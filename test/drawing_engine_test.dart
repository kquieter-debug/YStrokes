import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/rust/api/document.dart' show LayerBlendMode;
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/drawing_engine.dart';

/// 图层模型与撤销/重做。
void main() {
  late DrawingEngine engine;

  setUp(() {
    engine = DrawingEngine();
    engine.load(const <DrawingLayer>[]);
  });

  void addLine() {
    engine.addStroke(
      <rust.StrokePoint>[
        rust.StrokePoint(x: 0.1, y: 0.1, pressure: 1, timestampMs: 0),
      ],
      tool: ToolKind.brush,
      color: 0xFF000000,
      widthRatio: 0.01,
      usesPressure: false,
    );
  }

  test('载入空文档后至少有一个图层且处于选中状态', () {
    expect(engine.layers, hasLength(1));
    expect(engine.activeLayerId, engine.layers.first.id);
    expect(engine.isEmpty, isTrue);
  });

  test('笔画写入当前图层', () {
    addLine();
    expect(engine.layers.first.strokes, hasLength(1));
    expect(engine.activeLayer.strokes, hasLength(1));
    expect(engine.isEmpty, isFalse);
  });

  test('新建图层插入到当前层上方并自动选中', () {
    final bottom = engine.activeLayer;
    final added = engine.addLayer();

    expect(engine.layers, hasLength(2));
    expect(engine.layers.last.id, added.id, reason: '新层在上方');
    expect(engine.layers.first.id, bottom.id);
    expect(engine.activeLayerId, added.id);
  });

  test('新笔画只落在选中层，切换后互不影响', () {
    final bottom = engine.activeLayer;
    addLine();

    final top = engine.addLayer();
    addLine();
    addLine();

    expect(engine.layers.first.strokes, hasLength(1));
    expect(engine.layers.last.strokes, hasLength(2));
    expect(top.id, engine.activeLayerId);
    expect(bottom.strokes, hasLength(1));
  });

  test('只剩一个图层时拒绝删除', () {
    expect(engine.removeLayer(engine.activeLayerId), isFalse);
    expect(engine.layers, hasLength(1));
  });

  test('删除选中层后选中共相邻层', () {
    final bottom = engine.activeLayer;
    final top = engine.addLayer();

    expect(engine.removeLayer(top.id), isTrue);
    expect(engine.layers, hasLength(1));
    expect(engine.activeLayerId, bottom.id);
  });

  test('撤销笔画：按图层归属移除，不会误删其它层', () {
    final top = engine.addLayer();
    addLine(); // 顶层
    engine.selectLayer(engine.layers.first.id);
    addLine(); // 底层

    expect(engine.layers.first.strokes, hasLength(1));
    expect(engine.layers.last.strokes, hasLength(1));

    expect(engine.undo(), isTrue);
    expect(engine.layers.first.strokes, isEmpty, reason: '撤销的是底层那一笔');
    expect(engine.layers.last.strokes, hasLength(1));

    expect(engine.redo(), isTrue);
    expect(engine.layers.first.strokes, hasLength(1));
    expect(engine.activeLayerId, isNotEmpty);
    expect(top.id, engine.layers.last.id);
  });

  test('撤销新建图层会移除该层', () {
    engine.addLayer();
    expect(engine.layers, hasLength(2));

    expect(engine.undo(), isTrue);
    expect(engine.layers, hasLength(1));
  });

  test('删除图层可撤销', () {
    final bottom = engine.activeLayer;
    final top = engine.addLayer();
    addLine();
    engine.removeLayer(top.id);

    expect(engine.layers, hasLength(1));

    expect(engine.undo(), isTrue);
    expect(engine.layers, hasLength(2));
    expect(engine.layers.last.id, top.id);
    expect(engine.layers.last.strokes, hasLength(1), reason: '图层内容应一并恢复');
    expect(engine.layers.first.id, bottom.id);
  });

  test('清空只作用于当前图层，且可撤销', () {
    addLine();
    final bottom = engine.activeLayer;
    final top = engine.addLayer();
    addLine();

    expect(engine.clear(), isTrue);
    expect(engine.layers.last.strokes, isEmpty);
    expect(engine.layers.first.strokes, hasLength(1), reason: '底层不受影响');

    expect(engine.undo(), isTrue);
    expect(engine.layers.last.strokes, hasLength(1));
    expect(top.id, engine.layers.last.id);
    expect(bottom.strokes, hasLength(1));
  });

  test('不透明度与可见性会夹取到合法范围并递增版本号', () {
    final layer = engine.activeLayer;
    final before = engine.revision;

    engine.setLayerOpacity(layer.id, 0.4);
    expect(layer.opacity, closeTo(0.4, 1e-9));
    expect(engine.revision, greaterThan(before));

    engine.setLayerOpacity(layer.id, 5);
    expect(layer.opacity, 1.0);

    engine.setLayerOpacity(layer.id, -1);
    expect(layer.opacity, 0.0);

    engine.setLayerVisible(layer.id, false);
    expect(layer.visible, isFalse);
  });

  test('混合模式可设置并递增版本号', () {
    final layer = engine.activeLayer;
    final before = engine.revision;

    engine.setLayerBlendMode(layer.id, LayerBlendMode.multiply);
    expect(layer.blendMode, LayerBlendMode.multiply);
    expect(engine.revision, greaterThan(before));
  });

  test('重命名图层可撤销', () {
    final layer = engine.activeLayer;
    expect(engine.renameLayer(layer.id, '  线稿  '), isTrue);
    expect(layer.name, '线稿', reason: '首尾空白应被裁剪');

    expect(engine.undo(), isTrue);
    expect(layer.name, '图层 1');
  });

  test('空名或同名不写盘也不产生撤销记录', () {
    final layer = engine.activeLayer;
    final before = engine.revision;

    expect(engine.renameLayer(layer.id, '   '), isFalse);
    expect(engine.renameLayer(layer.id, layer.name), isFalse);
    expect(engine.revision, before, reason: '无效修改不应触发重绘');
    expect(engine.canUndo, isFalse);
  });

  test('移动图层改变顺序且可撤销', () {
    final bottom = engine.activeLayer;
    final top = engine.addLayer();

    expect(engine.layers.first.id, bottom.id);
    expect(engine.moveLayer(1, 0), isTrue);
    expect(engine.layers.first.id, top.id);
    expect(engine.layers.last.id, bottom.id);

    expect(engine.undo(), isTrue);
    expect(engine.layers.first.id, bottom.id);
  });

  test('越界的移动被拒绝', () {
    engine.addLayer();
    expect(engine.moveLayer(0, 5), isFalse);
    expect(engine.moveLayer(-1, 0), isFalse);
    expect(engine.moveLayer(1, 1), isFalse);
  });

  test('向下合并把上方笔画并入下方，并沿用下方参数', () {
    final bottom = engine.activeLayer;
    engine.setLayerOpacity(bottom.id, 0.8);
    addLine();

    final top = engine.addLayer(name: '上层');
    engine.setLayerOpacity(top.id, 0.3);
    engine.setLayerBlendMode(top.id, LayerBlendMode.screen);
    addLine();
    addLine();

    final merged = engine.mergeDown(top.id);

    expect(merged, isNotNull);
    expect(engine.layers, hasLength(1));
    expect(merged!.id, bottom.id, reason: '结果保留下方图层');
    expect(merged.strokes, hasLength(3));
    expect(merged.opacity, closeTo(0.8, 1e-9), reason: '沿用下方不透明度');
    expect(merged.blendMode, LayerBlendMode.normal);
    expect(engine.activeLayerId, bottom.id);
  });

  test('向下合并可撤销并恢复两侧内容', () {
    final bottom = engine.activeLayer;
    addLine();
    final top = engine.addLayer(name: '上层');
    addLine();
    addLine();

    engine.mergeDown(top.id);
    expect(engine.layers, hasLength(1));

    expect(engine.undo(), isTrue);
    expect(engine.layers, hasLength(2));
    expect(engine.layers.first.strokes, hasLength(1));
    expect(engine.layers.last.strokes, hasLength(2));
    expect(engine.layers.last.name, '上层');
    expect(engine.layers.last.id, top.id);
    expect(bottom.strokes, hasLength(1));
  });

  test('最底层无法向下合并', () {
    final bottom = engine.activeLayer;
    engine.addLayer();
    expect(engine.mergeDown(bottom.id), isNull);
    expect(engine.layers, hasLength(2));
  });

  test('不可见图层的内容仍会写入，只是不参与合成', () {
    final layer = engine.activeLayer;
    engine.setLayerVisible(layer.id, false);
    addLine();

    expect(layer.visible, isFalse);
    expect(layer.strokes, hasLength(1));
  });

  test('笔画记住画下时的压感标记，撤销重做不丢', () {
    final points = <rust.StrokePoint>[
      rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
      rust.StrokePoint(x: 0.8, y: 0.8, pressure: 0.4, timestampMs: 16),
    ];
    final stroke = engine.addStroke(
      points,
      tool: ToolKind.brush,
      color: 0xFF000000,
      widthRatio: 0.01,
      usesPressure: true,
    );

    expect(stroke.usesPressure, isTrue);
    expect(engine.activeLayer.strokes.single.usesPressure, isTrue);

    // 撤销/重做走的是同一批对象，标记不应丢失。
    expect(engine.undo(), isTrue);
    expect(engine.activeLayer.strokes, isEmpty);
    expect(engine.redo(), isTrue);
    expect(engine.activeLayer.strokes.single.usesPressure, isTrue);
  });
}
