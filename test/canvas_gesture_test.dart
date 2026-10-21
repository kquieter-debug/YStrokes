import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';

/// 双指缩放/旋转的接线：手势生效后「适配画布」按钮应变为可用，点击后复位。
///
/// 视口数学本身已在 `canvas_viewport_test.dart` 中单独验证；这里只确认
/// 指针事件确实驱动了视口，并且复位入口可用。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('ystrokes_gesture_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> pumpCanvas(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            project: DrawingProject.create(
              '手势',
              id: 'gesture',
              document: const DocumentSpec(
                widthPx: 1080,
                heightPx: 1920,
                dpi: 72,
              ),
            ),
            documentStore: DocumentStore(rootDirectory: temp),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  IconButton buttonWithTooltip(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  IconButton resetButton(WidgetTester tester) =>
      buttonWithTooltip(tester, '适配画布');

  testWidgets('双指张开后视口改变，复位按钮恢复可用', (tester) async {
    await pumpCanvas(tester);

    expect(tester.takeException(), isNull);
    expect(resetButton(tester).onPressed, isNull, reason: '初始为适配状态');

    final first = await tester.startGesture(const Offset(150, 300));
    final second = await tester.startGesture(const Offset(250, 300));
    await tester.pump();

    // 双指张开两倍，同时旋转一个小角度。
    await first.moveTo(const Offset(110, 280));
    await second.moveTo(const Offset(290, 320));
    await tester.pump();

    await first.up();
    await second.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      resetButton(tester).onPressed,
      isNotNull,
      reason: '手势后应不再是适配状态',
    );
  });

  testWidgets('点击适配画布后视口复位', (tester) async {
    await pumpCanvas(tester);

    final first = await tester.startGesture(const Offset(150, 300));
    final second = await tester.startGesture(const Offset(250, 300));
    await tester.pump();
    await first.moveTo(const Offset(100, 300));
    await second.moveTo(const Offset(300, 300));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    await tester.tap(find.byTooltip('适配画布'));
    await tester.pump();

    expect(resetButton(tester).onPressed, isNull, reason: '已回到适配状态');
  });

  /// 打开图层面板读取首行摘要（形如「1 笔 · 100%」），随后关闭面板。
  Future<String> layerSummary(WidgetTester tester) async {
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    final text =
        tester.widgetList<Text>(find.textContaining('笔 ·')).first.data!;
    await tester.tapAt(const Offset(20, 100));
    await tester.pumpAndSettle();
    return text;
  }

  /// 一次「双指轻点」：两指同时按下、不移动、同时抬起。
  Future<void> twoFingerTap(WidgetTester tester) async {
    final a = await tester.startGesture(const Offset(150, 300));
    final b = await tester.startGesture(const Offset(260, 300));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
  }

  testWidgets('双指结束后不会误落笔', (tester) async {
    await pumpCanvas(tester);

    final first = await tester.startGesture(const Offset(150, 300));
    final second = await tester.startGesture(const Offset(250, 300));
    await tester.pump();
    await first.moveTo(const Offset(120, 300));
    await second.moveTo(const Offset(280, 300));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    // 放弃画笔后当前图层不应有笔画。
    expect(await layerSummary(tester), startsWith('0 笔'));
  });

  testWidgets('双指双击撤销上一笔', (tester) async {
    await pumpCanvas(tester);

    final stroke = await tester.startGesture(const Offset(120, 320));
    await stroke.moveTo(const Offset(180, 340));
    await stroke.moveTo(const Offset(240, 320));
    await stroke.up();
    await tester.pump();

    expect(await layerSummary(tester), startsWith('1 笔'));

    await twoFingerTap(tester);
    await twoFingerTap(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(await layerSummary(tester), startsWith('0 笔'));
  });

  testWidgets('单次双指轻点不会撤销', (tester) async {
    await pumpCanvas(tester);

    final stroke = await tester.startGesture(const Offset(120, 320));
    await stroke.moveTo(const Offset(200, 330));
    await stroke.up();
    await tester.pump();
    expect(await layerSummary(tester), startsWith('1 笔'));

    await twoFingerTap(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(
      await layerSummary(tester),
      startsWith('1 笔'),
      reason: '双击才撤销，单击只当作一次无操作的双指轻点',
    );
  });

  testWidgets('双指缩放后不会误判为双击撤销', (tester) async {
    await pumpCanvas(tester);

    final stroke = await tester.startGesture(const Offset(120, 320));
    await stroke.moveTo(const Offset(200, 330));
    await stroke.up();
    await tester.pump();
    expect(await layerSummary(tester), startsWith('1 笔'));

    // 两次「双指张开」：视口变了，两次都不能算轻点。
    for (var i = 0; i < 2; i++) {
      final first = await tester.startGesture(const Offset(150, 300));
      final second = await tester.startGesture(const Offset(250, 300));
      await tester.pump();
      await first.moveTo(const Offset(110, 300));
      await second.moveTo(const Offset(290, 300));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));

    expect(await layerSummary(tester), startsWith('1 笔'));
  });
}
