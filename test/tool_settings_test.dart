import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/tool_settings.dart';
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/widgets/hsv_color_picker.dart';
import 'package:ystrokes/src/widgets/tool_settings_sheet.dart';

/// 工具设置面板与取色器。
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

  group('ToolSettingsSheet', () {
    Future<ToolSettings?> open(
      WidgetTester tester,
      ToolKind tool,
    ) async {
      ToolSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<ToolSettings>(
                      context: context,
                      builder: (_) => ToolSettingsSheet(
                        tool: tool,
                        initial: const ToolSettings(
                          color: Color(0xFF000000),
                          widthRatio: 0.01,
                        ),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('画笔设置含取色器与粗细滑杆', (tester) async {
      await open(tester, ToolKind.brush);

      expect(find.text('画笔设置'), findsOneWidget);
      expect(find.byType(HsvColorPicker), findsOneWidget);
      expect(find.text('粗细'), findsOneWidget);
      expect(find.byKey(const Key('tool-width-slider')), findsOneWidget);
    });

    testWidgets('橡皮设置只有粗细，不显示取色器', (tester) async {
      await open(tester, ToolKind.eraser);

      expect(find.text('橡皮设置'), findsOneWidget);
      expect(find.byType(HsvColorPicker), findsNothing);
      expect(find.byKey(const Key('tool-width-slider')), findsOneWidget);
    });

    testWidgets('拖动滑杆后完成，回传新的笔宽', (tester) async {
      // 面板较高，给足竖向空间，避免滑杆落在视口之外。
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);

      ToolSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<ToolSettings>(
                      context: context,
                      builder: (_) => const ToolSettingsSheet(
                        tool: ToolKind.brush,
                        initial: ToolSettings(
                          color: Color(0xFF000000),
                          widthRatio: 0.01,
                        ),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 拖到滑杆右侧，笔宽应显著增大。
      await tester.drag(
        find.byKey(const Key('tool-width-slider')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.widthRatio, greaterThan(0.01));
    });
  });
}
