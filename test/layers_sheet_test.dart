import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/rust/api/document.dart' show LayerBlendMode;
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/drawing_engine.dart';
import 'package:ystrokes/src/widgets/layers_sheet.dart';

/// 图层面板的交互：重命名、混合模式、向下合并。
void main() {
  late DrawingEngine engine;

  setUp(() {
    engine = DrawingEngine();
    engine.load(const <DrawingLayer>[]);
  });

  void addLine() {
    engine.addStroke(
      <rust.StrokePoint>[
        rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
      ],
      tool: ToolKind.brush,
      color: 0xFF000000,
      widthRatio: 0.01,
    );
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayersSheet(engine: engine, onChanged: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester, {int index = 0}) async {
    await tester.tap(find.byIcon(Icons.more_vert).at(index));
    await tester.pumpAndSettle();
  }

  testWidgets('通过菜单重命名图层', (tester) async {
    engine.addLayer(name: '上层');
    await pumpSheet(tester);

    await openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('layer-rename-field')), '线稿');
    await tester.tap(find.byKey(const Key('layer-rename-confirm')));
    await tester.pumpAndSettle();

    expect(engine.layers.last.name, '线稿');
    expect(find.text('线稿'), findsOneWidget);
  });

  testWidgets('切换混合模式', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('layer-blend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正片叠底').last);
    await tester.pumpAndSettle();

    expect(engine.activeLayer.blendMode, LayerBlendMode.multiply);
  });

  testWidgets('默认参数下向下合并无需确认', (tester) async {
    engine.addLayer(name: '上层');
    addLine(); // 顶层一笔
    await pumpSheet(tester);

    await openMenu(tester);
    await tester.tap(find.text('向下合并'));
    await tester.pumpAndSettle();

    expect(find.text('该图层带有不透明度或混合模式，合并后外观可能发生变化。'), findsNothing);
    expect(engine.layers, hasLength(1));
    expect(engine.layers.single.strokes, hasLength(1));
  });

  testWidgets('带不透明度时合并需二次确认', (tester) async {
    engine.addLayer(name: '上层');
    addLine();
    engine.setLayerOpacity(engine.activeLayerId, 0.4);
    await pumpSheet(tester);

    await openMenu(tester);
    await tester.tap(find.text('向下合并'));
    await tester.pumpAndSettle();

    expect(
      find.text('该图层带有不透明度或混合模式，合并后外观可能发生变化。'),
      findsOneWidget,
    );

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(engine.layers, hasLength(1));
  });

  testWidgets('长按拖拽排序：松手后才改写引擎顺序', (tester) async {
    engine.addLayer(name: '上层');
    await pumpSheet(tester);

    final topCenter = tester.getCenter(find.text('上层'));
    final bottomCenter = tester.getCenter(find.text('图层 1'));

    final gesture = await tester.startGesture(topCenter);
    // 超过长按阈值，进入拖拽态。
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(bottomCenter);
    await tester.pump();

    // 拖动过程中引擎顺序不应改变（默认关闭即时渲染）。
    expect(engine.layers.last.name, '上层', reason: '拖拽中不提交');

    await gesture.up();
    await tester.pumpAndSettle();

    expect(engine.layers.last.name, '图层 1');
    expect(engine.layers.first.name, '上层');
  });

  testWidgets('最底层不提供合并项', (tester) async {
    await pumpSheet(tester);

    await openMenu(tester);
    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('已在最底层'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(item.enabled, isFalse);
  });
}
