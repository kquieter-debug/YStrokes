import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/widgets/bubble_surface.dart';

/// 气泡外壳：动画存在性、首末帧数值、无动画时的直通。
void main() {
  Future<void> pumpSurface(
    WidgetTester tester, {
    Animation<double>? animation,
    Alignment alignment = Alignment.centerLeft,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              BubbleSurface(
                animation: animation,
                alignment: alignment,
                child: const SizedBox(key: Key('content'), width: 120, height: 60),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 只看 `BubbleSurface` 自己的子树：`MaterialApp` 的路由切换也有 FadeTransition，
  /// 用全局查找会把它算进来。
  Finder inSurface(Type type) => find.descendant(
        of: find.byType(BubbleSurface),
        matching: find.byType(type),
      );

  FadeTransition fadeOf(WidgetTester tester) =>
      tester.widget<FadeTransition>(inSurface(FadeTransition).first);

  ScaleTransition scaleOf(WidgetTester tester) =>
      tester.widget<ScaleTransition>(inSurface(ScaleTransition).first);

  testWidgets('没有动画时直接呈现，不套过渡组件', (tester) async {
    await pumpSurface(tester);

    expect(inSurface(FadeTransition), findsNothing);
    expect(inSurface(ScaleTransition), findsNothing);
    expect(find.byKey(const Key('content')), findsOneWidget);
  });

  testWidgets('动画首帧为透明且略微缩小，末帧完全显现', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 130),
    );
    addTearDown(controller.dispose);

    await pumpSurface(tester, animation: controller);

    // 首帧：动画值为 0，气泡必须完全透明且缩小到 94%。
    final fade = fadeOf(tester);
    final scale = scaleOf(tester);
    expect(fade.opacity.value, 0);
    expect(scale.scale.value, closeTo(0.94, 1e-9));
    expect(scale.alignment, Alignment.centerLeft);

    controller.value = 1;
    await tester.pump();
    expect(fade.opacity.value, moreOrLessEquals(1, epsilon: 1e-6));
    expect(scale.scale.value, moreOrLessEquals(1, epsilon: 1e-6));
  });

  testWidgets('动画中段介于两者之间（确认是插值而非跳变）', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 130),
    );
    addTearDown(controller.dispose);

    await pumpSurface(tester, animation: controller);
    controller.value = 0.5;
    await tester.pump();

    final fade = fadeOf(tester);
    final scale = scaleOf(tester);
    expect(fade.opacity.value, greaterThan(0.5), reason: 'easeOut 前段更快');
    expect(fade.opacity.value, lessThan(1));
    expect(scale.scale.value, greaterThan(0.94));
    expect(scale.scale.value, lessThan(1));
  });

  testWidgets('遮罩只负责关闭：点按与拖动都上报', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [BubbleBarrier(onClose: () => closes++)],
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(closes, 1);

    // 「尝试拖动工具栏」也走同一条路径：先关气泡，再拖一次才移动面板。
    await tester.dragFrom(const Offset(200, 400), const Offset(-100, 0));
    await tester.pump();
    expect(closes, 2);
  });
}
