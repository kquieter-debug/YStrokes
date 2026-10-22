import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../rust/api/document.dart' show LayerBlendMode;
import 'document_painter.dart';
import 'raster_surface.dart';

/// 把矢量图层烘焙成像素。
///
/// 这是「栅格化」唯一发生的地方，且**只由用户显式触发**——不做隐式栅格化，
/// 否则「可编辑矢量」这个卖点会在用户不知情时消失（ADR-027）。
///
/// 两条容易踩空的细节：
///
/// 1. **不烘焙图层自身的合成参数**。渲染时把不透明度置 1、混合模式置普通，
///    让这些参数继续留在图层上。否则一次「把 50% 的层栅格化」会得到
///    50% 的像素 + 50% 的图层不透明度 = 25%，画面立刻变淡。
/// 2. **alpha 语义**。`toByteData` 走 `rawStraightRgba`（非预乘），
///    与 [RasterSurface] 的存储约定一致；若改用 `rawRgba`（预乘），
///    像素会被再乘一次 alpha，半透明边缘变得又黑又脏。
class RasterRasterizer {
  const RasterRasterizer._();

  /// 把一层的内容渲染成文档尺寸的像素。
  ///
  /// 尺寸恒等于文档尺寸（D1：位图不超过画布上限，不做超采样）。
  /// 已在位图图层上调用时返回原有像素的写时复制副本（不做无谓的重采样）。
  static Future<RasterSurface> rasterizeLayer(
    DrawingLayer layer, {
    required int width,
    required int height,
  }) async {
    final existing = layer.raster;
    if (existing != null) return existing.fork();

    // 只带内容、不带合成参数的临时层：见类注释第 1 条。
    final contentOnly = DrawingLayer(
      id: layer.id,
      name: layer.name,
      opacity: 1,
      visible: true,
      blendMode: LayerBlendMode.normal,
      strokes: layer.strokes,
    );

    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintDocument(
      canvas,
      rect,
      const Color(0x00000000),
      <DrawingLayer>[contentOnly],
      drawPaper: false,
    );

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (data == null) {
          throw const RasterizeException('像素读取失败');
        }
        return RasterSurface.fromPixels(
          width,
          height,
          data.buffer.asUint8List(),
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}

/// 栅格化失败。调用方负责提示，不影响文档内容。
class RasterizeException implements Exception {
  const RasterizeException(this.message);

  final String message;

  @override
  String toString() => message;
}
