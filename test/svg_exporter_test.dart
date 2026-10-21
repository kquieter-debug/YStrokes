import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/rust/api/document.dart' show LayerBlendMode;
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/svg_exporter.dart';

/// SVG 生成：结构、路径、蒙版、图层属性与转义。
void main() {
  const document = DocumentSpec(widthPx: 100, heightPx: 200, dpi: 72);

  Stroke stroke({
    required List<(double, double)> points,
    double widthRatio = 0.1,
    ToolKind tool = ToolKind.brush,
    int color = 0xFFEF4444,
  }) =>
      Stroke(
        id: 0,
        tool: tool,
        color: color,
        widthRatio: widthRatio,
        points: <rust.StrokePoint>[
          for (final (x, y) in points)
            rust.StrokePoint(x: x, y: y, pressure: 1, timestampMs: 0),
        ],
      );

  DrawingLayer layer({
    String name = '图层',
    bool visible = true,
    double opacity = 1.0,
    LayerBlendMode blend = LayerBlendMode.normal,
    List<Stroke>? strokes,
  }) =>
      DrawingLayer(
        id: 'layer-0',
        name: name,
        visible: visible,
        opacity: opacity,
        blendMode: blend,
        strokes: strokes ?? [stroke(points: const [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)])],
      );

  test('根元素尺寸来自文档规格', () {
    final svg = buildDocumentSvg(document: document, layers: [layer()]);

    expect(svg, startsWith('<?xml'));
    expect(svg, contains('width="100" height="200" viewBox="0 0 100 200"'));
    expect(svg.trimRight(), endsWith('</svg>'));
  });

  test('多点笔画输出与画布一致的二次贝塞尔路径', () {
    final svg = buildDocumentSvg(document: document, layers: [layer()]);

    // 归一化 × 文档尺寸；端点取相邻点中值，控制点取原始点。
    expect(
      svg,
      contains(
        'd="M 10 20 Q 50 100 70 140 L 90 180"',
      ),
    );
    // 笔宽 = 0.1 × 短边 100 = 10。
    expect(svg, contains('stroke-width="10"'));
    expect(svg, contains('stroke="#EF4444"'));
    expect(svg, contains('stroke-linecap="round"'));
  });

  test('单点笔画输出圆点', () {
    final svg = buildDocumentSvg(
      document: document,
      layers: [layer(strokes: [stroke(points: const [(0.5, 0.5)])])],
    );

    expect(svg, contains('<circle cx="50" cy="100" r="5" fill="#EF4444"/>'));
  });

  test('橡皮转成蒙版，而不是被丢弃', () {
    final svg = buildDocumentSvg(
      document: document,
      layers: [
        layer(
          strokes: [
            stroke(points: const [(0.1, 0.1), (0.9, 0.9)]),
            stroke(
              points: const [(0.2, 0.2), (0.8, 0.8)],
              tool: ToolKind.eraser,
            ),
          ],
        ),
      ],
    );

    expect(svg, contains('<mask id="erase-1"'));
    expect(svg, contains('mask="url(#erase-1)"'));
    // 蒙版内白色铺底 + 黑色擦除路径。
    expect(svg, contains('fill="#FFFFFF"'));
    expect(svg, contains('stroke="#000000"'));
  });

  test('隐藏图层与空图层不参与输出', () {
    final svg = buildDocumentSvg(
      document: document,
      layers: [
        layer(name: '可见'),
        layer(name: '隐藏', visible: false),
        DrawingLayer(id: 'empty', name: '空层'),
      ],
    );

    expect(svg, contains('data-name="可见"'));
    expect(svg, isNot(contains('data-name="隐藏"')));
    expect(svg, isNot(contains('data-name="空层"')));
  });

  test('不透明度与混合模式落到所在分组', () {
    final svg = buildDocumentSvg(
      document: document,
      layers: [
        layer(opacity: 0.5, blend: LayerBlendMode.multiply),
        layer(name: '正常层', blend: LayerBlendMode.normal),
      ],
    );

    expect(svg, contains('opacity="0.5"'));
    expect(svg, contains('style="mix-blend-mode:multiply"'));
    // 「正常」不输出 mix-blend-mode。
    expect(
      svg.split('mix-blend-mode').length - 1,
      1,
      reason: '仅非正常模式输出该属性',
    );
  });

  test('图层名中的特殊字符被转义', () {
    final svg = buildDocumentSvg(
      document: document,
      layers: [layer(name: 'a&b<c>"d\'e')],
    );

    expect(svg, contains('data-name="a&amp;b&lt;c&gt;&quot;d&apos;e"'));
  });

  test('空文档也产出合法 SVG', () {
    final svg = buildDocumentSvg(document: document, layers: const []);

    expect(svg, contains('<svg'));
    expect(svg, isNot(contains('<g ')));
  });
}
