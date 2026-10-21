import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 导出目标的三类来源。
enum ExportDestinationKind {
  /// 平台默认位置。桌面端解析为「下载/YStrokes」，Android 端写入公共下载目录。
  platformDefault,

  /// 文件系统上的绝对路径（桌面自选目录、或用户手填的路径）。
  directory,

  /// Android 的 SAF 目录树（`content://` 树 URI）。
  ///
  /// 它不是文件系统路径，只能用 ContentResolver 写入，因此不能和 [directory]
  /// 合并成同一个字段——这是平台差异必须显式建模的地方。
  tree,
}

/// 一次导出要写到哪里。
///
/// 之所以不直接用 `String path`：Android 10 之后「用户选的目录」拿到的是
/// SAF 树 URI，而不是可 `Directory(path)` 打开的路径；把两者混成一个字符串，
/// 迟早会在某个分支上出现「路径对了但打不开」。
@immutable
class ExportDestination {
  const ExportDestination._({
    required this.kind,
    this.path,
    this.uri,
    this.label,
  });

  /// 平台默认位置。
  static const ExportDestination platformDefault =
      ExportDestination._(kind: ExportDestinationKind.platformDefault);

  /// 文件系统上的绝对路径。
  factory ExportDestination.directory(String path) =>
      ExportDestination._(kind: ExportDestinationKind.directory, path: path);

  /// Android SAF 目录树；[label] 只用于界面展示（例如「下载」）。
  factory ExportDestination.tree({required String uri, String? label}) =>
      ExportDestination._(
        kind: ExportDestinationKind.tree,
        uri: uri,
        label: label,
      );

  final ExportDestinationKind kind;
  final String? path;
  final String? uri;
  final String? label;

  bool get isPlatformDefault => kind == ExportDestinationKind.platformDefault;

  bool get isDirectory => kind == ExportDestinationKind.directory;

  bool get isTree => kind == ExportDestinationKind.tree;

  /// 界面展示用的简短描述。
  String get description => switch (kind) {
        ExportDestinationKind.platformDefault => '默认位置',
        ExportDestinationKind.directory => path ?? '默认位置',
        ExportDestinationKind.tree => label ?? uri ?? '所选目录',
      };

  /// 是否需要在界面上提供「用默认」的返回入口。
  bool get isCustom => kind != ExportDestinationKind.platformDefault;

  /// 写入 `shared_preferences` 的字符串；默认位置存 `null`（删除键）。
  String? encode() {
    if (isPlatformDefault) return null;
    return jsonEncode(<String, Object?>{
      'kind': kind.name,
      if (path != null) 'path': path,
      if (uri != null) 'uri': uri,
      if (label != null) 'label': label,
    });
  }

  /// 从偏好字符串还原；无法解析或字段缺失时回落到默认位置。
  static ExportDestination decode(String? raw) {
    if (raw == null || raw.isEmpty) return platformDefault;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return platformDefault;
      final kind = data['kind'];
      if (kind == ExportDestinationKind.directory.name) {
        final path = data['path'];
        if (path is String && path.isNotEmpty) {
          return ExportDestination.directory(path);
        }
      } else if (kind == ExportDestinationKind.tree.name) {
        final uri = data['uri'];
        if (uri is String && uri.isNotEmpty) {
          final label = data['label'];
          return ExportDestination.tree(
            uri: uri,
            label: label is String && label.isNotEmpty ? label : null,
          );
        }
      }
      return platformDefault;
    } catch (_) {
      // 偏好被手改坏时不要连累导出：退回默认位置即可。
      return platformDefault;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ExportDestination &&
      other.kind == kind &&
      other.path == path &&
      other.uri == uri &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, path, uri, label);

  @override
  String toString() => 'ExportDestination(${kind.name}: $description)';
}
