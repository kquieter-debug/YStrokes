import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/raster_mask.dart';
import 'package:ystrokes/src/services/raster_mask_overlay.dart';
import 'package:ystrokes/src/services/raster_patch.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// 像素选区的两个数据模块：蒙版（多边形 → 覆盖率）与浮动内容（提取 / 写回）。
///
/// 这一层完全不含 UI，因此可以直接断言像素值。
void main() {
  const width = 8;
  const height = 8;

  /// 轴对齐的矩形选区（整像素边界，覆盖率非 0 即 255）。
  RasterMask rectMask(int left, int top, int right, int bottom) =>
      RasterMask.fromPolygon(width, height, <Offset>[
        Offset(left.toDouble(), top.toDouble()),
        Offset(right.toDouble(), top.toDouble()),
        Offset(right.toDouble(), bottom.toDouble()),
        Offset(left.toDouble(), bottom.toDouble()),
      ]);

  int alphaAt(RasterSurface s, int x, int y) {
    final tile = s.tile(0, 0);
    if (tile == null) return 0;
    return tile[(y * s.tileSize + x) * 4 + 3];
  }

  void fill(RasterSurface s, int left, int top, int w, int h, int argb) {
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    for (var y = top; y < top + h; y++) {
      for (var x = left; x < left + w; x++) {
        final buffer = s.writableTile(0, 0);
        final i = (y * s.tileSize + x) * 4;
        buffer[i] = r;
        buffer[i + 1] = g;
        buffer[i + 2] = b;
        buffer[i + 3] = a;
      }
    }
  }

  group('选区蒙版', () {
    test('矩形内部全选中，外部全不选', () {
      final mask = rectMask(2, 2, 6, 6);

      expect(mask.coverageAt(4, 4), 255);
      expect(mask.coverageAt(2, 2), 255);
      expect(mask.coverageAt(1, 1), 0);
      expect(mask.coverageAt(6, 6), 0);
      expect(mask.isEmpty, isFalse);
    });

    test('包围盒只覆盖被选中的像素范围', () {
      final mask = rectMask(2, 3, 6, 7);
      expect(mask.bounds, const PixelBounds(2, 3, 4, 4));
    });

    test('斜边产生中间覆盖率（抗锯齿）', () {
      // 三角形：垂直边在 x=2，斜边从 (6,2) 到 (2,6)。
      final mask = RasterMask.fromPolygon(width, height, <Offset>[
        const Offset(2, 2),
        const Offset(6, 2),
        const Offset(2, 6),
      ]);

      // 三角内部：中心点稳在内部。
      expect(mask.coverageAt(3, 3), greaterThan(200));
      // 斜边附近必然出现部分覆盖：既非 0 也非 255。
      var partial = 0;
      for (var y = 2; y < 6; y++) {
        for (var x = 2; x < 6; x++) {
          final c = mask.coverageAt(x, y);
          if (c > 0 && c < 255) partial++;
        }
      }
      expect(partial, greaterThan(0), reason: '斜边应有过渡像素');
    });

    test('多边形超出画布时被裁剪，不越界', () {
      final mask = RasterMask.fromPolygon(width, height, <Offset>[
        const Offset(-10, -10),
        const Offset(4, -10),
        const Offset(4, 20),
        const Offset(-10, 20),
      ]);

      expect(mask.coverageAt(0, 0), 255);
      expect(mask.coverageAt(3, 7), 255);
      expect(mask.coverageAt(4, 4), 0);
    });

    test('退化输入得到空选区', () {
      expect(RasterMask.fromPolygon(width, height, const <Offset>[]).isEmpty, isTrue);
      expect(
        RasterMask.fromPolygon(width, height, const <Offset>[
          Offset(1, 1),
          Offset(5, 5),
        ]).isEmpty,
        isTrue,
      );
    });

    test('反向选择取补集，再取一次回到原样', () {
      final mask = rectMask(2, 2, 4, 4);
      final inverted = mask.inverted();

      expect(inverted.coverageAt(2, 2), 0);
      expect(inverted.coverageAt(0, 0), 255);
      expect(mask.inverted().inverted().coverageAt(2, 2), 255);
    });

    test('加选是并集，减选是差集', () {
      final a = rectMask(0, 0, 4, 4);
      final b = rectMask(2, 2, 6, 6);

      final union = a.union(b);
      expect(union.coverageAt(1, 1), 255);
      expect(union.coverageAt(5, 5), 255);

      final diff = a.subtract(b);
      expect(diff.coverageAt(1, 1), 255);
      expect(diff.coverageAt(3, 3), 0, reason: '重叠部分应被减掉');
    });

    test('交集按乘积合并覆盖率', () {
      final a = rectMask(0, 0, 4, 4);
      final b = rectMask(2, 2, 6, 6);

      final cross = a.intersect(b);
      expect(cross.coverageAt(3, 3), 255);
      expect(cross.coverageAt(1, 1), 0);
    });

    test('选中面积按覆盖率折算', () {
      final mask = rectMask(0, 0, 2, 2);
      expect(mask.selectedPixels, closeTo(4, 1e-9));
    });
  });

  group('浮动内容', () {
    test('提起时只取选区内的像素', () {
      final s = RasterSurface(width: width, height: height);
      fill(s, 0, 0, width, height, 0xFF3366CC);

      final patch = RasterPatch.lift(s, rectMask(2, 2, 5, 5));
      expect(patch, isNotNull);
      expect(patch!.bounds, const PixelBounds(2, 2, 3, 3));
      expect(patch.pixels[3], 255, reason: '第一像素的 alpha');

      // 选区外的像素不该进入 patch。
      final mask = rectMask(2, 2, 5, 5);
      expect(mask.coverageAt(1, 1), 0);
    });

    test('空选区提起返回 null', () {
      final s = RasterSurface(width: width, height: height);
      expect(RasterPatch.lift(s, RasterMask.empty(width, height)), isNull);
    });

    test('清除区域按覆盖率扣除 alpha', () {
      final s = RasterSurface(width: width, height: height);
      fill(s, 0, 0, width, height, 0xFF000000);

      expect(RasterPatch.clearRegion(s, rectMask(2, 2, 4, 4)), isTrue);
      expect(alphaAt(s, 3, 3), 0, reason: '全选中的像素被完全抹掉');
      expect(alphaAt(s, 5, 5), 255, reason: '选区外不受影响');
    });

    test('提起 → 清除 → 原样放回，逐像素恢复', () {
      final s = RasterSurface(width: width, height: height);
      fill(s, 0, 0, width, height, 0xFF3366CC);
      final before = <int>[
        for (var i = 0; i < width * height; i++) alphaAt(s, i % width, i ~/ width),
      ];

      final mask = rectMask(2, 2, 6, 6);
      final patch = RasterPatch.lift(s, mask)!;
      RasterPatch.clearRegion(s, mask);
      expect(alphaAt(s, 3, 3), 0);

      // 整像素覆盖下双线性采样应精确命中原像素，往返无损失。
      patch.compositeInto(s);

      for (var i = 0; i < before.length; i++) {
        expect(
          alphaAt(s, i % width, i ~/ width),
          before[i],
          reason: '像素 (${i % width}, ${i ~/ width}) 往返后应一致',
        );
      }
    });

    test('平移后内容出现在新位置，原位置留空', () {
      final s = RasterSurface(width: width, height: height);
      fill(s, 2, 2, 2, 2, 0xFFFF0000);

      final mask = rectMask(2, 2, 4, 4);
      final patch = RasterPatch.lift(s, mask)!;
      RasterPatch.clearRegion(s, mask);
      final touched = patch.compositeInto(
        s,
        transform: const PatchTransform(dx: 4, dy: 0),
      );

      expect(touched, isNotEmpty);
      expect(alphaAt(s, 2, 2), 0, reason: '原位置已清空');
      expect(alphaAt(s, 6, 2), 255, reason: '新位置有内容');
    });

    test('缩放与旋转不抛异常，且改动瓦片被上报', () {
      final s = RasterSurface(width: 32, height: 32);
      fill(s, 8, 8, 8, 8, 0xFF00FF00);

      final mask = RasterMask.fromPolygon(32, 32, <Offset>[
        const Offset(8, 8),
        const Offset(16, 8),
        const Offset(16, 16),
        const Offset(8, 16),
      ]);
      final patch = RasterPatch.lift(s, mask)!;
      RasterPatch.clearRegion(s, mask);

      final touched = patch.compositeInto(
        s,
        transform: const PatchTransform(dx: 6, dy: 2, scale: 0.5, rotation: 0.4),
      );
      expect(touched, isNotEmpty);

      var anyInk = false;
      for (var y = 0; y < 32 && !anyInk; y++) {
        for (var x = 0; x < 32; x++) {
          if (alphaAt(s, x, y) > 0) {
            anyInk = true;
            break;
          }
        }
      }
      expect(anyInk, isTrue, reason: '缩放旋转后仍应有内容');
    });

    test('镜像参数参与映射', () {
      final s = RasterSurface(width: width, height: height);
      // 2×2 选区（中心在 3）里只在左上角放一个点。水平镜像后，
      // 本地 [0,1) 会翻到中心的另一侧，也就是 x=3 那一列。
      fill(s, 2, 2, 1, 1, 0xFF000000);

      final mask = rectMask(2, 2, 4, 4);
      final patch = RasterPatch.lift(s, mask)!;
      RasterPatch.clearRegion(s, mask);
      patch.compositeInto(s, transform: const PatchTransform(flipX: true));

      expect(alphaAt(s, 3, 2), greaterThan(0), reason: '镜像后落到中心另一侧');
      expect(alphaAt(s, 2, 2), 0);
    });

    test('预览图把蒙版乘进 alpha', () {
      final s = RasterSurface(width: width, height: height);
      fill(s, 0, 0, width, height, 0xFF3366CC);

      final patch = RasterPatch.lift(s, rectMask(2, 2, 4, 4))!;
      final rgba = patch.toImageRgba();

      expect(rgba.length, 2 * 2 * 4);
      expect(rgba[3], 255);
      expect(rgba[0], 0x33);
    });
  });

  group('选区外压暗', () {
    test('选区外变暗，选区内保持透明', () {
      final mask = rectMask(2, 2, 6, 6);
      final overlay = buildMaskDimOverlay(mask, downscale: 1);

      int alphaAt(int x, int y) => overlay.rgba[(y * overlay.width + x) * 4 + 3];

      expect(alphaAt(0, 0), greaterThan(0), reason: '选区外应当压暗');
      expect(alphaAt(4, 4), 0, reason: '选区内完全不压暗');
    });

    test('降采样后的尺寸向上取整', () {
      final mask = rectMask(0, 0, 3, 3);
      final overlay = buildMaskDimOverlay(mask, downscale: 2);
      expect(overlay.width, (width / 2).ceil());
      expect(overlay.height, (height / 2).ceil());
      expect(overlay.rgba.length, overlay.width * overlay.height * 4);
    });

    test('强度决定最暗处的 alpha', () {
      final mask = rectMask(0, 0, 1, 1);
      final strong = buildMaskDimOverlay(mask, strength: 1.0, downscale: 1);
      final weak = buildMaskDimOverlay(mask, strength: 0.1, downscale: 1);

      // 取一个远离选区中心的像素。
      int alphaAt(MaskDimOverlay o, int x, int y) =>
          o.rgba[(y * o.width + x) * 4 + 3];

      expect(alphaAt(strong, 7, 7), 255);
      expect(alphaAt(weak, 7, 7), lessThan(40));
    });

    test('全选选区不产生任何压暗', () {
      final mask = RasterMask.full(width, height);
      final overlay = buildMaskDimOverlay(mask, downscale: 1);
      for (var i = 3; i < overlay.rgba.length; i += 4) {
        expect(overlay.rgba[i], 0);
      }
    });
  });
}
