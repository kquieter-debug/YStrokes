import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/services/edit_journal.dart';

/// 位图图层在画板这一层的行为：怎么建、怎么画、以及那些「明确不支持」的入口。
///
/// 像素内容本身由 `raster_brush_test` / `raster_engine_test` 逐像素覆盖；
/// 这里只关心接线是否正确——手势有没有真的落到像素上、选区会不会误报、
/// 矢量路径有没有被改动。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('ystrokes_raster_ui_');
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上文件句柄可能滞后释放。
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
              '位图',
              id: 'raster',
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

  /// 顶部提示横幅会盖住画布上半部分并吃掉手势（测试环境必然保存失败）。
  Future<void> clearNotices(WidgetTester tester) async {
    final close = find.byTooltip('关闭提示');
    for (var i = close.evaluate().length - 1; i >= 0; i--) {
      await tester.tap(close.at(i));
      await tester.pump();
    }
  }

  /// 撤销按钮是否可用。
  bool canUndo(WidgetTester tester) {
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('撤销'),
        matching: find.byType(IconButton),
      ),
    );
    return button.onPressed != null;
  }

  /// 通过图层面板新建一个位图图层。
  Future<void> addRasterLayer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layer-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('位图图层'));
    await tester.pumpAndSettle();
  }

  Future<void> closeLayers(WidgetTester tester) async {
    await tester.tapAt(const Offset(60, 500));
    await tester.pumpAndSettle();
  }

  /// 画一条横线（多点采样，保证像素笔有连续落点）。
  Future<void> drawLine(WidgetTester tester, {required double y}) async {
    await clearNotices(tester);
    final gesture = await tester.startGesture(Offset(120, y));
    for (var i = 1; i <= 8; i++) {
      await gesture.moveTo(Offset(120 + i * 25, y));
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets('新建位图图层后，图层面板标记为位图', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);

    expect(find.text('位图 1080×1920 · 100%'), findsOneWidget);
  });

  testWidgets('位图图层上画一笔会进撤销栈', (tester) async {
    await pumpCanvas(tester);
    expect(canUndo(tester), isFalse, reason: '刚打开时没有可撤销操作');

    await addRasterLayer(tester);
    await closeLayers(tester);
    await drawLine(tester, y: 300);

    expect(canUndo(tester), isTrue, reason: '像素笔画必须产生撤销记录');
  });

  testWidgets('位图图层上套索给出明确提示而不是静默失败', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);
    await closeLayers(tester);

    await tester.tap(find.byTooltip('选区'));
    await tester.pump();
    await clearNotices(tester);

    final gesture = await tester.startGesture(const Offset(100, 250));
    await gesture.moveTo(const Offset(300, 250));
    await gesture.moveTo(const Offset(300, 450));
    await gesture.moveTo(const Offset(100, 450));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('位图图层暂不支持套索选区'), findsOneWidget);
  });

  testWidgets('切回矢量图层后画笔仍然产生笔画（没有破坏原有路径）', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);
    await closeLayers(tester);

    // 选中下方的矢量图层。
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图层 1'));
    await tester.pumpAndSettle();
    await closeLayers(tester);

    await drawLine(tester, y: 300);
    expect(canUndo(tester), isTrue);

    // 再打开面板，矢量层的摘要仍按「笔」显示。
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    expect(find.textContaining('笔 ·'), findsWidgets);
  });

  testWidgets('位图图层的翻转入口被置灰', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);

    await tester.tap(find.byTooltip('图层操作').first);
    await tester.pumpAndSettle();

    final flip = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('水平翻转'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(flip.enabled, isFalse);
  });
}
