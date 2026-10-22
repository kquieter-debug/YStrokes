import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/screens/home_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/widgets/app_icon.dart';

/// 主界面：右侧导航布局与工程长按删除流程。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ystrokes_home_');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'projects': jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'id': 'p1',
          'name': '测试工程',
          'createdAt': '2026-01-01T00:00:00.000',
          'updatedAt': '2026-01-02T00:00:00.000',
          'document': <String, Object>{
            'widthPx': 1080,
            'heightPx': 1920,
            'dpi': 72,
            'backgroundArgb': 0xFFFFFFFF,
          },
        },
      ]),
    });
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          documentStore: DocumentStore(rootDirectory: temp),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 导航栏图标（排除标题栏右侧的应用图标）。
  List<Offset> railIconCenters(WidgetTester tester, Size size) => tester
      .widgetList<AppIcon>(find.byType(AppIcon))
      .map((widget) => tester.getCenter(find.byWidget(widget)))
      .where((center) => center.dx > size.width - 76)
      .toList();

  testWidgets('右侧导航：图标同列、等距，选中态为圆形底色', (tester) async {
    const size = Size(400, 800);
    await pumpHome(tester, size);

    final centers = railIconCenters(tester, size);
    expect(centers, hasLength(3), reason: '工程 / 设置 / 关于');

    // 同一竖列：横坐标一致。
    expect(centers.map((c) => c.dx).toSet().length, 1);

    // 等距：相邻间距相等。
    final ys = centers.map((c) => c.dy).toList()..sort();
    expect(ys[1] - ys[0], closeTo(ys[2] - ys[1], 0.5));

    // 每个条目都有 44dp 的圆形高亮容器。
    final highlights = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .toList();
    expect(highlights, hasLength(3));
    for (final highlight in highlights) {
      final decoration = highlight.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(highlight.constraints?.maxWidth, 44);
      expect(highlight.constraints?.maxHeight, 44);
    }
  });

  testWidgets('长按工程弹出删除，并给出不可回退的二次确认', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('将移入回收站，之后可以恢复。'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
  });

  testWidgets('取消后工程保留', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('将移入回收站，之后可以恢复。'), findsNothing);
    expect(find.text('测试工程'), findsOneWidget);
  });

  testWidgets('长按可重命名，保存后列表更新', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('rename-field')), '速写练习');
    await tester.tap(find.byKey(const Key('rename-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('速写练习'), findsOneWidget);
    expect(find.text('测试工程'), findsNothing);
  });

  testWidgets('重命名为空时保持原名', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('rename-field')), '   ');
    await tester.tap(find.byKey(const Key('rename-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('测试工程'), findsOneWidget);
  });

  testWidgets('画板自带 messenger，提示不会溢出到主界面', (tester) async {
    final project = DrawingProject.create(
      '画板',
      id: 'p1',
      document: const DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72),
    );

    // 载入阶段有真实文件 IO，需在 runAsync 中等待。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            project: project,
            documentStore: DocumentStore(rootDirectory: temp),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(CanvasScreen),
        matching: find.byType(ScaffoldMessenger),
      ),
      findsOneWidget,
      reason: '画板应持有自己的 messenger，路由销毁时提示随之销毁',
    );
  });

  testWidgets('删除只是移入回收站，可恢复', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 列表里消失，但回收站入口出现（说明索引里仍然留着）。
    expect(find.text('测试工程'), findsNothing);
    expect(find.byKey(const Key('open-trash')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-trash')));
    await tester.pumpAndSettle();
    expect(find.text('回收站'), findsOneWidget);

    await tester.tap(find.byKey(const Key('restore-p1')));
    await tester.pumpAndSettle();

    expect(find.text('测试工程'), findsOneWidget, reason: '恢复后回到列表');
    expect(find.byKey(const Key('open-trash')), findsNothing, reason: '回收站已空');
  });

  testWidgets('彻底删除需要二次确认', (tester) async {
    await pumpHome(tester, const Size(400, 800));

    await tester.longPress(find.text('测试工程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-trash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purge-p1')));
    await tester.pumpAndSettle();

    expect(find.text('永久删除'), findsOneWidget, reason: '必须再确认一次');
    await tester.tap(find.byKey(const Key('purge-confirm')));
    await tester.pumpAndSettle();
    // 清文件是真实 IO，假时钟不会推进它；等它跑完再断言列表刷新。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();

    // 条目与回收站入口都消失（文件清理在 project_store_test 里单独验证，
    // 那里没有假时钟，能真正 await 到删除完成）。
    expect(find.text('测试工程'), findsNothing);
    expect(find.byKey(const Key('open-trash')), findsNothing);
  });

  testWidgets('回收站为空时不显示入口', (tester) async {
    await pumpHome(tester, const Size(400, 800));
    expect(find.byKey(const Key('open-trash')), findsNothing);
  });
}
