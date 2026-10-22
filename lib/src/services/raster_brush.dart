import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'raster_surface.dart';

/// 像素笔：把一条笔画落到 [RasterSurface] 上。
///
/// 只做「几何 → 像素」，不认识图层、文档矩形、撤销栈，也不碰 UI。
/// 输入一律是**surface 像素坐标**，因此调用方负责把归一化坐标换算成像素
/// （一次乘法），这也让本模块可以在纯 Dart 测试里逐像素断言。
///
/// ## 笔尖模型
///
/// 当前是**实心圆 + 单像素抗锯齿**（coverage 在边缘 1 像素内线性过渡）。
/// 硬度、流量、纹理都还没有——它们属于 ROADMAP 的笔刷项，等位图图层稳定后
/// 再替换本类的笔尖实现；接口（一条线段 → 一串 dab）不需要跟着变。
///
/// ## 为什么用直通 alpha
///
/// 存储是 RGBA8888 **非预乘**：PNG 编码、`decodeImageFromPixels` 与肉眼调试
/// 都按这个约定工作。代价是混合时要多一次除法（见 [_blendOver]），
/// 但只在被 dab 覆盖的像素上发生，量级可忽略。
class RasterBrush {
  /// dab 间距相对半径的比例。
  ///
  /// 0.25 意味着半径 8 的笔刷每隔 2 像素落一个 dab，重叠足够密，
  /// 又不会让一次移动产生几十个 dab。太小会让高速运笔变成一连串圆点。
  static const double spacingRatio = 0.25;

  /// 绝对最小间距（像素）：极细笔刷下避免间距变成 0 而陷入死循环。
  static const double minSpacing = 0.5;

  /// 沿 `from → to` 连续落 dab，返回**被改动的瓦片坐标**。
  ///
  /// 返回值不是可选的附加信息：渲染层要靠它决定重传哪几块纹理。若改从
  /// `surface.dirtyTiles` 推断，会与「落盘脏标记」共用一个标志位，
  /// 保存后标记被清空、绘制却还在继续——两个消费者争一份状态，迟早出错。
  static Set<TileKey> strokeSegment(
    RasterSurface surface, {
    required Offset from,
    required Offset to,
    required double radius,
    required int colorArgb,
    required bool erase,
  }) {
    final touched = <TileKey>{};
    if (radius <= 0) return touched;
    final distance = (to - from).distance;
    final spacing = math.max(minSpacing, radius * spacingRatio);

    // 距离为 0（原地按下/极慢移动）时也要落一个 dab，否则点一下什么都没有。
    final steps = distance <= 0 ? 0 : (distance / spacing).ceil();
    if (steps <= 0) {
      return dab(
        surface,
        center: to,
        radius: radius,
        colorArgb: colorArgb,
        erase: erase,
      );
    }

    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      touched.addAll(
        dab(
          surface,
          center: Offset(
            from.dx + (to.dx - from.dx) * t,
            from.dy + (to.dy - from.dy) * t,
          ),
          radius: radius,
          colorArgb: colorArgb,
          erase: erase,
        ),
      );
    }
    return touched;
  }

  /// 落一个圆形 dab，返回被改动的瓦片坐标。
  ///
  /// 按**瓦片**遍历而不是按像素查表：一次 dab 通常只覆盖一块瓦片，
  /// 每块瓦片只取一次可写缓冲（写时复制的分裂也只发生一次），
  /// 内层循环因此是纯算术。
  static Set<TileKey> dab(
    RasterSurface surface, {
    required Offset center,
    required double radius,
    required int colorArgb,
    required bool erase,
  }) {
    final touched = <TileKey>{};
    if (radius <= 0) return touched;

    final size = surface.tileSize;
    final left = (center.dx - radius - 1).floor();
    final top = (center.dy - radius - 1).floor();
    final right = (center.dx + radius + 1).ceil();
    final bottom = (center.dy + radius + 1).ceil();

    final minX = math.max(0, left);
    final minY = math.max(0, top);
    final maxX = math.min(surface.width - 1, right);
    final maxY = math.min(surface.height - 1, bottom);
    if (minX > maxX || minY > maxY) return touched;

    final srcA = ((colorArgb >> 24) & 0xFF) / 255.0;
    final srcR = (colorArgb >> 16) & 0xFF;
    final srcG = (colorArgb >> 8) & 0xFF;
    final srcB = colorArgb & 0xFF;

    final tx0 = minX ~/ size;
    final tx1 = maxX ~/ size;
    final ty0 = minY ~/ size;
    final ty1 = maxY ~/ size;

    for (var ty = ty0; ty <= ty1; ty++) {
      for (var tx = tx0; tx <= tx1; tx++) {
        // 瓦片与 dab 包围盒的交集：只遍历这里面的像素。
        final x0 = math.max(minX, tx * size);
        final x1 = math.min(maxX, tx * size + size - 1);
        final y0 = math.max(minY, ty * size);
        final y1 = math.min(maxY, ty * size + size - 1);

        // 擦除空白区域等于什么都不做，不必为它分配瓦片。
        if (erase && surface.tile(tx, ty) == null) continue;
        final buffer = surface.writableTile(tx, ty);
        touched.add((tx, ty));

        for (var y = y0; y <= y1; y++) {
          final dy = y + 0.5 - center.dy;
          final rowBase = (y - ty * size) * size;
          for (var x = x0; x <= x1; x++) {
            final dx = x + 0.5 - center.dx;
            final dist = math.sqrt(dx * dx + dy * dy);
            // 边缘 1 像素线性覆盖：既避免了锯齿，也不需要超采样。
            final coverage = (radius + 0.5 - dist).clamp(0.0, 1.0);
            if (coverage <= 0) continue;

            final index = (rowBase + (x - tx * size)) * RasterSurface.bytesPerPixel;
            _blendOver(
              buffer,
              index,
              coverage: coverage,
              erase: erase,
              srcA: srcA,
              srcR: srcR,
              srcG: srcG,
              srcB: srcB,
            );
          }
        }
      }
    }
    return touched;
  }

  /// 把一整条折线画出来（栅格化、导入场景用），返回被改动的瓦片。
  static Set<TileKey> strokePolyline(
    RasterSurface surface,
    List<Offset> points, {
    required double radius,
    required int colorArgb,
    bool erase = false,
  }) {
    final touched = <TileKey>{};
    if (points.isEmpty) return touched;
    if (points.length == 1) {
      return dab(
        surface,
        center: points.first,
        radius: radius,
        colorArgb: colorArgb,
        erase: erase,
      );
    }
    for (var i = 1; i < points.length; i++) {
      touched.addAll(
        strokeSegment(
          surface,
          from: points[i - 1],
          to: points[i],
          radius: radius,
          colorArgb: colorArgb,
          erase: erase,
        ),
      );
    }
    return touched;
  }

  /// 把一个 dab 的覆盖写进单个像素（直通 alpha 的 source-over）。
  static void _blendOver(
    Uint8List buffer,
    int index, {
    required double coverage,
    required bool erase,
    required double srcA,
    required int srcR,
    required int srcG,
    required int srcB,
  }) {
    final dstA = buffer[index + 3] / 255.0;

    if (erase) {
      // 擦除按覆盖率削减 alpha，颜色保持不动（alpha 为 0 时颜色无意义）。
      final next = (dstA * (1 - coverage)).clamp(0.0, 1.0);
      buffer[index + 3] = (next * 255).round();
      if (next <= 0) {
        buffer[index] = 0;
        buffer[index + 1] = 0;
        buffer[index + 2] = 0;
      }
      return;
    }

    final sa = srcA * coverage;
    if (sa <= 0) return;

    final outA = sa + dstA * (1 - sa);
    if (outA <= 0) {
      buffer[index] = 0;
      buffer[index + 1] = 0;
      buffer[index + 2] = 0;
      buffer[index + 3] = 0;
      return;
    }

    // 直通 alpha 的合成公式：先把两边都还原成「量」，加权后除以总 alpha。
    final dstWeight = dstA * (1 - sa);
    buffer[index] = ((srcR * sa + buffer[index] * dstWeight) / outA).round().clamp(0, 255);
    buffer[index + 1] =
        ((srcG * sa + buffer[index + 1] * dstWeight) / outA).round().clamp(0, 255);
    buffer[index + 2] =
        ((srcB * sa + buffer[index + 2] * dstWeight) / outA).round().clamp(0, 255);
    buffer[index + 3] = (outA * 255).round().clamp(0, 255);
  }
}
