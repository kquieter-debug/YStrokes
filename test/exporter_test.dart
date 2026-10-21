import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/export_destination.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/models/stroke_render_options.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/export_bridge.dart';
import 'package:ystrokes/src/services/exporter.dart';

/// 平台能力替身：宿主平台没有 Android 通道，只能靠注入验证分发逻辑。
class _StubBridge implements ExportBridge {
  _StubBridge({this.canSavePublic = false});

  bool canSavePublic;
  int publicCalls = 0;
  int treeCalls = 0;
  String? lastTreeUri;

  @override
  Future<bool> canSaveToPublicDownloads() async => canSavePublic;

  @override
  Future<SavedExport?> saveToPublicDownloads({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    publicCalls++;
    return SavedExport(
      location: 'Download/YStrokes',
      uri: 'content://media/external/downloads/42',
    );
  }

  @override
  Future<PickedDirectory?> pickDirectory() async => null;

  @override
  Future<SavedExport?> saveToDirectoryTree({
    required String treeUri,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? label,
  }) async {
    treeCalls++;
    lastTreeUri = treeUri;
    return SavedExport(
      location: label ?? '所选目录',
      uri: 'content://com.android.externalstorage.documents/document/42',
    );
  }
}

/// 导出服务：文件命名、范围过滤、错误分支。
///
/// 光栅化依赖引擎的 `toImage`，其正确性由渲染层保证；此处只覆盖不涉及
/// 像素处理的路径（SVG 与参数校验），避免在单元测试里做真实渲染。
void main() {
  const document = DocumentSpec(widthPx: 100, heightPx: 200, dpi: 72);

  DrawingLayer layer(String id, {bool visible = true, int strokes = 1}) =>
      DrawingLayer(
        id: id,
        name: id,
        visible: visible,
        strokes: <Stroke>[
          for (var i = 0; i < strokes; i++)
            Stroke(
              id: i,
              tool: ToolKind.brush,
              color: 0xFF000000,
              widthRatio: 0.01,
              points: <rust.StrokePoint>[
                rust.StrokePoint(x: 0.1, y: 0.1, pressure: 1, timestampMs: 0),
                rust.StrokePoint(x: 0.9, y: 0.9, pressure: 1, timestampMs: 10),
              ],
            ),
        ],
      );

  late Directory temp;
  late DocumentExporter exporter;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ystrokes_export_test_');
    exporter = DocumentExporter(outputRoot: temp);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ExportOptions svgOptions({ExportScope scope = ExportScope.document}) =>
      const ExportOptions(
        format: ExportFormat.svg,
        scope: ExportScope.document,
        width: 100,
        height: 200,
      ).copyWith(scope: scope);

  test('压感开关透传到 SVG 产物', () async {
    final result = await exporter.export(
      projectName: '压感',
      document: document,
      layers: [layer('a')],
      activeLayerId: 'a',
      options: svgOptions(),
      render: const StrokeRenderOptions(brushPressure: true),
    );

    final content = utf8.decode(await result.file!.readAsBytes());
    expect(content, contains('fill="#000000"'));
    expect(content, isNot(contains('stroke-width')));
  });

  test('SVG 导出写入 exports 目录，文件名清洗非法字符', () async {
    final result = await exporter.export(
      projectName: '速写/练习',
      document: document,
      layers: [layer('a')],
      activeLayerId: 'a',
      options: svgOptions(),
    );

    expect(await result.file!.exists(), isTrue);
    expect(result.location, endsWith('exports'));
    expect(
      result.file!.uri.pathSegments.last,
      startsWith('速写_练习_'),
      reason: '路径分隔符应被替换',
    );
    expect(result.byteLength, greaterThan(0));

    final content = utf8.decode(await result.file!.readAsBytes());
    expect(content, contains('<svg'));
  });

  test('同一秒内多次导出不会互相覆盖', () async {
    final first = await exporter.export(
      projectName: '同名',
      document: document,
      layers: [layer('a')],
      activeLayerId: 'a',
      options: svgOptions(),
    );
    final second = await exporter.export(
      projectName: '同名',
      document: document,
      layers: [layer('a')],
      activeLayerId: 'a',
      options: svgOptions(),
    );

    expect(first.file!.path, isNot(second.file!.path));
    expect(await second.file!.exists(), isTrue);
  });

  test('没有可见内容时拒绝导出', () async {
    expect(
      () => exporter.export(
        projectName: '空',
        document: document,
        layers: [layer('a', visible: false)],
        activeLayerId: 'a',
        options: svgOptions(),
      ),
      throwsA(isA<ExportException>()),
    );
  });

  test('「仅当前图层」只导出选中层', () async {
    final result = await exporter.export(
      projectName: '单层',
      document: document,
      layers: [layer('a'), layer('b')],
      activeLayerId: 'b',
      options: svgOptions(scope: ExportScope.activeLayer),
    );

    final content = utf8.decode(await result.file!.readAsBytes());
    expect(content, contains('data-name="b"'));
    expect(content, isNot(contains('data-name="a"')));
  });

  test('超出像素上限时在光栅化前拦截', () async {
    expect(
      () => exporter.export(
        projectName: '过大',
        document: document,
        layers: [layer('a')],
        activeLayerId: 'a',
        options: const ExportOptions(
          format: ExportFormat.png,
          scope: ExportScope.document,
          width: 20000,
          height: 20000,
        ),
      ),
      throwsA(isA<ExportException>()),
    );
  });

  test('批量导出接口保持未实现状态', () {
    expect(
      () => exporter.exportLayersSeparately(),
      throwsA(isA<UnsupportedError>()),
    );
  });

  group('导出目标分发', () {
    test('公共下载可用时走 MediaStore，不落文件系统', () async {
      final bridge = _StubBridge(canSavePublic: true);
      final target = DocumentExporter(outputRoot: temp, bridge: bridge);

      final result = await target.export(
        projectName: '公共',
        document: document,
        layers: [layer('a')],
        activeLayerId: 'a',
        options: svgOptions(),
      );

      expect(bridge.publicCalls, 1);
      expect(result.file, isNull, reason: '内容 URI 没有文件路径');
      expect(result.location, 'Download/YStrokes');
      expect(result.uri, startsWith('content://'));
      // 不该顺手在应用目录再写一份。
      expect(await Directory('${temp.path}/exports').exists(), isFalse);
    });

    test('选了 SAF 目录树时按树写入', () async {
      final bridge = _StubBridge();
      final target = DocumentExporter(outputRoot: temp, bridge: bridge);

      final result = await target.export(
        projectName: '树',
        document: document,
        layers: [layer('a')],
        activeLayerId: 'a',
        options: svgOptions(),
        destination: ExportDestination.tree(
          uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload',
          label: '下载',
        ),
      );

      expect(bridge.treeCalls, 1);
      expect(bridge.lastTreeUri, contains('tree/primary'));
      expect(result.file, isNull);
      expect(result.location, '下载');
      expect(result.uri, startsWith('content://'));
    });

    test('选了文件系统目录时写到该目录', () async {
      final custom = await Directory.systemTemp.createTemp('ystrokes_custom_');
      addTearDown(() async {
        if (await custom.exists()) await custom.delete(recursive: true);
      });

      final target = DocumentExporter(
        outputRoot: temp,
        bridge: _StubBridge(canSavePublic: true),
      );
      final result = await target.export(
        projectName: '自定义',
        document: document,
        layers: [layer('a')],
        activeLayerId: 'a',
        options: svgOptions(),
        destination: ExportDestination.directory(custom.path),
      );

      expect(result.file, isNotNull);
      expect(result.file!.parent.path, custom.path);
      expect(result.location, custom.path);
    });

    test('公共下载不可用时回落到默认目录', () async {
      final bridge = _StubBridge();
      final target = DocumentExporter(outputRoot: temp, bridge: bridge);

      final result = await target.export(
        projectName: '回落',
        document: document,
        layers: [layer('a')],
        activeLayerId: 'a',
        options: svgOptions(),
      );

      expect(bridge.publicCalls, 0);
      expect(result.file, isNotNull);
      expect(result.location, endsWith('exports'));
    });

    test('树目录写入失败时给出可读错误', () async {
      final target = DocumentExporter(
        outputRoot: temp,
        bridge: _FailingTreeBridge(),
      );

      await expectLater(
        target.export(
          projectName: '失败',
          document: document,
          layers: [layer('a')],
          activeLayerId: 'a',
          options: svgOptions(),
          destination: ExportDestination.tree(uri: 'content://broken'),
        ),
        throwsA(
          isA<ExportException>().having(
            (error) => error.message,
            'message',
            contains('重新选择'),
          ),
        ),
      );
    });
  });
}

class _FailingTreeBridge extends _StubBridge {
  @override
  Future<SavedExport?> saveToDirectoryTree({
    required String treeUri,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? label,
  }) async =>
      null;
}
