import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次「写到系统公共位置」的结果。
class SavedExport {
  const SavedExport({required this.location, this.uri});

  /// 展示给用户的目录描述，例如 `Download/YStrokes` 或 `下载/草图`。
  final String location;

  /// 内容 URI（Android 的 `content://...`）；桌面端为空。
  final String? uri;
}

/// 用户通过系统文件管理器选中的目录。
class PickedDirectory {
  const PickedDirectory({
    required this.label,
    this.path,
    this.uri,
  });

  /// 展示名（系统返回的目录名）。
  final String label;

  /// 文件系统绝对路径；Android 的 SAF 目录没有这个值。
  final String? path;

  /// Android SAF 树 URI；桌面端为空。
  final String? uri;
}

/// 平台文件系统的能力出口。
///
/// 存在的原因：Android 的「公共下载目录」与「用户选的目录」都不是普通文件路径，
/// 必须走 MediaStore / SAF；桌面端则就是文件路径 + 系统目录选择器。把差异收在
/// 这一个接口后面，导出编排（`DocumentExporter`）与界面都不需要判断平台。
///
/// 方法在能力不可用时返回 `null` / `false` 而不是抛错：桌面端与测试环境没有
/// 这个通道，静默降级到文件系统路径才是正确行为。
abstract class ExportBridge {
  /// 当前平台能否直接写入公共下载目录。
  Future<bool> canSaveToPublicDownloads();

  /// 写入公共下载目录下的应用子目录。
  Future<SavedExport?> saveToPublicDownloads({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  });

  /// 唤起系统目录选择器；用户取消时返回 null。
  Future<PickedDirectory?> pickDirectory();

  /// 写入用户选中的 SAF 目录树。
  Future<SavedExport?> saveToDirectoryTree({
    required String treeUri,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? label,
  });
}

/// 生产实现：Android 走 MethodChannel，桌面走 `file_selector`。
class PlatformExportBridge implements ExportBridge {
  const PlatformExportBridge();

  /// 与 `MainActivity` 中的通道名保持一致。
  static const MethodChannel channel =
      MethodChannel('com.muffins.ystrokes/export');

  static const String _publicSubdir = 'YStrokes';

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Android 通道是否真的可用。
  ///
  /// 单元测试跑在宿主平台，`Platform.isAndroid` 为假，这里直接返回 false，
  /// 于是导出会走文件系统分支——测试因此不需要为通道打桩。
  Future<bool> _channelAvailable() async {
    if (!_isAndroid) return false;
    return true;
  }

  @override
  Future<bool> canSaveToPublicDownloads() async {
    if (!await _channelAvailable()) return false;
    try {
      final result = await channel.invokeMethod<bool>('canSaveToPublicDownloads');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<SavedExport?> saveToPublicDownloads({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (!await _channelAvailable()) return null;
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'saveToDownloads',
        <String, Object?>{
          'bytes': bytes,
          'fileName': fileName,
          'mimeType': mimeType,
          'subdir': _publicSubdir,
        },
      );
      if (result == null) return null;
      return SavedExport(
        location: (result['location'] as String?) ?? 'Download/$_publicSubdir',
        uri: result['uri'] as String?,
      );
    } on PlatformException catch (error) {
      throw ExportBridgeException(error.message ?? '写入公共下载目录失败');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<PickedDirectory?> pickDirectory() async {
    if (_isAndroid) {
      try {
        final result = await channel
            .invokeMapMethod<String, Object?>('pickDirectory');
        if (result == null) return null;
        final uri = result['uri'] as String?;
        if (uri == null) return null;
        return PickedDirectory(
          label: (result['label'] as String?) ?? '所选目录',
          uri: uri,
        );
      } on PlatformException catch (error) {
        throw ExportBridgeException(error.message ?? '无法打开系统目录选择器');
      } on MissingPluginException {
        return null;
      }
    }

    // 桌面端：系统原生目录选择器（Windows 资源管理器 / macOS Finder / Linux 门户）。
    try {
      final path = await getDirectoryPath(
        confirmButtonText: '选择此目录',
      );
      if (path == null || path.isEmpty) return null;
      return PickedDirectory(
        label: path.split(Platform.pathSeparator).last,
        path: path,
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<SavedExport?> saveToDirectoryTree({
    required String treeUri,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? label,
  }) async {
    if (!await _channelAvailable()) return null;
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'saveToDirectoryTree',
        <String, Object?>{
          'treeUri': treeUri,
          'bytes': bytes,
          'fileName': fileName,
          'mimeType': mimeType,
        },
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      return SavedExport(
        // 优先用用户看得懂的目录名，其次平台返回的位置，最后退回树 URI。
        location: label ?? (result['location'] as String?) ?? treeUri,
        uri: uri,
      );
    } on PlatformException catch (error) {
      throw ExportBridgeException(
        error.message ?? '无法写入所选目录（授权可能已失效，请重新选择）',
      );
    } on MissingPluginException {
      return null;
    }
  }
}

/// 桥接层可展示给用户的失败原因。
class ExportBridgeException implements Exception {
  const ExportBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
