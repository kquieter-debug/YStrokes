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

  group('翻转', () {
    test('水平翻转把点左右镜像，垂直翻转只改 y', () {
      const transform = StrokeTransform(flipX: true);
      expect(
        transform.apply(const Offset(0.2, 0.3), const Offset(0.5, 0.5)),
        const Offset(0.8, 0.3),
      );

      const vertical = StrokeTransform(flipY: true);
      expect(
        vertical.apply(const Offset(0.2, 0.3), const Offset(0.5, 0.5)),
        const Offset(0.2, 0.7),
      );
    });

    test('翻转算「非恒等」，因此会进撤销栈', () {
      expect(const StrokeTransform(flipX: true).isIdentity, isFalse);
      expect(const StrokeTransform(flipY: true).isIdentity, isFalse);
      expect(
        const StrokeTransform(flipX: true),
        isNot(const StrokeTransform()),
      );
    });

    test('翻转与缩放叠加时先缩放后镜像，宽度不变', () {
      final strokes = [line([(0.2, 0.2)], widthRatio: 0.02)];
      final flipped = transformStrokes(
        strokes,
        const StrokeTransform(flipX: true, scale: 2),
        const Offset(0.5, 0.5),
      );

      // (0.2 - 0.5) * 2 = -0.6 → 镜像后 +0.6 → 0.5 + 0.6 = 1.1
      expect(flipped.single.points.single.x, closeTo(1.1, 1e-9));
      expect(flipped.single.widthRatio, closeTo(0.04, 1e-9));
    });

    test('两次水平翻转回到原处', () {
      final strokes = [line([(0.2, 0.7), (0.8, 0.3)])];
      final once = transformStrokes(
        strokes,
        const StrokeTransform(flipX: true),
        const Offset(0.5, 0.5),
      );
      final twice = transformStrokes(
        once,
        const StrokeTransform(flipX: true),
        const Offset(0.5, 0.5),
      );

      expect(twice.single.points.first.x, closeTo(0.2, 1e-9));
      expect(twice.single.points.last.y, closeTo(0.3, 1e-9));
    });
  });

  group('按多边形切分折线', () {
    final square = <Offset>[
      const Offset(0.3, 0.3),
      const Offset(0.7, 0.3),
      const Offset(0.7, 0.7),
      const Offset(0.3, 0.7),
    ];

    List<rust.StrokePoint> pts(List<(double, double)> input) => [
          for (final (x, y) in input)
            rust.StrokePoint(x: x, y: y, pressure: 1, timestampMs: 0),
        ];

    test('整条在内：返回单段，点数不变', () {
      final fragments = splitPolylineAtPolygon(
        pts([(0.4, 0.4), (0.5, 0.5), (0.6, 0.6)]),
        square,
      );
      expect(fragments, hasLength(1));
      expect(fragments.single, hasLength(3));
    });

    test('整条在外：返回空', () {
      final fragments = splitPolylineAtPolygon(
        pts([(0.0, 0.0), (0.1, 0.1)]),
        square,
      );
      expect(fragments, isEmpty);
    });

    test('横穿一次：只保留区域内那一段，端点落在边界上', () {
      final fragments = splitPolylineAtPolygon(
        pts([(0.1, 0.5), (0.9, 0.5)]),
        square,
      );
      expect(fragments, hasLength(1));
      expect(fragments.single.first.x, closeTo(0.3, 1e-6));
      expect(fragments.single.last.x, closeTo(0.7, 1e-6));
    });

    test('穿出再穿入：切成两段', () {
      final fragments = splitPolylineAtPolygon(
        pts([(0.4, 0.4), (0.9, 0.4), (0.9, 0.6), (0.4, 0.6)]),
        square,
      );
      expect(fragments, hasLength(2));
      expect(fragments[0].last.x, closeTo(0.7, 1e-6));
      expect(fragments[1].first.x, closeTo(0.7, 1e-6));
    });

    test('切点上的压力按比例插值', () {
      final points = [
        rust.StrokePoint(x: 0.1, y: 0.5, pressure: 0.2, timestampMs: 0),
        rust.StrokePoint(x: 0.9, y: 0.5, pressure: 1.0, timestampMs: 100),
      ];
      final fragments = splitPolylineAtPolygon(points, square);
      // 切点位于 x=0.3，占总长的 25%。
      expect(fragments.single.first.pressure, closeTo(0.4, 0.01));
      expect(fragments.single.first.timestampMs, closeTo(25, 1));
    });

    test('顶点正好压在边界上：之后露在外面的那截也要裁掉', () {
      // 采样点 (0.7, 0.5) 恰好落在正方形的右边上：射线法判它在外，交点参数退化成 1
      // 被丢弃，若不额外校正内外状态，右半段就会被整段留在区内。
      final fragments = splitPolylineAtPolygon(
        pts([(0.4, 0.5), (0.55, 0.5), (0.7, 0.5), (0.85, 0.5), (0.95, 0.5)]),
        square,
      );
      expect(fragments, hasLength(1));
      expect(fragments.single.last.x, closeTo(0.7, 1e-9));
    });

    test('整个顶点序列都在边界左侧外：返回空', () {
      final fragments = splitPolylineAtPolygon(
        pts([(0.75, 0.5), (0.85, 0.5)]),
        square,
      );
      expect(fragments, isEmpty);
    });

    test('点列不足或多边形退化时原样返回', () {
      expect(splitPolylineAtPolygon(pts([(0.5, 0.5)]), square), hasLength(1));
      expect(
        splitPolylineAtPolygon(pts([(0.1, 0.5), (0.9, 0.5)]), const <Offset>[]),
        hasLength(1),
      );
    });
  });
}
