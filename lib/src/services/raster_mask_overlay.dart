import 'dart:typed_data';

import 'raster_mask.dart';

/// 一张「选区外压暗」的叠加图：黑色，alpha 与覆盖率成反比。
class MaskDimOverlay {
  const MaskDimOverlay({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;

  /// RGBA8888、非预乘，行优先。
  final Uint8List rgba;
}

/// 由选区蒙版生成压暗层（快速蒙版效果）。
///
/// 画在画面之上，选区外逐渐变暗——「哪一块被选中」因此在任何底色上都一眼可辨，
/// 不必依赖一圈细虚线。它与流动虚线是两件事：虚线标边界，压暗标范围。
///
/// ## 为什么要降采样
///
/// 压暗是一大片平涂，原分辨率的细节毫无意义，而 1080×1920 的 RGBA 是 8 MB。
/// 降到 [downscale] 分之一后：
/// - 解码与纹理上传成本降到 1/4（双线性放大后的软边正好符合快速蒙版的观感）；
/// - 逐像素遍历从 200 万次降到 50 万次。
///
/// 用**盒式平均**而不是最近邻：最近邻会让选区边界在放大后出现锯齿状的暗边。
MaskDimOverlay buildMaskDimOverlay(
  RasterMask mask, {
  double strength = 0.22,
  int downscale = 2,
}) {
  assert(downscale >= 1, '降采样倍率必须为正');
  final outWidth = (mask.width / downscale).ceil();
  final outHeight = (mask.height / downscale).ceil();
  final rgba = Uint8List(outWidth * outHeight * 4);
  final maxAlpha = (strength.clamp(0.0, 1.0) * 255).round();

  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      // 盒式平均：把 downscale² 个源像素的覆盖率求均值。
      var sum = 0;
      var count = 0;
      for (var dy = 0; dy < downscale; dy++) {
        final sy = y * downscale + dy;
        if (sy >= mask.height) break;
        for (var dx = 0; dx < downscale; dx++) {
          final sx = x * downscale + dx;
          if (sx >= mask.width) break;
          sum += mask.coverageAt(sx, sy);
          count++;
        }
      }
      if (count == 0) continue;

      final coverage = sum / count / 255.0;
      final alpha = (maxAlpha * (1 - coverage)).round();
      if (alpha <= 0) continue;

      // RGB 保持 0：叠一层黑，让底色整体变暗而不是变色。
      rgba[(y * outWidth + x) * 4 + 3] = alpha > 255 ? 255 : alpha;
    }
  }

  return MaskDimOverlay(width: outWidth, height: outHeight, rgba: rgba);
}
