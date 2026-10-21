import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/document_spec.dart';
import '../models/layer.dart';
import '../models/stroke_render_options.dart';
import 'document_painter.dart';
import 'svg_exporter.dart';

/// 导出格式。
enum ExportFormat { png, jpg, svg }

/// 导出范围。
enum ExportScope { document, activeLayer }

/// 一次导出的参数。
///
/// 尺寸一律以**像素**为单位：自定义尺寸由界面换算好再传进来，
/// 导出层不再处理单位（工程创建时的尺寸本身就是像素）。
class ExportOptions {
  const ExportOptions({
    required this.format,
    required this.scope,
    required this.width,
    required this.height,
    this.transparentBackground = true,
    this.jpegQuality = 92,
  });

  final ExportFormat format;
  final ExportScope scope;

  /// 输出像素尺寸；SVG 忽略该值（矢量无固定分辨率）。
  final int width;
  final int height;

  /// 仅 PNG 生效。JPG 不支持透明，SVG 保留画布自身的透明区域。
  final bool transparentBackground;

  /// 仅 JPG 生效，取值 1~100。
  final int jpegQuality;

  String get extension => switch (format) {
        ExportFormat.png => 'png',
        ExportFormat.jpg => 'jpg',
        ExportFormat.svg => 'svg',
      };

  ExportOptions copyWith({
    ExportFormat? format,
    ExportScope? scope,
    int? width,
    int? height,
    bool? transparentBackground,
    int? jpegQuality,
  }) =>
      ExportOptions(
        format: format ?? this.format,
        scope: scope ?? this.scope,
        width: width ?? this.width,
        height: height ?? this.height,
        transparentBackground:
            transparentBackground ?? this.transparentBackground,
        jpegQuality: jpegQuality ?? this.jpegQuality,
      );
}

/// 导出结果。
class ExportResult {
  const ExportResult({required this.file, required this.byteLength});

  final File file;
  final int byteLength;
}

/// 导出失败，`message` 可直接展示给用户。
class ExportException implements Exception {
  const ExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把文档导出为文件。
///
/// 职责边界：只负责「内容 → 字节 → 文件」，不涉及分享与界面。
/// 分享由界面层处理，便于测试时替换。
class DocumentExporter {
  /// [outputRoot] 仅用于测试注入；生产环境使用应用文档目录。
  DocumentExporter({Directory? outputRoot}) : _rootOverride = outputRoot;

  final Directory? _rootOverride;

  /// 单次导出的像素上限。
  ///
  /// 光栅化需要整幅 RGBA（`w×h×4` 字节），64 MP 约 256 MB，
  /// 已接近中端设备的安全边界；超出时应当由界面提前拦截。
  static const int maxPixels = 64 * 1000 * 1000;

  /// 各平台的默认导出**目录**（绝对路径）。
  ///
  /// - 桌面端：用户「下载」目录下的 `YStrokes`。导出后不再走分享，
  ///   文件必须落在用户自己能找到的地方。
  /// - 移动端：`getDownloadsDirectory()` 返回 null（公共下载目录需要 MediaStore
  ///   与额外权限），回落到应用文档目录下的 `exports`，并在导出后把路径提示出来。
  static Future<String> defaultOutputPath() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return '${downloads.path}${Platform.pathSeparator}YStrokes';
    }
    final documents = await getApplicationDocumentsDirectory();
    return '${documents.path}${Platform.pathSeparator}exports';
  }

  /// 导出当前文档（或指定图层）。
  ///
  /// [render] 必须与画板当前的压感开关一致：导出若忽略它，用户会得到
  /// 「屏幕上变宽、导出的却是固定宽度」的结果。
  ///
  /// [outputDirectory] 为自定义保存目录（绝对路径）；为空时使用平台默认目录。
  Future<ExportResult> export({
    required String projectName,
    required DocumentSpec document,
    required List<DrawingLayer> layers,
    required String activeLayerId,
    required ExportOptions options,
    StrokeRenderOptions render = StrokeRenderOptions.none,
    String? outputDirectory,
  }) async {
    final selected = _selectLayers(layers, options.scope, activeLayerId);
    if (selected.isEmpty) {
      throw const ExportException('没有可导出的内容');
    }

    if (options.format != ExportFormat.svg) {
      if (options.width <= 0 || options.height <= 0) {
        throw const ExportException('导出尺寸无效');
      }
      if (options.width * options.height > maxPixels) {
        throw const ExportException('导出尺寸超出上限');
      }
    }

    final Uint8List bytes = switch (options.format) {
      ExportFormat.svg => Uint8List.fromList(
          utf8.encode(
            buildDocumentSvg(
              document: document,
              layers: selected,
              render: render,
            ),
          ),
        ),
      ExportFormat.png => await _rasterize(document, selected, options,
          render: render),
      ExportFormat.jpg => await _rasterize(document, selected, options,
          jpeg: true, render: render),
    };

    final file = await _writeFile(projectName, options, bytes, outputDirectory);
    return ExportResult(file: file, byteLength: bytes.length);
  }

  /// 逐层批量导出（**预留接口，暂未实现**）。
  ///
  /// 用户决定先不做批量导出，但保留入口：接入时在此按图层循环调用 [export]，
  /// 并将结果打包（多文件或 zip）。设计约束见 `ystrokes-agent/docs/EXPORT.md` §5。
  Future<List<ExportResult>> exportLayersSeparately() {
    throw UnsupportedError('逐层批量导出尚未实现，见 docs/EXPORT.md §5');
  }

  /// 过滤出真正参与导出的图层：可见、非空、且符合范围。
  List<DrawingLayer> _selectLayers(
    List<DrawingLayer> layers,
    ExportScope scope,
    String activeLayerId,
  ) {
    return <DrawingLayer>[
      for (final layer in layers)
        if (layer.visible &&
            layer.opacity > 0 &&
            layer.strokes.isNotEmpty &&
            (scope == ExportScope.document || layer.id == activeLayerId))
          layer,
    ];
  }

  /// 栅格化：按目标像素尺寸重绘整个文档。
  ///
  /// 导出与视口无关——始终以文档坐标为基准，缩放/旋转状态不影响结果。
  Future<Uint8List> _rasterize(
    DocumentSpec document,
    List<DrawingLayer> layers,
    ExportOptions options, {
    bool jpeg = false,
    StrokeRenderOptions render = StrokeRenderOptions.none,
  }) async {
    final width = options.width;
    final height = options.height;
    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

    // JPG 不支持透明，必须铺纸色；PNG 尊重用户的透明开关。
    final transparent = !jpeg && options.transparentBackground;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintDocument(
      canvas,
      rect,
      Color(document.backgroundArgb),
      layers,
      drawPaper: !transparent,
      render: render,
    );

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        if (!jpeg) {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) {
            throw const ExportException('图片编码失败');
          }
          return data.buffer.asUint8List();
        }

        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw == null) {
          throw const ExportException('图片读取失败');
        }
        final decoded = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: raw.buffer,
          numChannels: 4,
        );
        return img.encodeJpg(decoded, quality: options.jpegQuality);
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  Future<File> _writeFile(
    String projectName,
    ExportOptions options,
    Uint8List bytes,
    String? outputDirectory,
  ) async {
    final dir = await _resolveOutputDir(outputDirectory);

    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final base = _safeFileName(projectName);
      final stamp = _timestamp();
      var file = File('${dir.path}/${base}_$stamp.${options.extension}');
      var suffix = 2;
      // 同一秒内多次导出时避免覆盖。
      while (await file.exists()) {
        file = File('${dir.path}/${base}_${stamp}_$suffix.${options.extension}');
        suffix++;
      }

      await file.writeAsBytes(bytes, flush: true);
      return file;
    } on FileSystemException catch (error) {
      // 自定义目录可能不存在、无权限或被拔掉（U 盘），必须给出可读的原因，
      // 否则界面只会显示一个异常类名。
      final reason = error.osError?.message ?? error.message;
      throw ExportException('无法写入导出目录 ${dir.path}：$reason');
    }
  }

  /// 解析实际写入目录：自定义路径优先，其次平台默认。
  Future<Directory> _resolveOutputDir(String? outputDirectory) async {
    final custom = outputDirectory?.trim() ?? '';
    if (custom.isNotEmpty) return Directory(custom);

    // 测试注入的根目录沿用「根/exports」布局，与真实默认位置同构。
    final override = _rootOverride;
    if (override != null) {
      return Directory('${override.path}${Platform.pathSeparator}exports');
    }
    return Directory(await defaultOutputPath());
  }

  /// 工程名可能包含路径分隔符等非法字符，统一替换并限制长度。
  static String _safeFileName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_')
        .trim();
    final name = cleaned.isEmpty ? 'YStrokes' : cleaned;
    return name.length > 60 ? name.substring(0, 60) : name;
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
