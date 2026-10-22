import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/services/edit_journal.dart';
import 'package:ystrokes/src/services/color_picker.dart';

/// 选区工具与两类变换（选集 / 整层）的界面契约。
///
/// 几何正确性在 `transform_geometry_test.dart` 里单测；这里只确认
/// 「工具能选中、套索能命中、操作条能出现与消失、入口能走通」。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('ystrokes_selection_');
  });

  tearDown(() async {
    // 画板里还有未完成的落盘 / 日志追加在跑，Windows 会锁住文件；
    // 临时目录删不掉不影响断言，忽略即可。
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // ignore
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
              '选区',
              id: 'selection',
              document: const DocumentSpec(
                widthPx: 1080,
                heightPx: 1920,
                dpi: 72,
              ),
            ),
            documentStore: DocumentStore(rootDirectory: temp),
            journal: EditJournal(rootDirectory: temp),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 在画面上部画一条横线。避开左中悬浮的工具栏与顶栏。
  Future<void> drawStroke(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(150, 200));
    await gesture.moveTo(const Offset(250, 210));
    await gesture.moveTo(const Offset(350, 220));
    await gesture.up();
    await tester.pump();
  }

  /// 用套索切一个矩形区域。[from]/[to] 为屏幕坐标。
  Future<void> lasso(WidgetTester tester, Offset from, Offset to) async {
    await tester.tap(find.byTooltip('选区'));
    await tester.pump();

    final gesture = await tester.startGesture(from);
    await gesture.moveTo(Offset(to.dx, from.dy));
    await gesture.moveTo(to);
    await gesture.moveTo(Offset(from.dx, to.dy));
    await gesture.moveTo(from);
    await gesture.up();
    await tester.pump();
  }

  testWidgets('工具栏里有选区与吸管', (tester) async {
    await pumpCanvas(tester);

    expect(find.byTooltip('选区'), findsOneWidget);
    expect(find.byTooltip('吸管'), findsOneWidget);
  });

  testWidgets('圈住笔画后出现变换操作条，取消即消失', (tester) async {
    await pumpCanvas(tester);
    await drawStroke(tester);

    await lasso(tester, const Offset(100, 150), const Offset(390, 280));

    expect(find.byKey(const Key('transform-commit')), findsOneWidget);
    expect(find.text('选区变换'), findsOneWidget);

    await tester.tap(find.byKey(const Key('transform-cancel')));
    await tester.pump();
    expect(find.byKey(const Key('transform-commit')), findsNothing);
  });

  testWidgets('圈到空白处给出提示，不产生操作条', (tester) async {
    await pumpCanvas(tester);

    await lasso(tester, const Offset(120, 560), const Offset(370, 700));

    expect(find.byKey(const Key('transform-commit')), findsNothing);
    expect(find.text('未选中笔画'), findsOneWidget);
  });

  testWidgets('拖动框内会产生预览，提交后操作条消失', (tester) async {
    await pumpCanvas(tester);
    await drawStroke(tester);
    await lasso(tester, const Offset(100, 150), const Offset(390, 280));

    // 从选区中部拖动：命中「移动」。
    final gesture = await tester.startGesture(const Offset(250, 212));
    await gesture.moveTo(const Offset(270, 262));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(find.byKey(const Key('transform-commit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('transform-commit')));
    await tester.pump();
    expect(find.byKey(const Key('transform-commit')), findsNothing);
  });

  testWidgets('图层面板提供复制图层与变换图层', (tester) async {
    await pumpCanvas(tester);
    await drawStroke(tester);

    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('图层操作'));
    await tester.pumpAndSettle();

    expect(find.text('复制图层'), findsOneWidget);
    expect(find.text('变换图层'), findsOneWidget);

    await tester.tap(find.text('变换图层'));
    await tester.pumpAndSettle();

    expect(find.text('整层变换'), findsOneWidget);
    expect(find.byKey(const Key('transform-commit')), findsOneWidget);
  });

  testWidgets('复制图层后层数增加', (tester) async {
    await pumpCanvas(tester);
    await drawStroke(tester);

    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    expect(find.text('图层'), findsOneWidget);

    await tester.tap(find.byTooltip('图层操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制图层'));
    await tester.pumpAndSettle();

    expect(find.text('副本').hitTestable(), findsNothing);
    expect(find.textContaining('副本'), findsOneWidget);
  });

  testWidgets('长按选区工具弹出选区气泡', (tester) async {
    await pumpCanvas(tester);

    await tester.longPress(find.byTooltip('选区'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selection-bubble')), findsOneWidget);
    expect(find.textContaining('拖出一个闭合区域'), findsOneWidget);

    await tester.tapAt(const Offset(360, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selection-bubble')), findsNothing);
  });

  testWidgets('吸管：取到纸色后回到上一个绘画工具', (tester) async {
    await pumpCanvas(tester);
    await drawStroke(tester);

    await tester.tap(find.byTooltip('吸管'));
    await tester.pump();

    // 点在纸面空白处：取到纸色。取样要真正光栅化，必须让异步在真实时钟里跑完。
    await tester.runAsync(() async {
      await tester.tapAt(const Offset(300, 640));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 回到画笔后，长按打开气泡应能看到取到的颜色。
    await tester.longPress(find.byTooltip('画笔'));
    await tester.pumpAndSettle();
    final paper = Color(
      const DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72)
          .backgroundArgb,
    );
    final hex = paper.toARGB32().toRadixString(16).padLeft(8, '0');
    expect(find.text('#${hex.substring(2).toUpperCase()}'), findsOneWidget);
  });

  group('取样服务', () {
    testWidgets('取到画面内的颜色，画面外回落纸色', (tester) async {
      late Color inside;
      late Color outside;

      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 10, 10),
          Paint()..color = const Color(0xFFEF4444),
        );
        final picture = recorder.endRecording();

        inside = await sampleColorAt(
          picture: picture,
          docPoint: const Offset(5, 5),
          fallback: const Color(0xFFFFFFFF),
        );
        outside = await sampleColorAt(
          picture: picture,
          docPoint: const Offset(100, 100),
          fallback: const Color(0xFFFFFFFF),
        );
        picture.dispose();
      });

      expect(inside.toARGB32(), 0xFFEF4444);
      expect(outside.toARGB32(), 0xFFFFFFFF, reason: '透明处应回落纸色');
    });
  });
}
