import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/transform_geometry.dart';

/// 变换几何：纯函数，不涉及画布与视口。
void main() {
  Stroke line(
    List<(double, double)> points, {
    int id = 0,
    double widthRatio = 0.02,
    ToolKind tool = ToolKind.brush,
  }) =>
      Stroke(
        id: id,
        tool: tool,
        color: 0xFF000000,
        widthRatio: widthRatio,
        points: <rust.StrokePoint>[
          for (final (x, y) in points)
            rust.StrokePoint(x: x, y: y, pressure: 1, timestampMs: 0),
        ],
        usesPressure: false,
      );

  group('StrokeTransform', () {
    const pivot = Offset(0.5, 0.5);
    const point = Offset(0.6, 0.5);

    test('默认参数不改变任何点', () {
      expect(const StrokeTransform().isIdentity, isTrue);
      expect(const StrokeTransform().apply(point, pivot), point);
    });

    test('平移按归一化单位叠加', () {
      const transform = StrokeTransform(offset: Offset(0.1, -0.2));
      expect(
        transform.apply(point, pivot),
        const Offset(0.7, 0.3),
      );
    });

    test('缩放绕 pivot 生效', () {
      const transform = StrokeTransform(scale: 2);
      expect(transform.apply(point, pivot), const Offset(0.7, 0.5));
    });

    test('旋转 90° 把右侧点转到下方', () {
      const transform = StrokeTransform(rotation: 1.5707963267948966);
      final moved = transform.apply(point, pivot);
      expect(moved.dx, closeTo(0.5, 1e-9));
      expect(moved.dy, closeTo(0.6, 1e-9));
    });

    test('值相等语义可用于缓存比较', () {
      expect(
        const StrokeTransform(scale: 1.5, rotation: 0.2),
        const StrokeTransform(scale: 1.5, rotation: 0.2),
      );
    });
  });

  group('transformStrokes', () {
    test('笔宽随等比缩放', () {
      final strokes = [line([(0.2, 0.2), (0.4, 0.4)], widthRatio: 0.02)];
      final moved = transformStrokes(
        strokes,
        const StrokeTransform(scale: 2),
        const Offset(0.3, 0.3),
      );

      expect(moved.single.widthRatio, closeTo(0.04, 1e-9));
      expect(moved.single.points.first.x, closeTo(0.1, 1e-9));
    });

    test('缩放后笔宽被夹在安全范围内', () {
      final strokes = [line([(0.5, 0.5)], widthRatio: 0.2)];
      final moved = transformStrokes(
        strokes,
        const StrokeTransform(scale: 10),
        const Offset(0.5, 0.5),
      );

      expect(moved.single.widthRatio, lessThanOrEqualTo(0.25));
    });

    test('不变换时返回副本而不是同一列表', () {
      final strokes = [line([(0.1, 0.1)])];
      final copy = transformStrokes(strokes, StrokeTransform.identity, Offset.zero);

      expect(copy, isNot(same(strokes)));
      expect(copy.single, same(strokes.single), reason: '身份不变就不该复制对象');
    });

    test('只变换被选中的笔画', () {
      final strokes = [
        line([(0.2, 0.2)], id: 1),
        line([(0.8, 0.8)], id: 2),
      ];
      final moved = transformSelection(
        strokes,
        <int>{1},
        const StrokeTransform(offset: Offset(0.1, 0)),
        Offset.zero,
      );

      expect(moved[0].points.first.x, closeTo(0.3, 1e-9));
      expect(moved[1], same(strokes[1]), reason: '未选中的笔画保持原对象');
    });
  });

  group('boundsOfStrokes', () {
    test('包含笔宽，单点笔画也有面积', () {
      final single = [line([(0.5, 0.5)], widthRatio: 0.1)];
      final bounds = boundsOfStrokes(single);

      expect(bounds.width, closeTo(0.1, 1e-9));
      expect(bounds.isEmpty, isFalse);
    });

    test('空集合返回零矩形', () {
      expect(boundsOfStrokes(const <Stroke>[]), Rect.zero);
    });
  });

  group('套索命中', () {
    final square = <Offset>[
      const Offset(0.3, 0.3),
      const Offset(0.7, 0.3),
      const Offset(0.7, 0.7),
      const Offset(0.3, 0.7),
    ];

    test('点在多边形内外的判定', () {
      expect(polygonContains(const Offset(0.5, 0.5), square), isTrue);
      expect(polygonContains(const Offset(0.1, 0.5), square), isFalse);
    });

    test('整条落在区域内算命中', () {
      final stroke = line([(0.4, 0.4), (0.6, 0.6)]);
      expect(strokeTouchesPolygon(stroke, square), isTrue);
    });

    test('横穿区域但采样点都在外面也算命中', () {
      // 两点都在 x∈[0.3,0.7] 之外，线段中段穿过方框。
      final stroke = line([(0.1, 0.5), (0.9, 0.5)]);
      expect(
        strokeTouchesPolygon(stroke, square),
        isTrue,
        reason: '只判「点是否在内部」会漏掉高速划过的长笔画',
      );
    });

    test('完全在外面的笔画不命中', () {
      final stroke = line([(0.0, 0.0), (0.1, 0.1)]);
      expect(strokeTouchesPolygon(stroke, square), isFalse);
    });

    test('命中集合按 id 去重', () {
      final strokes = [
        line([(0.4, 0.4)], id: 7),
        line([(0.0, 0.0)], id: 8),
      ];
      expect(strokesInPolygon(strokes, square), <int>{7});
    });
  });
}
