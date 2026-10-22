import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/drawing_engine.dart';
import 'package:ystrokes/src/widgets/layers_bubble.dart';

/// 图层气泡的定位与关闭契约。
///
/// 定位规则不是审美选择而是硬约束：它必须贴屏幕右缘、从上沿向下展开，
/// 否则会盖住画布中央（首版曾对齐「图层」按钮，结果面板整体左移约 90dp）。
void main() {
  late DrawingEngine engine;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    engine = DrawingEngine();
    engine.load(const <DrawingLayer>[]);
    engine.addLayer(name: '上层');
  });

  void addLine() {
    engine.addStroke(
      <rust.StrokePoint>[
        rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
      ],
      tool: ToolKind.brush,
      color: 0xFF000000,
      widthRatio: 0.01,
      usesPressure: false,
    );
  }

  /// [anchor] 模拟顶栏「图层」按钮：右侧还有三个按钮，因此右边缘离屏幕右缘约 96。
  Future<void> pumpBubble(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    void Function()? onClose,
    void Function()? onCleared,
    void Function(String)? onTransform,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    final anchorBottom = 48.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayersBubble(
            engine: engine,
            anchor: Rect.fromLTRB(size.width - 192, 8, size.width - 144, anchorBottom),
            onChanged: () {},
            onCleared: onCleared ?? () {},
            onTransform: onTransform ?? (_) {},
            onFlip: (_, _) {},
            onAddRaster: () {},
            onRasterize: (_) async {},
            onClose: onClose ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect bubbleRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('layers-bubble')));

  testWidgets('贴屏幕右缘，且从锚点下方向下展开', (tester) async {
    await pumpBubble(tester);
    final rect = bubbleRect(tester);

    // 右缘只留 10dp 的间距：与锚点按钮的位置无关。
    expect(rect.right, 400 - 10);
    // 上沿在按钮下方。
    expect(rect.top, greaterThan(48));
    expect(rect.top, lessThan(60));
    // 宽度受上限约束（320），不会盖住画布中线（x=200）。
    expect(rect.width, lessThanOrEqualTo(320));
    expect(rect.left, greaterThan(50));
  });

  testWidgets('窄屏上按可用宽度收窄，不越界', (tester) async {
    await pumpBubble(tester, size: const Size(280, 640));
    final rect = bubbleRect(tester);

    expect(rect.left, greaterThanOrEqualTo(9));
    expect(rect.right, lessThanOrEqualTo(280 - 9));
  });

  testWidgets('点气泡外关闭', (tester) async {
    var closes = 0;
    await pumpBubble(tester, onClose: () => closes++);

    expect(closes, 0);
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    expect(closes, 1);
  });

  testWidgets('点气泡内部不关闭', (tester) async {
    var closes = 0;
    await pumpBubble(tester, onClose: () => closes++);

    await tester.tap(find.text('图层'));
    await tester.pumpAndSettle();

    expect(closes, 0);
  });

  testWidgets('清空图层：确认后先通知画板再请求关闭', (tester) async {
    addLine();
    final events = <String>[];
    await pumpBubble(
      tester,
      onCleared: () => events.add('cleared'),
      onClose: () => events.add('close'),
    );

    await tester.tap(find.byKey(const Key('layer-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layer-clear-confirm')));
    await tester.pumpAndSettle();

    expect(engine.activeLayer.strokes, isEmpty);
    // 顺序有意义：先让画板弹提示，再关气泡，否则提示会被一起关掉。
    expect(events, <String>['cleared', 'close']);
  });

  testWidgets('取消清空时不通知也不关闭', (tester) async {
    addLine();
    var closes = 0;
    var cleared = 0;
    await pumpBubble(
      tester,
      onClose: () => closes++,
      onCleared: () => cleared++,
    );

    await tester.tap(find.byKey(const Key('layer-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(cleared, 0);
    expect(closes, 0);
    expect(engine.activeLayer.strokes, hasLength(1));
  });
}
