import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/stroke.dart';
import '../rust/api.dart' as rust;

/// 笔画数据的文件存储。
///
/// 存储布局：
/// ```
/// <applicationDocuments>/projects/<projectId>/strokes.bin
/// ```
///
/// 设计要点：
/// - **元数据与笔画分离**。工程名称、时间等轻量信息仍由 `ProjectStore` 放在
///   shared_preferences 中充当索引；笔画体量大、变化频繁，走独立文件，
///   避免每次保存都全量重写一个大 JSON 字符串。
/// - **写入是原子的**。先写 `strokes.bin.tmp`，再重命名覆盖目标文件。
///   进程在写入中途被杀时，旧文件仍然完整，不会出现半截文档。
/// - **ID 由调用方保证安全**。工程 id 会直接作为目录名，因此禁止路径分隔符。
class DocumentStore {
  /// [rootDirectory] 仅用于测试注入；生产环境走 [getApplicationDocumentsDirectory]。
  DocumentStore({Directory? rootDirectory}) : _rootOverride = rootDirectory;

  static const String _fileName = 'strokes.bin';
  static const String _tmpSuffix = '.tmp';
  static const String _libraryDirName = 'projects';

  final Directory? _rootOverride;
  Directory? _resolvedRoot;

  /// 读取笔画；文件不存在时返回空文档而非抛错（新建工程属正常情况）。
  Future<StoredDocument> loadStrokes(String projectId) async {
    final file = await _fileFor(projectId);
    if (!await file.exists()) {
      return const StoredDocument(strokes: <Stroke>[]);
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return const StoredDocument(strokes: <Stroke>[]);
    }
    final outcome = await rust.decodeDocument(bytes: bytes);
    return StoredDocument(
      strokes: outcome.strokes.map(Stroke.fromRust).toList(),
      error: outcome.error,
    );
  }

  /// 编码并原子写入全部笔画。
  Future<void> saveStrokes(String projectId, List<Stroke> strokes) async {
    final encoded = await rust.encodeDocument(
      strokes: strokes.map((s) => s.toRust()).toList(),
    );
    await writeBytes(projectId, encoded);
  }

  /// 直接读取原始字节；文件不存在时返回 null。
  Future<Uint8List?> readBytes(String projectId) async {
    final file = await _fileFor(projectId);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 原子写入原始字节。
  ///
  /// 先落临时文件并 flush，再重命名覆盖。绝大多数文件系统上 rename 对同分区
  /// 是原子操作，因此读者要么看到旧版本、要么看到新版本，不会读到半截数据。
  Future<void> writeBytes(String projectId, Uint8List bytes) async {
    final file = await _fileFor(projectId);
    final tmp = File('${file.path}$_tmpSuffix');
    await tmp.writeAsBytes(bytes, flush: true);

    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows 上重命名到已存在的文件会失败，需先删除目标。
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    }
  }

  /// 删除工程对应的笔画目录（删除工程时调用）。
  Future<void> deleteStrokes(String projectId) async {
    final dir = await _dirFor(projectId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 是否已存在笔画文件（用于列表页判断有无内容）。
  Future<bool> hasStrokes(String projectId) async {
    final file = await _fileFor(projectId);
    return file.exists();
  }

  Future<Directory> _libraryRoot() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;

    final base = _rootOverride ?? await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/$_libraryDirName');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _resolvedRoot = root;
    return root;
  }

  Future<Directory> _dirFor(String projectId) async {
    _assertSafeId(projectId);
    final root = await _libraryRoot();
    final dir = Directory('${root.path}/$projectId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _fileFor(String projectId) async {
    final dir = await _dirFor(projectId);
    return File('${dir.path}/$_fileName');
  }

  /// 工程 id 会拼进文件路径，必须拒绝任何可能逃逸出工程目录的取值。
  void _assertSafeId(String projectId) {
    if (projectId.isEmpty ||
        projectId.contains('/') ||
        projectId.contains(r'\') ||
        projectId.contains('..')) {
      throw ArgumentError.value(projectId, 'projectId', '工程 id 不能为空或包含路径分隔符');
    }
  }
}

/// 读取结果：`error` 非空表示文档损坏，此时 [strokes] 为已恢复的部分。
class StoredDocument {
  const StoredDocument({required this.strokes, this.error});

  final List<Stroke> strokes;
  final String? error;

  bool get isEmpty => strokes.isEmpty;
}
