import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/screens/canvas_screen.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/services/edit_journal.dart';

/// P1 的选区动作：加选 / 减选 / 反向 / 切分 / 翻转 / 数值。
void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('ystrokes_actions_');
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // 后台落盘/日志仍在写，Windows 会锁文件；删不掉不影响断言。
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
              '动作',
              id: 'actions',
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

  /// 关掉画布顶部的提示横幅。
  ///
  /// 测试环境没有初始化 Rust 桥，自动保存必然失败，失败横幅会铺满画布上部并吃掉
  /// 落在它上面的手势。横幅本身带关闭按钮，因此每次要操作画布前先把它关掉。
  Future<void> clearNotices(WidgetTester tester) async {
    final close = find.byTooltip('关闭提示');
    if (close.evaluate().isEmpty) return;
    for (var i = close.evaluate().length - 1; i >= 0; i--) {
      await tester.tap(close.at(i));
      await tester.pump();
    }
  }

  /// 画一条横线。[y] 控制高度，测试里用不同高度区分两条笔画。
  ///
  /// 必须给足采样点：`StrokeSmoother` 的窗口是 5，原始点不足 5 个时中心移动平均会把
  /// 整条笔画压成同一个点（`finish()` 返回两个重合点），后续的套索命中/切分就无从谈起。
  /// 因此这里按 25 逻辑像素的间距补 8 个中间点，并左右交替 ±4 让 y 不退化。
  Future<void> drawLine(WidgetTester tester, {required double y}) async {
    await clearNotices(tester);
    final gesture = await tester.startGesture(Offset(150, y));
    for (var i = 1; i <= 8; i++) {
      await gesture.moveTo(Offset(150 + i * 25, y + (i.isOdd ? 4 : -4)));
    }
    await gesture.up();
    await tester.pump();
  }

  /// 等提示条（SnackBar）自然消失，避免它挡住后续的空白区域点击。
  Future<void> settleHints(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  /// 只做套索手势（不碰工具按钮，工具需已切到选区）。
  Future<void> traceLasso(
    WidgetTester tester,
    Offset from,
    Offset to,
  ) async {
    await clearNotices(tester);
    final gesture = await tester.startGesture(from);
    await gesture.moveTo(Offset(to.dx, from.dy));
    await gesture.moveTo(to);
    await gesture.moveTo(Offset(from.dx, to.dy));
    await gesture.moveTo(from);
    await gesture.up();
    await tester.pump();
  }

  Future<void> selectTool(WidgetTester tester) async {
    await tester.tap(find.byTooltip('选区'));
    await tester.pump();
  }

  Future<void> openBubble(WidgetTester tester) async {
    await tester.longPress(find.byTooltip('选区'));
    await tester.pumpAndSettle();
  }

  Future<void> closeBubble(WidgetTester tester) async {
    await tester.tapAt(const Offset(390, 760));
    await tester.pumpAndSettle();
  }

  testWidgets('追加模式：两次套索累加选区', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 200);
    await drawLine(tester, y: 330);
    await selectTool(tester);

    await traceLasso(tester, const Offset(100, 150), const Offset(390, 250));
    await openBubble(tester);
    expect(find.text('1 笔'), findsOneWidget);
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await closeBubble(tester);

    await traceLasso(tester, const Offset(100, 280), const Offset(390, 380));
    await openBubble(tester);
    expect(find.text('2 笔'), findsOneWidget, reason: '追加后应包含两条笔画');
  });

  testWidgets('减选模式：从选区里去掉一条', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 200);
    await drawLine(tester, y: 330);
    await selectTool(tester);

    // 圈住两条。
    await traceLasso(tester, const Offset(100, 150), const Offset(390, 380));
    await openBubble(tester);
    expect(find.text('2 笔'), findsOneWidget);

    await tester.tap(find.text('减选'));
    await tester.pumpAndSettle();
    await closeBubble(tester);

    // 减掉下面那条。
    await traceLasso(tester, const Offset(100, 280), const Offset(390, 380));
    await openBubble(tester);
    expect(find.text('1 笔'), findsOneWidget);
  });

  testWidgets('反向选择：取当前图层的补集', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 200);
    await drawLine(tester, y: 330);
    await selectTool(tester);

    await traceLasso(tester, const Offset(100, 150), const Offset(390, 250));
    await openBubble(tester);
    expect(find.text('1 笔'), findsOneWidget);

    await tester.tap(find.byKey(const Key('selection-invert')));
    await tester.pumpAndSettle();
    await openBubble(tester);
    expect(find.text('1 笔'), findsOneWidget, reason: '两条里反选另一条');
  });

  testWidgets('切分到选区：跨边界的笔画被裁剪并可撤销', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 210);
    await selectTool(tester);

    // 只圈左半段（x ≤ 250），右半段在选区外。套索右边界正好过笔画采样点，
    // 顺带覆盖「顶点压在边界上」这个退化情形。
    await traceLasso(tester, const Offset(100, 150), const Offset(250, 270));
    expect(find.byKey(const Key('transform-commit')), findsOneWidget);

    await openBubble(tester);
    await tester.tap(find.byKey(const Key('selection-split')));
    await tester.pumpAndSettle();

    // 切分是破坏性的：选区被消费掉，操作条随之消失。
    expect(find.byKey(const Key('transform-commit')), findsNothing);
    await settleHints(tester);

    // 右侧已被裁掉：再圈右半段选不中任何笔画，操作条不会出现。
    await traceLasso(tester, const Offset(260, 150), const Offset(390, 270));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('transform-commit')),
      findsNothing,
      reason: '选区外的右半段应已被裁掉',
    );
    await settleHints(tester);

    // 撤销应当把整条原笔画放回来。
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();

    await traceLasso(tester, const Offset(260, 150), const Offset(390, 270));
    expect(
      find.byKey(const Key('transform-commit')),
      findsOneWidget,
      reason: '撤销后右半段笔画应恢复',
    );
  });

  testWidgets('变换条提供翻转与数值入口', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 210);
    await selectTool(tester);
    await traceLasso(tester, const Offset(100, 150), const Offset(390, 280));

    expect(find.byKey(const Key('transform-flip-h')), findsOneWidget);
    expect(find.byKey(const Key('transform-flip-v')), findsOneWidget);
    expect(find.byKey(const Key('transform-values')), findsOneWidget);

    // 翻转是可预览的改动，点完不应崩溃，操作条保持在。
    await tester.tap(find.byKey(const Key('transform-flip-h')));
    await tester.pump();
    expect(find.byKey(const Key('transform-commit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('transform-values')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transform-rotation-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('transform-rotation-field')),
      '45',
    );
    await tester.enterText(
      find.byKey(const Key('transform-scale-field')),
      '150',
    );
    await tester.tap(find.byKey(const Key('transform-values-confirm')));
    await tester.pumpAndSettle();

    // 完成提交后操作条消失。
    await tester.tap(find.byKey(const Key('transform-commit')));
    await tester.pump();
    expect(find.byKey(const Key('transform-commit')), findsNothing);
  });

  testWidgets('图层面板提供水平/垂直翻转', (tester) async {
    await pumpCanvas(tester);
    await drawLine(tester, y: 210);

    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('图层操作'));
    await tester.pumpAndSettle();

    expect(find.text('水平翻转'), findsOneWidget);
    expect(find.text('垂直翻转'), findsOneWidget);

    await tester.tap(find.text('水平翻转'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('layers-bubble')), findsOneWidget,
        reason: '翻转是一步操作，不关闭面板');
  });
}
