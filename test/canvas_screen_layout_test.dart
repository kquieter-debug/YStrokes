import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/app_settings.dart';
import 'package:ystrokes/src/services/document_store.dart';

/// 画板布局回归：工具栏不占用布局空间、不溢出，且默认贴左两列排列。
///
/// 历史问题：工具栏是画布上方的单行 Row，宽度需求约 425dp，在 360dp 手机上必然
/// `RenderFlex overflow`。这些用例锁定修复后的行为。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 全局单例会跨用例残留，逐个用例复位，否则「贴左」断言会被上一个用例的拖动影响。
    AppSettings.toolbarAnchor.value = null;
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

  /// 面板内的格子（当前仅工具：画笔 + 橡皮）。
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
    expect(centers, hasLength(2), reason: '画笔 + 橡皮；颜色与粗细已移入长按设置');

    // 贴左：全部落在屏幕左半区。
    expect(centers.every((c) => c.dx < 180), isTrue);

    // 两列：两个工具并排在同一行。
    final columns = centers.map((c) => c.dx).toSet();
    expect(columns, hasLength(2), reason: '默认两列');
    expect(centers.map((c) => c.dy).toSet(), hasLength(1), reason: '同一行');
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
    expect(cellCenters(tester), hasLength(2));
  });

  testWidgets('没有「长按设置」提示文字', (tester) async {
    await pumpCanvas(tester, const Size(400, 800));
    expect(find.text('长按设置'), findsNothing);
  });

  testWidgets('拖动把手可移动面板并记住位置', (tester) async {
    await pumpCanvas(tester, const Size(400, 800));

    final handle = find.byKey(const Key('toolbar-drag-handle'));
    expect(handle, findsOneWidget);
    expect(
      AppSettings.toolbarAnchor.value,
      isNull,
      reason: '未拖动时不该写偏好，默认位置由画板决定',
    );

    final before = tester.getCenter(handle);
    await tester.drag(handle, const Offset(120, -90));
    await tester.pumpAndSettle();

    final after = tester.getCenter(handle);
    expect(after.dx, greaterThan(before.dx), reason: '向右拖动应跟随');
    expect(after.dy, lessThan(before.dy), reason: '向上拖动应跟随');
    expect(
      AppSettings.toolbarAnchor.value,
      isNotNull,
      reason: '松手后应记住归一化位置',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动不会超出可用区域', (tester) async {
    await pumpCanvas(tester, const Size(400, 800));

    final handle = find.byKey(const Key('toolbar-drag-handle'));
    await tester.drag(handle, const Offset(2000, 2000));
    await tester.pumpAndSettle();

    final panel = tester.getRect(handle);
    expect(panel.right, lessThanOrEqualTo(400));
    expect(panel.bottom, lessThanOrEqualTo(800));
    expect(AppSettings.toolbarAnchor.value!.dx, lessThanOrEqualTo(1.0));
    expect(AppSettings.toolbarAnchor.value!.dy, lessThanOrEqualTo(1.0));
  });
}
