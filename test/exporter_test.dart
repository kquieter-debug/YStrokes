import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/exporter.dart';

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

  test('SVG 导出写入 exports 目录，文件名清洗非法字符', () async {
    final result = await exporter.export(
      projectName: '速写/练习',
      document: document,
      layers: [layer('a')],
      activeLayerId: 'a',
      options: svgOptions(),
    );

    expect(await result.file.exists(), isTrue);
    expect(result.file.parent.path, endsWith('exports'));
    expect(
      result.file.uri.pathSegments.last,
      startsWith('速写_练习_'),
      reason: '路径分隔符应被替换',
    );
    expect(result.byteLength, greaterThan(0));

    final content = utf8.decode(await result.file.readAsBytes());
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

    expect(first.file.path, isNot(second.file.path));
    expect(await second.file.exists(), isTrue);
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

    final content = utf8.decode(await result.file.readAsBytes());
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
}
