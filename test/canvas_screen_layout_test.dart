import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';

/// 画板布局回归：工具栏不再占用布局空间、不溢出，且贴右两列排列。
///
/// 历史问题：工具栏是画布上方的单行 Row，宽度需求约 425dp，在 360dp 手机上必然
/// `RenderFlex overflow`。这些用例锁定修复后的行为。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('ystrokes_layout_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> pumpCanvas(WidgetTester tester, Size logicalSize) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = logicalSize;
    addTearDown(tester.view.reset);

    // 载入阶段有真实文件 IO，必须放在 runAsync 中等待，否则假时钟不会推进它。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            project: DrawingProject.create(
              '布局用例',
              id: 'layout',
              document: const DocumentSpec(
                widthPx: 750,
                heightPx: 1000,
                dpi: 72,
              ),
            ),
            // 注入以临时目录为根的存储，避免依赖 path_provider 插件。
            documentStore: DocumentStore(rootDirectory: temp),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });

    // 重建一帧，让载入完成后的 setState 生效。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 面板内的格子（工具 2 + 颜色 6 + 笔宽 4 = 12）。
  ///
  /// AppBar 的图标按钮同样是 InkWell，按纵向位置排除。
  List<InkWell> panelCells(WidgetTester tester) {
    final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
    return tester
        .widgetList<InkWell>(find.byType(InkWell))
        .where((widget) => tester.getCenter(find.byWidget(widget)).dy > appBarBottom)
        .toList();
  }

  List<Offset> cellCenters(WidgetTester tester) => panelCells(tester)
      .map((widget) => tester.getCenter(find.byWidget(widget)))
      .toList();

  Size cellSize(WidgetTester tester) =>
      tester.getSize(find.byWidget(panelCells(tester).first));

  testWidgets('360×640 手机：不溢出，格子贴左且排成两列', (tester) async {
    await pumpCanvas(tester, const Size(360, 640));

    expect(tester.takeException(), isNull, reason: '窄屏不应出现 overflow');

    final centers = cellCenters(tester);
    expect(centers, hasLength(12), reason: '2 个工具 + 6 个颜色 + 4 个笔宽');

    // 贴左：全部落在屏幕左半区。
    expect(centers.every((c) => c.dx < 180), isTrue);

    // 两列：中心 x 只有两个不同取值。
    final columns = centers.map((c) => c.dx).toSet();
    expect(columns, hasLength(2), reason: '默认两列');

    // 竖向排列：行数明显多于列数。
    final rows = centers.map((c) => c.dy).toSet();
    expect(rows.length, greaterThan(columns.length));
  });

  testWidgets('800×1280 平板：不溢出，格子随屏幕放大', (tester) async {
    await pumpCanvas(tester, const Size(360, 640));
    final phoneCell = cellSize(tester);

    await pumpCanvas(tester, const Size(800, 1280));
    final tabletCell = cellSize(tester);

    expect(tester.takeException(), isNull);
    expect(
      tabletCell.width,
      greaterThan(phoneCell.width),
      reason: '触控密度应随屏幕短边增大',
    );

    final centers = cellCenters(tester);
    expect(centers.map((c) => c.dx).toSet(), hasLength(2));
    expect(centers.every((c) => c.dx < 400), isTrue);
  });

  testWidgets('横屏不再溢出（历史缺陷场景）', (tester) async {
    await pumpCanvas(tester, const Size(640, 360));
    expect(tester.takeException(), isNull);
    expect(cellCenters(tester), hasLength(12));
  });
}
