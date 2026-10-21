import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/rust/api/document.dart' show LayerBlendMode;
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/screens/export_screen.dart';
import 'package:ystrokes/src/services/exporter.dart';

/// 记录参数、不落盘的导出器。
///
/// widget 测试的时钟是假的，真实文件 IO 在其中不会推进；因此界面测试只验证
/// 「参数是否按选项传递、分享是否被调用」，落盘与编码由 `exporter_test` 覆盖。
class _RecordingExporter extends DocumentExporter {
  ExportOptions? lastOptions;
  int calls = 0;

  @override
  Future<ExportResult> export({
    required String projectName,
    required DocumentSpec document,
    required List<DrawingLayer> layers,
    required String activeLayerId,
    required ExportOptions options,
  }) async {
    calls++;
    lastOptions = options;
    return ExportResult(
      file: File('${Directory.systemTemp.path}/fake.${options.extension}'),
      byteLength: 42,
    );
  }
}

/// 导出页：默认选项、格式切换、尺寸校验、参数传递与混合模式提示。
void main() {
  final project = DrawingProject.create(
    '测试工程',
    id: 'p1',
    document: const DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72),
  );

  DrawingLayer layer({
    String id = 'layer-0',
    String name = '图层 1',
    LayerBlendMode blend = LayerBlendMode.normal,
  }) =>
      DrawingLayer(
        id: id,
        name: name,
        blendMode: blend,
        strokes: <Stroke>[
          Stroke(
            id: 0,
            tool: ToolKind.brush,
            color: 0xFF000000,
            widthRatio: 0.01,
            points: <rust.StrokePoint>[
              rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
              rust.StrokePoint(x: 0.8, y: 0.8, pressure: 1, timestampMs: 16),
            ],
          ),
        ],
      );

  late _RecordingExporter exporter;
  late List<File> shared;

  setUp(() {
    exporter = _RecordingExporter();
    shared = <File>[];
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<DrawingLayer>? layers,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ExportScreen(
          project: project,
          layers: layers ?? <DrawingLayer>[layer()],
          activeLayerId: 'layer-0',
          exporter: exporter,
          shareFile: (file) async => shared.add(file),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 选项卡片可能落在首屏之外，断言前先滚动到可见。
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) return;
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectFormat(WidgetTester tester, String label) async {
    final chip = find.widgetWithText(ChoiceChip, label);
    await scrollTo(tester, chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  testWidgets('默认 PNG，显示输出尺寸且可导出', (tester) async {
    await pumpScreen(tester);

    expect(find.text('1080 × 1920 px'), findsOneWidget);
    await scrollTo(tester, find.text('透明背景'));
    expect(find.text('透明背景'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('export-submit')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('切到 JPG 显示质量滑杆，透明开关消失', (tester) async {
    await pumpScreen(tester);
    await selectFormat(tester, 'JPG');

    await scrollTo(tester, find.byKey(const Key('export-quality')));
    expect(find.byKey(const Key('export-quality')), findsOneWidget);
    expect(find.text('透明背景'), findsNothing);
    expect(find.text('JPG 不支持透明，将以文档底色填充。'), findsOneWidget);
  });

  testWidgets('自定义尺寸超出上限时禁用并说明原因', (tester) async {
    await pumpScreen(tester);

    final custom = find.widgetWithText(ChoiceChip, '自定义');
    await scrollTo(tester, custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('export-width')));
    await tester.enterText(find.byKey(const Key('export-width')), '20000');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('export-submit')),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('输出尺寸过大'), findsOneWidget);
  });

  testWidgets('导出 SVG 会把格式与范围传给导出器并分享文件', (tester) async {
    await pumpScreen(tester);
    await selectFormat(tester, 'SVG');

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    expect(exporter.calls, 1);
    expect(exporter.lastOptions?.format, ExportFormat.svg);
    expect(exporter.lastOptions?.scope, ExportScope.document);
    expect(shared, hasLength(1));
    expect(shared.single.path, endsWith('.svg'));
  });

  testWidgets('自定义尺寸与透明开关会传到导出器', (tester) async {
    await pumpScreen(tester);

    final custom = find.widgetWithText(ChoiceChip, '自定义');
    await scrollTo(tester, custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('export-width')));
    await tester.enterText(find.byKey(const Key('export-width')), '540');
    await tester.pumpAndSettle();

    // 锁比例时高度应被自动换算：540 × 1920/1080 = 960。
    expect(find.text('960'), findsOneWidget);

    await scrollTo(tester, find.text('透明背景'));
    // 页面里有两个开关（锁定比例 / 透明背景），按所在行精确定位后滚动到可见，
    // 避免被底部操作栏遮挡导致点击落空。
    final transparentRow = find
        .ancestor(of: find.text('透明背景'), matching: find.byType(Row))
        .first;
    final transparentSwitch = find.descendant(
      of: transparentRow,
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(transparentSwitch);
    await tester.pumpAndSettle();
    await tester.tap(transparentSwitch);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Switch>(transparentSwitch).value,
      isFalse,
      reason: '开关应被切到关闭',
    );

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    final options = exporter.lastOptions;
    expect(options?.width, 540);
    expect(options?.height, 960);
    expect(options?.transparentBackground, isFalse);
  });

  testWidgets('含非正常混合模式时导出 SVG 会提示，可取消', (tester) async {
    await pumpScreen(
      tester,
      layers: <DrawingLayer>[layer(blend: LayerBlendMode.multiply)],
    );
    await selectFormat(tester, 'SVG');

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    expect(find.text('混合模式提示'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(exporter.calls, 0, reason: '取消后不应调用导出');
    expect(shared, isEmpty);
  });

  testWidgets('提示中选择仍要导出则继续', (tester) async {
    await pumpScreen(
      tester,
      layers: <DrawingLayer>[layer(blend: LayerBlendMode.screen)],
    );
    await selectFormat(tester, 'SVG');

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍要导出'));
    await tester.pumpAndSettle();

    expect(exporter.calls, 1);
    expect(shared, hasLength(1));
  });
}
