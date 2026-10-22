import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/services/edit_journal.dart';
import 'package:ystrokes/src/widgets/marching_ants.dart';

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

  /// 一路撤销到底，返回撤销栈的深度。
  ///
  /// 比「断言某一步之后还能不能撤销」更精确：新建图层本身也会进栈，
  /// 只靠布尔值无法区分「多了一条移动记录」和「本来就有的记录」。
  Future<int> undoAll(WidgetTester tester) async {
    var presses = 0;
    while (canUndo(tester) && presses < 30) {
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      presses++;
    }
    return presses;
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

  testWidgets('位图图层上套索建立像素选区并画出流动虚线', (tester) async {
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

    // 选区靠轮廓与压暗表达，不再弹提示条。
    expect(find.byType(MarchingAnts), findsOneWidget);
    final ants = tester.widget<MarchingAnts>(find.byType(MarchingAnts));
    expect(ants.points.length, greaterThanOrEqualTo(3), reason: '轮廓应有顶点');
    expect(find.textContaining('已选中'), findsNothing, reason: '不再提示选中面积');
  });

  testWidgets('像素选区：圈住后拖动会移动内容，并且只产生一条撤销记录', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);
    await closeLayers(tester);

    await drawLine(tester, y: 300);

    await tester.tap(find.byTooltip('选区'));
    await tester.pump();
    await clearNotices(tester);

    // 圈住那条线。
    final lasso = await tester.startGesture(const Offset(100, 250));
    await lasso.moveTo(const Offset(340, 250));
    await lasso.moveTo(const Offset(340, 350));
    await lasso.moveTo(const Offset(100, 350));
    await lasso.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<MarchingAnts>(find.byType(MarchingAnts)).points.length,
      greaterThanOrEqualTo(3),
    );
    await clearNotices(tester);

    // 从选区内部拖动：这一步会把内容提起、并写到新位置。
    final drag = await tester.startGesture(const Offset(200, 300));
    await drag.moveTo(const Offset(230, 330));
    await drag.moveTo(const Offset(260, 360));
    await drag.up();
    await tester.pumpAndSettle();

    // 撤销栈：新建位图层 + 一笔 + 一次移动 = 3 条。
    expect(await undoAll(tester), 3);
  });

  testWidgets('选区外按下会重新圈选，不会误拖动', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);
    await closeLayers(tester);

    await drawLine(tester, y: 300);

    await tester.tap(find.byTooltip('选区'));
    await tester.pump();
    await clearNotices(tester);

    final lasso = await tester.startGesture(const Offset(100, 250));
    await lasso.moveTo(const Offset(340, 250));
    await lasso.moveTo(const Offset(340, 350));
    await lasso.moveTo(const Offset(100, 350));
    await lasso.up();
    await tester.pumpAndSettle();
    await clearNotices(tester);

    // 在选区之外画一个新套索：应当重新生成选区，而不是把旧内容拖走。
    final second = await tester.startGesture(const Offset(60, 500));
    await second.moveTo(const Offset(300, 500));
    await second.moveTo(const Offset(300, 620));
    await second.moveTo(const Offset(60, 620));
    await second.up();
    await tester.pumpAndSettle();

    expect(
      tester.widget<MarchingAnts>(find.byType(MarchingAnts)).points.length,
      greaterThanOrEqualTo(3),
    );
    // 只有「新建位图层 + 一笔」，重新圈选不该追加记录。
    expect(await undoAll(tester), 2);
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

  testWidgets('位图图层的翻转入口可用（像素置换）', (tester) async {
    await pumpCanvas(tester);
    await addRasterLayer(tester);
    await closeLayers(tester);
    await drawLine(tester, y: 300);

    // 画完笔画面板已经关了，重新打开再点行内菜单。
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('图层操作').first);
    await tester.pumpAndSettle();

    final flip = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('水平翻转'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(flip.enabled, isTrue);

    await tester.tap(find.text('水平翻转'));
    await tester.pumpAndSettle();
    // 面板还开着时它那道模态遮罩会吞掉第一次点击，先关掉再数撤销。
    await closeLayers(tester);

    // 翻转本身也是一步可撤销的编辑：建层 + 一笔 + 翻转 = 3。
    expect(await undoAll(tester), 3);
  });
}
