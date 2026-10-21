import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/tool_settings.dart';
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/widgets/hsv_color_picker.dart';
import 'package:ystrokes/src/widgets/tool_settings_bubble.dart';

/// 一次气泡实例的观测结果。
class _Harness {
  final List<ToolSettings> changes = <ToolSettings>[];
  int closes = 0;
}

/// 工具设置气泡与取色器。
void main() {
  group('HsvColorPicker', () {
    Future<Color?> tapAt(
      WidgetTester tester,
      Offset offsetFromCenter,
    ) async {
      Color? latest;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HsvColorPicker(
                color: const Color(0xFFFF0000),
                size: 200,
                onChanged: (color) => latest = color,
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(HsvColorPicker));
      await tester.tapAt(center + offsetFromCenter);
      await tester.pump();
      return latest;
    }

    testWidgets('点按 SV 方块右上角得到高饱和高明度', (tester) async {
      // 方块半边约 (100-2-26)*0.94/√2 ≈ 48，取 40 落在方块内。
      final color = await tapAt(tester, const Offset(40, -40));
      expect(color, isNotNull);

      final hsv = HSVColor.fromColor(color!);
      expect(hsv.saturation, greaterThan(0.8));
      expect(hsv.value, greaterThan(0.8));
    });

    testWidgets('点按方块底部得到低明度', (tester) async {
      final color = await tapAt(tester, const Offset(0, 44));
      expect(color, isNotNull);
      expect(HSVColor.fromColor(color!).value, lessThan(0.2));
    });

    testWidgets('点按色相环左侧得到约 180° 的色相', (tester) async {
      // 环中线半径约 85，左侧对应 180°（青）。
      final color = await tapAt(tester, const Offset(-85, 0));
      expect(color, isNotNull);

      final hue = HSVColor.fromColor(color!).hue;
      expect(hue, closeTo(180, 12));
    });
  });

  group('ToolSettingsBubble', () {
    Future<_Harness> pumpBubble(
      WidgetTester tester,
      ToolKind tool, {
      bool pressureEnabled = false,
    }) async {
      final harness = _Harness();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolSettingsBubble(
              tool: tool,
              initial: ToolSettings(
                color: const Color(0xFF000000),
                widthRatio: 0.01,
                pressureEnabled: pressureEnabled,
              ),
              // 气泡贴在工具栏右侧：左 20、宽 110。
              anchor: const Rect.fromLTWH(20, 200, 110, 120),
              onChanged: harness.changes.add,
              onClose: () => harness.closes++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('画笔气泡含取色器、粗细与压感，且没有确认按钮', (tester) async {
      await pumpBubble(tester, ToolKind.brush);

      expect(find.text('画笔'), findsOneWidget);
      expect(find.byType(HsvColorPicker), findsOneWidget);
      expect(find.text('粗细'), findsOneWidget);
      expect(find.byKey(const Key('tool-width-slider')), findsOneWidget);
      expect(find.byKey(const Key('tool-pressure-switch')), findsOneWidget);
      // 改动即时生效，因此不该再出现「完成 / 确定」这类提交按钮。
      expect(find.text('完成'), findsNothing);
      expect(find.text('确定'), findsNothing);
    });

    testWidgets('橡皮气泡不含取色器', (tester) async {
      await pumpBubble(tester, ToolKind.eraser);

      expect(find.text('橡皮'), findsOneWidget);
      expect(find.byType(HsvColorPicker), findsNothing);
      expect(find.byKey(const Key('tool-width-slider')), findsOneWidget);
      expect(find.byKey(const Key('tool-pressure-switch')), findsOneWidget);
    });

    testWidgets('拖动粗细滑杆会即时上报新宽度', (tester) async {
      final harness = await pumpBubble(tester, ToolKind.brush);

      await tester.drag(
        find.byKey(const Key('tool-width-slider')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();

      expect(harness.changes, isNotEmpty);
      expect(harness.changes.last.widthRatio, greaterThan(0.01));
    });

    testWidgets('切换压感会即时上报', (tester) async {
      final harness = await pumpBubble(tester, ToolKind.brush);

      await tester.tap(find.byKey(const Key('tool-pressure-switch')));
      await tester.pumpAndSettle();

      expect(harness.changes.last.pressureEnabled, isTrue);
    });

    testWidgets('点击气泡外的画面会关闭', (tester) async {
      final harness = await pumpBubble(tester, ToolKind.brush);

      expect(harness.closes, 0);
      // 气泡在锚点右侧（约 142~442），右下角远离它。
      await tester.tapAt(const Offset(700, 800));
      await tester.pumpAndSettle();

      expect(harness.closes, 1);
    });

    testWidgets('在气泡外拖动（尝试移动工具栏）也会关闭', (tester) async {
      final harness = await pumpBubble(tester, ToolKind.brush);

      // 拖动会命中遮罩的 onPanStart：先关气泡，再拖一次才移动工具栏。
      await tester.dragFrom(const Offset(700, 400), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(harness.closes, 1);
    });

    testWidgets('点击气泡内部不会关闭', (tester) async {
      final harness = await pumpBubble(tester, ToolKind.brush);

      await tester.tap(find.text('粗细'));
      await tester.pumpAndSettle();

      expect(harness.closes, 0);
    });
  });
}
