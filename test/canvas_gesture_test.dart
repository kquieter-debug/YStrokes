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

    // 放弃画笔后，清空按钮应保持禁用（当前图层没有笔画）。
    final clear = buttonWithTooltip(tester, '清空当前图层');
    expect(clear.onPressed, isNull);
  });
}
