import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/services/stroke_outline.dart';

/// 压感驱动笔宽：映射曲线、轮廓几何与「换空间不换形状」不变量。
void main() {
  /// 构造一条归一化点列；[pressures] 与 [points] 一一对应。
  List<rust.StrokePoint> stroke(
    List<(double, double)> points, {
    List<double>? pressures,
  }) =>
      <rust.StrokePoint>[
        for (var i = 0; i < points.length; i++)
          rust.StrokePoint(
            x: points[i].$1,
            y: points[i].$2,
            pressure: pressures == null ? 1.0 : pressures[i],
            timestampMs: 0,
          ),
      ];

  double maxOffsetFromCenterline(List<Offset> outline, double cy) =>
      outline.map((p) => (p.dy - cy).abs()).reduce(math.max);

  group('压力映射', () {
    test('压力 1.0 精确等于基准宽度', () {
      // 手指与不支持压感的笔上报 1.0，必须与「关闭压感」得到同一线宽。
      expect(pressureWidthFactor(1.0), 1.0);
    });

    test('压力 0 落在 25% 下限', () {
      expect(pressureWidthFactor(0.0), closeTo(kPressureMinFactor, 1e-12));
    });

    test('单调递增且不超过上限', () {
      var previous = pressureWidthFactor(0.0);
      for (var i = 1; i <= 100; i++) {
        final next = pressureWidthFactor(i / 100);
        expect(next, greaterThanOrEqualTo(previous - 1e-12));
        expect(next, lessThanOrEqualTo(kPressureMaxFactor));
        previous = next;
      }
    });

    test('越界与非法输入被夹住，不产生 NaN', () {
      expect(pressureWidthFactor(-3), closeTo(kPressureMinFactor, 1e-12));
      expect(pressureWidthFactor(9), lessThanOrEqualTo(kPressureMaxFactor));
      expect(pressureWidthFactor(double.nan), 1.0);
      expect(pressureWidthFactor(double.infinity), 1.0);
    });

    test('gamma 使中段偏细（曲线位于线性映射之下）', () {
      // gamma > 1 时 p^gamma < p；这是「笔锋更明显」的来源。
      const p = 0.5;
      final linear = kPressureMinFactor + (1 - kPressureMinFactor) * p;
      expect(pressureWidthFactor(p), lessThan(linear));
    });
  });

  group('轮廓几何', () {
    const spaceW = 100.0;
    const spaceH = 100.0;
    const base = 10.0;

    test('点数不足、空间非法或笔宽非法时返回空', () {
      expect(
        buildStrokeOutline(
          points: stroke([(0.5, 0.5)]),
          spaceWidth: spaceW,
          spaceHeight: spaceH,
          baseWidth: base,
        ),
        isEmpty,
      );
      expect(
        buildStrokeOutline(
          points: stroke([(0.1, 0.5), (0.9, 0.5)]),
          spaceWidth: 0,
          spaceHeight: spaceH,
          baseWidth: base,
        ),
        isEmpty,
      );
      expect(
        buildStrokeOutline(
          points: stroke([(0.1, 0.5), (0.9, 0.5)]),
          spaceWidth: spaceW,
          spaceHeight: spaceH,
          baseWidth: 0,
        ),
        isEmpty,
      );
    });

    test('等压直线：厚度等于基准宽度，两端各外扩半个笔宽', () {
      final outline = buildStrokeOutline(
        points: stroke([(0.1, 0.5), (0.5, 0.5), (0.9, 0.5)]),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: base,
        pressure: true,
      );

      expect(outline, isNotEmpty);
      expect(maxOffsetFromCenterline(outline, 50), closeTo(5, 1e-6));

      final xs = outline.map((p) => p.dx);
      expect(xs.reduce(math.min), closeTo(10 - 5, 1e-6));
      expect(xs.reduce(math.max), closeTo(90 + 5, 1e-6));
    });

    test('关闭压感时厚度恒定，与压力值无关', () {
      final outline = buildStrokeOutline(
        points: stroke(
          [(0.1, 0.5), (0.5, 0.5), (0.9, 0.5)],
          pressures: [0.1, 0.5, 1.0],
        ),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: base,
        pressure: false,
      );

      expect(maxOffsetFromCenterline(outline, 50), closeTo(5, 1e-6));
    });

    test('变压力：起笔处厚度随压力收窄', () {
      final outline = buildStrokeOutline(
        points: stroke(
          [(0.1, 0.5), (0.5, 0.5), (0.9, 0.5)],
          pressures: [0.0, 1.0, 1.0],
        ),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: base,
        pressure: true,
      );

      // 首端半径 = 5 × 0.25 = 1.25。圆帽按 10 段折线近似，最外侧的极值点
      // 落在左右两侧的入射点上；只取首端圆帽范围内的点来验证收窄。
      final cap = outline.where((p) => p.dx <= 10 + 1e-9).toList();
      expect(cap, isNotEmpty);
      final capOffset = maxOffsetFromCenterline(cap, 50);
      expect(capOffset, closeTo(1.25, 1e-6));
      expect(capOffset, lessThan(5), reason: '首端必须明显细于中段');
      // 末段仍是最粗处。
      expect(maxOffsetFromCenterline(outline, 50), closeTo(5, 1e-6));
    });

    test('两点笔画得到胶囊形：左右各外扩半个笔宽', () {
      final outline = buildStrokeOutline(
        points: stroke([(0.2, 0.5), (0.8, 0.5)]),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: base,
        pressure: true,
      );

      final xs = outline.map((p) => p.dx);
      expect(xs.reduce(math.min), closeTo(20 - 5, 1e-6));
      expect(xs.reduce(math.max), closeTo(80 + 5, 1e-6));
      expect(outline.every((p) => p.dx.isFinite && p.dy.isFinite), isTrue);
    });

    test('急转弯不产生 NaN，且折角内侧靠 nonzero 填充消化自交', () {
      final outline = buildStrokeOutline(
        points: stroke([(0.2, 0.2), (0.5, 0.2), (0.5, 0.8)]),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: 20,
        pressure: true,
      );

      expect(outline, isNotEmpty);
      expect(outline.every((p) => p.dx.isFinite && p.dy.isFinite), isTrue);
      // 轮廓必须有面积：退化时会塌成一条线。
      final path = outlineToPath(outline);
      final bounds = path.getBounds();
      expect(bounds.width, greaterThan(20));
      expect(bounds.height, greaterThan(50));
    });

    test('重复点（零长度段）沿用上一方向，不除零', () {
      final outline = buildStrokeOutline(
        points: stroke([(0.3, 0.5), (0.3, 0.5), (0.7, 0.5)]),
        spaceWidth: spaceW,
        spaceHeight: spaceH,
        baseWidth: base,
        pressure: true,
      );

      expect(outline.every((p) => p.dx.isFinite && p.dy.isFinite), isTrue);
      expect(maxOffsetFromCenterline(outline, 50), closeTo(5, 1e-6));
    });

    test('换空间只缩放形状：文档坐标与屏幕坐标得到同一轮廓', () {
      // 画布传屏幕矩形、SVG 传文档像素，两者宽高比相同。
      // 若轮廓在归一化空间生成，这里会因 x/y 缩放不同而失真。
      final small = buildStrokeOutline(
        points: stroke(
          [(0.2, 0.3), (0.5, 0.6), (0.8, 0.3)],
          pressures: [0.4, 0.8, 0.6],
        ),
        spaceWidth: 100,
        spaceHeight: 200,
        baseWidth: 6,
        pressure: true,
      );
      final large = buildStrokeOutline(
        points: stroke(
          [(0.2, 0.3), (0.5, 0.6), (0.8, 0.3)],
          pressures: [0.4, 0.8, 0.6],
        ),
        spaceWidth: 300,
        spaceHeight: 600,
        baseWidth: 18,
        pressure: true,
      );

      expect(large, hasLength(small.length));
      for (var i = 0; i < small.length; i++) {
        expect(large[i].dx, closeTo(small[i].dx * 3, 1e-9));
        expect(large[i].dy, closeTo(small[i].dy * 3, 1e-9));
      }
    });
  });

  group('outlineToPath', () {
    test('空轮廓得到空路径', () {
      expect(outlineToPath(const []).getBounds(), Rect.zero);
    });

    test('平移量与轮廓坐标相加', () {
      final outline = buildStrokeOutline(
        points: const [
          rust.StrokePoint(x: 0.1, y: 0.5, pressure: 1, timestampMs: 0),
          rust.StrokePoint(x: 0.9, y: 0.5, pressure: 1, timestampMs: 0),
        ],
        spaceWidth: 100,
        spaceHeight: 100,
        baseWidth: 10,
      );
      final plain = outlineToPath(outline).getBounds();
      final shifted =
          outlineToPath(outline, translate: const Offset(30, 40)).getBounds();

      expect(shifted.left, closeTo(plain.left + 30, 1e-6));
      expect(shifted.top, closeTo(plain.top + 40, 1e-6));
      expect(shifted.width, closeTo(plain.width, 1e-6));
    });
  });

}
