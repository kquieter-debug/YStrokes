import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/export_destination.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/project.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/models/stroke_render_options.dart';
import 'package:ystrokes/src/rust/api/document.dart' show LayerBlendMode;
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/screens/export_screen.dart';
import 'package:ystrokes/src/services/app_settings.dart';
import 'package:ystrokes/src/services/export_bridge.dart';
import 'package:ystrokes/src/services/exporter.dart';

/// 目录选择器的替身：宿主平台没有原生通道，选择器返回值必须能注入。
class _FakeBridge implements ExportBridge {
  PickedDirectory? pickResult;
  bool pickThrows = false;
  int pickCalls = 0;

  @override
  Future<bool> canSaveToPublicDownloads() async => false;

  @override
  Future<PickedDirectory?> pickDirectory() async {
    pickCalls++;
    if (pickThrows) throw const ExportBridgeException('系统选择器不可用');
    return pickResult;
  }

  @override
  Future<SavedExport?> saveToDirectoryTree({
    required String treeUri,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? label,
  }) async =>
      null;

  @override
  Future<SavedExport?> saveToPublicDownloads({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async =>
      null;
}

/// 记录参数、不落盘的导出器。
///
/// widget 测试的时钟是假的，真实文件 IO 在其中不会推进；因此界面测试只验证
/// 「参数是否按选项传递、分享是否被调用」，落盘与编码由 `exporter_test` 覆盖。
class _RecordingExporter extends DocumentExporter {
  ExportOptions? lastOptions;
  StrokeRenderOptions? lastRender;
  ExportDestination? lastDestination;
  int calls = 0;

  @override
  Future<ExportResult> export({
    required String projectName,
    required DocumentSpec document,
    required List<DrawingLayer> layers,
    required String activeLayerId,
    required ExportOptions options,
    StrokeRenderOptions render = StrokeRenderOptions.none,
    ExportDestination destination = ExportDestination.platformDefault,
  }) async {
    calls++;
    lastOptions = options;
    lastRender = render;
    lastDestination = destination;
    return ExportResult(
      file: File('${Directory.systemTemp.path}/fake.${options.extension}'),
      byteLength: 42,
      location: destination.description,
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
  late _FakeBridge bridge;

  setUp(() {
    // 选择目录会写偏好；没有内存实现时 getInstance 走平台通道，测试里会挂住。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    exporter = _RecordingExporter();
    bridge = _FakeBridge();
    // 全局单例会跨用例残留：不清掉，上一个用例选的目录会带进下一个。
    AppSettings.exportDestination.value = ExportDestination.platformDefault;
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
          bridge: bridge,
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

  testWidgets('导出 SVG 会把格式与范围传给导出器', (tester) async {
    await pumpScreen(tester);
    await selectFormat(tester, 'SVG');

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    expect(exporter.calls, 1);
    expect(exporter.lastOptions?.format, ExportFormat.svg);
    expect(exporter.lastOptions?.scope, ExportScope.document);
    // 未选目录时保持「平台默认」，由导出器决定具体位置。
    expect(exporter.lastDestination?.isPlatformDefault, isTrue);
  });

  testWidgets('通过系统选择器选定目录后传给导出器，并记住选择', (tester) async {
    bridge.pickResult = const PickedDirectory(
      label: '草图',
      path: '/tmp/ystrokes-out',
    );
    await pumpScreen(tester);
    await scrollTo(tester, find.byKey(const Key('export-directory-pick')));

    await tester.tap(find.byKey(const Key('export-directory-pick')));
    await tester.pumpAndSettle();

    expect(bridge.pickCalls, 1);
    expect(find.textContaining('/tmp/ystrokes-out'), findsOneWidget);
    expect(
      AppSettings.exportDestination.value.isDirectory,
      isTrue,
      reason: '选择结果应写入偏好，下次导出沿用',
    );

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    expect(exporter.lastDestination?.path, '/tmp/ystrokes-out');
  });

  testWidgets('选择器返回 SAF 目录树时按树写入', (tester) async {
    bridge.pickResult = const PickedDirectory(
      label: '下载',
      uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload',
    );
    await pumpScreen(tester);
    await scrollTo(tester, find.byKey(const Key('export-directory-pick')));

    await tester.tap(find.byKey(const Key('export-directory-pick')));
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();

    expect(exporter.lastDestination?.isTree, isTrue);
    expect(
      exporter.lastDestination?.uri,
      contains('content://'),
      reason: 'SAF 目录只能靠树 URI 写入',
    );
  });

  testWidgets('选择器报错时在页面上说明原因', (tester) async {
    bridge.pickThrows = true;
    await pumpScreen(tester);
    await scrollTo(tester, find.byKey(const Key('export-directory-pick')));

    await tester.tap(find.byKey(const Key('export-directory-pick')));
    await tester.pumpAndSettle();

    expect(find.textContaining('系统选择器不可用'), findsOneWidget);
  });

  testWidgets('用默认可清除已选目录', (tester) async {
    bridge.pickResult = const PickedDirectory(
      label: '草图',
      path: '/tmp/somewhere',
    );
    await pumpScreen(tester);
    await scrollTo(tester, find.byKey(const Key('export-directory-pick')));

    await tester.tap(find.byKey(const Key('export-directory-pick')));
    await tester.pumpAndSettle();

    final reset = find.byKey(const Key('export-directory-reset'));
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(reset, findsNothing, reason: '回到默认后不再显示「用默认」');
    expect(AppSettings.exportDestination.value.isPlatformDefault, isTrue);

    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.pumpAndSettle();
    expect(exporter.lastDestination?.isPlatformDefault, isTrue);
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
  });
}
