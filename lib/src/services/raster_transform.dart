import 'raster_surface.dart';

/// 位图的整层几何变换。
///
/// 只做**整数像素置换**（镜像）：每个目标像素都精确来自某一个源像素，
/// 因此逐位精确、不进插值、不软化边缘。
///
/// 旋转 90° 的倍数不在这一类里：它会交换宽高，而位图尺寸恒等于文档尺寸
/// （D1，不做超采样），尺寸一变就得连同文档一起改。那类变换要等图层矩阵
/// （P3）有统一的表示之后再说。
abstract final class RasterTransform {
  /// 翻转整层。`horizontal` 为真表示左右镜像。
  ///
  /// 走「整层取出 → 就地置换 → 写回」而不是逐瓦片处理：镜像会把一个像素搬到
  /// 关于中心对称的另一个瓦片里，逐瓦片做要处理瓦片间的配对，代码量翻几倍而
  /// 收益为零。整层 8.3 MB 的临时缓冲，对一次性操作完全够用。
  static void flip(RasterSurface surface, {required bool horizontal}) {
    final width = surface.width;
    final height = surface.height;
    if (width <= 0 || height <= 0) return;

    final pixels = surface.toPixelBytes();
    const bpp = RasterSurface.bytesPerPixel;

    if (horizontal) {
      for (var y = 0; y < height; y++) {
        final row = y * width * bpp;
        for (var x = 0; x < width ~/ 2; x++) {
          final left = row + x * bpp;
          final right = row + (width - 1 - x) * bpp;
          for (var i = 0; i < bpp; i++) {
            final tmp = pixels[left + i];
            pixels[left + i] = pixels[right + i];
            pixels[right + i] = tmp;
          }
        }
      }
    } else {
      final stride = width * bpp;
      for (var y = 0; y < height ~/ 2; y++) {
        final top = y * stride;
        final bottom = (height - 1 - y) * stride;
        for (var i = 0; i < stride; i++) {
          final tmp = pixels[top + i];
          pixels[top + i] = pixels[bottom + i];
          pixels[bottom + i] = tmp;
        }
      }
    }

    // 就地替换内容而不是造一张新 surface：对象身份不变，渲染缓存不会整体失效。
    surface.replacePixels(pixels);
  }
}
