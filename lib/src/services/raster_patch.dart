import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'raster_mask.dart';
import 'raster_surface.dart';

/// 浮动内容的摆放参数：平移 + 等比缩放 + 旋转 + 镜像。
///
/// 与矢量的 `StrokeTransform` 是同构的（连镜像施加的顺序都一样：缩放之后、
/// 旋转之前），但**不可互换**——矢量的作用对象是点列，这里作用对象是一整块
/// 像素，因此这里不做烘焙，只是保留参数，绘制与提交时才落地。
class PatchTransform {
  const PatchTransform({
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
  });

  static const PatchTransform identity = PatchTransform();

  /// 平移量（图层像素）。
  final double dx;
  final double dy;

  /// 等比缩放系数。
  final double scale;

  /// 旋转角（弧度，顺时针为正）。
  final double rotation;

  final bool flipX;
  final bool flipY;

  bool get isIdentity =>
      dx == 0 &&
      dy == 0 &&
      scale == 1 &&
      rotation == 0 &&
      !flipX &&
      !flipY;

  PatchTransform copyWith({
    double? dx,
    double? dy,
    double? scale,
    double? rotation,
    bool? flipX,
    bool? flipY,
  }) =>
      PatchTransform(
        dx: dx ?? this.dx,
        dy: dy ?? this.dy,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        flipX: flipX ?? this.flipX,
        flipY: flipY ?? this.flipY,
      );

  @override
  String toString() =>
      'PatchTransform(dx: $dx, dy: $dy, scale: $scale, rot: $rotation, '
      'flip: ${flipX ? 'X' : ''}${flipY ? 'Y' : ''})';
}

/// 从图层里「提起」的一块像素：颜色 + 选区覆盖 + 它在原图中的位置。
///
/// ## 为什么是「提起」（lift）而不是原地预览
///
/// 只有两个选择：
/// - **原地预览**：每帧重新计算「擦掉选区内 + 在目标位置重画一份」，代价与
///   选区面积成正比，而且是每帧一次；
/// - **提起**：动一次手（把选区内像素搬出来、源区域清空），之后预览只是把
///   一张图按矩阵画出去，GPU 合成，成本与面积无关。
///
/// 后者就是传统像素软件里的「浮动选区」。代价是提起这一步会真的改动图层，
/// 所以它必须紧跟着一条撤销快照（由引擎负责）。
///
/// ## 颜色与覆盖分开存
///
/// 蒙版**不预乘进 alpha**：重采样时先插值颜色、再插值覆盖率、最后相乘。
/// 预先乘进去会让边界像素的 RGB 变成「和黑色混合过的值」，
/// 解预乘之后再插值就会出现暗边。
class RasterPatch {
  RasterPatch({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.pixels,
    required this.coverage,
  })  : assert(pixels.length == width * height * 4),
        assert(coverage.length == width * height);

  /// 在原图层中的位置。
  final int left;
  final int top;
  final int width;
  final int height;

  /// RGBA8888、**非预乘**、行优先。
  final Uint8List pixels;

  /// 每像素覆盖率 0–255。
  final Uint8List coverage;

  PixelBounds get bounds => PixelBounds(left, top, width, height);

  /// 从图层抠出 [mask] 覆盖的内容。
  ///
  /// **不修改** [surface]：清空源区域是独立的一步（[clearRegion]），
  /// 这样「只想复制、不想剪切」的场景也能直接用。
  /// 选区全空时返回 null。
  static RasterPatch? lift(RasterSurface surface, RasterMask mask) {
    final bounds = mask.bounds;
    if (bounds == null) return null;

    final region =
        surface.readRegion(bounds.left, bounds.top, bounds.width, bounds.height);
    final count = bounds.width * bounds.height;
    final pixels = Uint8List(count * 4);
    final coverage = Uint8List(count);

    for (var y = 0; y < bounds.height; y++) {
      final rowBase = y * bounds.width;
      for (var x = 0; x < bounds.width; x++) {
        final cov = mask.coverageAt(bounds.left + x, bounds.top + y);
        if (cov == 0) continue;
        final i = rowBase + x;
        coverage[i] = cov;
        final p = i * 4;
        pixels[p] = region[p];
        pixels[p + 1] = region[p + 1];
        pixels[p + 2] = region[p + 2];
        pixels[p + 3] = region[p + 3];
      }
    }

    return RasterPatch(
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      pixels: pixels,
      coverage: coverage,
    );
  }

  /// 把选区覆盖的区域从图层里抹掉。
  ///
  /// 按覆盖率**部分**扣除 alpha，而不是简单的置零：选区边界上的半覆盖像素
  /// 如果直接清空，移动后会留下一条白边（原本该留下一半）。
  ///
  /// 返回是否有像素被改动。
  static bool clearRegion(RasterSurface surface, RasterMask mask) {
    final bounds = mask.bounds;
    if (bounds == null) return false;

    var changed = false;
    final columnCount = surface.columns;
    for (var y = bounds.top; y < bounds.bottom; y++) {
      if (y < 0 || y >= surface.height) continue;
      final ty = y ~/ surface.tileSize;
      final rowInTile = y - ty * surface.tileSize;

      for (var x = bounds.left; x < bounds.right; x++) {
        if (x < 0 || x >= surface.width) continue;
        final cov = mask.coverageAt(x, y);
        if (cov == 0) continue;

        final tx = x ~/ surface.tileSize;
        if (tx >= columnCount) continue;
        final buffer = surface.writableTile(tx, ty);
        final index =
            (rowInTile * surface.tileSize + (x - tx * surface.tileSize)) * 4;
        final alpha = buffer[index + 3];
        if (alpha == 0) continue;

        final next = alpha * (255 - cov) ~/ 255;
        buffer[index + 3] = next;
        if (next == 0) {
          // 完全透明之后 RGB 已无意义，清零可以避免半透明像素在缩小采样时
          // 把残留颜色带出来。
          buffer[index] = 0;
          buffer[index + 1] = 0;
          buffer[index + 2] = 0;
        }
        changed = true;
      }
    }
    return changed;
  }

  /// 按 [transform] 把内容合成回图层。
  ///
  /// 逆向映射 + 双线性：遍历**目标**包围盒的每个像素，反算回 patch 本地坐标采样。
  /// 反过来（遍历源像素、正向投射）会在放大时留下空洞，在缩小时重复写入。
  ///
  /// 颜色在**预乘空间**插值后解回直通 alpha：直通空间插值会让高对比边界
  /// 出现一圈黑边（透明像素的 RGB 是 0，被当成"黑色"参与混合）。
  ///
  /// 返回被改动到的瓦片（渲染层据此重传纹理）。
  Set<TileKey> compositeInto(
    RasterSurface surface, {
    PatchTransform transform = PatchTransform.identity,
  }) {
    final touched = <TileKey>{};
    final scale = transform.scale.abs() < 1e-6 ? 1e-6 : transform.scale;
    final cos = math.cos(transform.rotation);
    final sin = math.sin(transform.rotation);
    final halfW = width / 2;
    final halfH = height / 2;
    final cx = left + halfW + transform.dx;
    final cy = top + halfH + transform.dy;

    // 目标包围盒 = 四个角变换后的外接矩形。
    final corners = <Offset>[
      for (final local in <Offset>[
        const Offset(0, 0),
        Offset(width.toDouble(), 0),
        Offset(width.toDouble(), height.toDouble()),
        Offset(0, height.toDouble()),
      ])
        _forward(local, cx, cy, halfW, halfH, scale, cos, sin, transform),
    ];
    var minX = corners.first.dx;
    var maxX = minX;
    var minY = corners.first.dy;
    var maxY = minY;
    for (final c in corners.skip(1)) {
      minX = math.min(minX, c.dx);
      maxX = math.max(maxX, c.dx);
      minY = math.min(minY, c.dy);
      maxY = math.max(maxY, c.dy);
    }

    final x0 = math.max(0, (minX - 1).floor());
    final x1 = math.min(surface.width - 1, (maxX + 1).ceil());
    final y0 = math.max(0, (minY - 1).floor());
    final y1 = math.min(surface.height - 1, (maxY + 1).ceil());
    if (x0 > x1 || y0 > y1) return touched;

    final inverseCos = math.cos(-transform.rotation);
    final inverseSin = math.sin(-transform.rotation);
    final tileSize = surface.tileSize;

    for (var y = y0; y <= y1; y++) {
      final ty = y ~/ tileSize;
      final rowInTile = y - ty * tileSize;

      for (var x = x0; x <= x1; x++) {
        // 目标像素中心反算回 patch 本地坐标。
        final relX = x + 0.5 - cx;
        final relY = y + 0.5 - cy;
        var u = (relX * inverseCos - relY * inverseSin) / scale;
        var v = (relX * inverseSin + relY * inverseCos) / scale;
        if (transform.flipX) u = -u;
        if (transform.flipY) v = -v;
        u += halfW;
        v += halfH;

        // 双线性需要 u-0.5 落在 [0, width-1] 内，否则完全在 patch 外。
        if (u < -0.5 || v < -0.5 || u > width + 0.5 || v > height + 0.5) {
          continue;
        }

        final sample = _sampleBilinear(u - 0.5, v - 0.5);
        final cov = sample.coverage;
        if (cov <= 0) continue;

        final srcA = sample.a * cov;
        if (srcA <= 0) continue;

        final tx = x ~/ tileSize;
        final buffer = surface.writableTile(tx, ty);
        final index = (rowInTile * tileSize + (x - tx * tileSize)) * 4;
        _blendOver(buffer, index, sample, srcA);
        touched.add((tx, ty));
      }
    }
    return touched;
  }

  /// 把蒙版乘进 alpha，得到一张可以直接交给解码器的图（预览用）。
  ///
  /// 预览走 GPU 合成，因此这里只烘焙一次，之后每帧只是换一个矩阵。
  Uint8List toImageRgba() {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      final cov = coverage[i];
      final p = i * 4;
      if (cov == 0) continue;
      out[p] = pixels[p];
      out[p + 1] = pixels[p + 1];
      out[p + 2] = pixels[p + 2];
      out[p + 3] = pixels[p + 3] * cov ~/ 255;
    }
    return out;
  }

  Offset _forward(
    Offset local,
    double cx,
    double cy,
    double halfW,
    double halfH,
    double scale,
    double cos,
    double sin,
    PatchTransform transform,
  ) {
    var x = local.dx - halfW;
    var y = local.dy - halfH;
    if (transform.flipX) x = -x;
    if (transform.flipY) y = -y;
    x *= scale;
    y *= scale;
    return Offset(
      cx + x * cos - y * sin,
      cy + x * sin + y * cos,
    );
  }

  /// 在 patch 本地坐标（0-based，可为小数）处双线性采样。
  ///
  /// 返回**预乘**颜色 + 插值后的覆盖率。
  _Sample _sampleBilinear(double u, double v) {
    final x0 = u.floor();
    final y0 = v.floor();
    final fx = u - x0;
    final fy = v - y0;

    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    var a = 0.0;
    var cov = 0.0;

    for (var dy = 0; dy <= 1; dy++) {
      final sy = y0 + dy;
      if (sy < 0 || sy >= height) continue;
      final wy = dy == 0 ? 1 - fy : fy;
      if (wy <= 0) continue;

      for (var dx = 0; dx <= 1; dx++) {
        final sx = x0 + dx;
        if (sx < 0 || sx >= width) continue;
        final wx = dx == 0 ? 1 - fx : fx;
        if (wx <= 0) continue;

        final weight = wx * wy;
        final i = sy * width + sx;
        final c = coverage[i];
        if (c == 0) continue; // 无覆盖的像素不带入任何颜色（避免黑边）

        final p = i * 4;
        final alpha = pixels[p + 3] / 255.0;
        // 预乘后再加权：直通 alpha 插值会让透明像素的 RGB 污染边缘。
        r += pixels[p] * alpha * weight;
        g += pixels[p + 1] * alpha * weight;
        b += pixels[p + 2] * alpha * weight;
        a += alpha * weight;
        cov += c / 255.0 * weight;
      }
    }

    return _Sample(r: r, g: g, b: b, a: a, coverage: cov);
  }

  /// 把预乘样本合成到直通 alpha 的目标像素上。
  static void _blendOver(Uint8List buffer, int index, _Sample src, double srcA) {
    final dstA = buffer[index + 3] / 255.0;
    final outA = srcA + dstA * (1 - srcA);
    if (outA <= 0) {
      buffer[index] = 0;
      buffer[index + 1] = 0;
      buffer[index + 2] = 0;
      buffer[index + 3] = 0;
      return;
    }

    final dstWeight = dstA * (1 - srcA);
    final r = src.r + buffer[index] * dstWeight;
    final g = src.g + buffer[index + 1] * dstWeight;
    final b = src.b + buffer[index + 2] * dstWeight;

    buffer[index] = (r / outA).clamp(0, 255).round();
    buffer[index + 1] = (g / outA).clamp(0, 255).round();
    buffer[index + 2] = (b / outA).clamp(0, 255).round();
    buffer[index + 3] = (outA * 255).clamp(0, 255).round();
  }
}

/// 一次双线性采样的结果：预乘 RGB、独立累积的 alpha 与覆盖率。
class _Sample {
  const _Sample({
    required this.r,
    required this.g,
    required this.b,
    required this.a,
    required this.coverage,
  });

  /// 预乘 RGB（0–255 量级）。
  final double r;
  final double g;
  final double b;

  /// 插值后的 alpha（0–1）。
  final double a;

  /// 插值后的覆盖率（0–1）。
  final double coverage;
}
