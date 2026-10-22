import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/layer.dart';
import 'document_codec.dart';
import 'raster_surface.dart';
import 'tile_store.dart';

/// 笔画数据的文件存储。
///
/// 存储布局：
/// ```
/// <applicationDocuments>/projects/<projectId>/strokes.bin
/// <applicationDocuments>/projects/<projectId>/tiles/<layer>/<x>_<y>.png
/// ```
///
/// 设计要点：
/// - **元数据与笔画分离**。工程名称、时间等轻量信息仍由 `ProjectStore` 放在
///   shared_preferences 中充当索引；笔画体量大、变化频繁，走独立文件，
///   避免每次保存都全量重写一个大 JSON 字符串。
/// - **写入是原子的**。先写 `strokes.bin.tmp`，再重命名覆盖目标文件。
///   进程在写入中途被杀时，旧文件仍然完整，不会出现半截文档。
/// - **ID 由调用方保证安全**。工程 id 会直接作为目录名，因此禁止路径分隔符。
/// - **位图与文档同目录**。v6 起一个工程是「文档 + 瓦片目录」，本类是唯一
///   知道这两者关系的地方：像素读写交给 [TileStore]（它只认一个已定位的目录），
///   目录定位与 id 校验留在这里。
class DocumentStore {
  /// [rootDirectory] 仅用于测试注入；生产环境走 [getApplicationDocumentsDirectory]。
  DocumentStore({
    Directory? rootDirectory,
    TileStore? tileStore,
    DocumentCodec? codec,
  })  : _rootOverride = rootDirectory,
        _tileStore = tileStore ?? const TileStore(),
        _codec = codec ?? const RustDocumentCodec();

  static const String _fileName = 'strokes.bin';
  static const String _thumbnailName = 'thumb.png';
  static const String _tmpSuffix = '.tmp';
  static const String _libraryDirName = 'projects';

  final Directory? _rootOverride;
  final TileStore _tileStore;
  final DocumentCodec _codec;
  Directory? _resolvedRoot;

  /// 读取图层；文件不存在时返回空文档而非抛错（新建工程属正常情况）。
  ///
  /// 位图图层的像素不读文件就不存在，因此这里会逐层去瓦片目录取；
  /// 瓦片缺失只表现为「那块透明」，不影响其它图层继续加载。
  Future<StoredDocument> loadDocument(String projectId) async {
    final file = await _fileFor(projectId);
    if (!await file.exists()) {
      return const StoredDocument(layers: <DrawingLayer>[]);
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return const StoredDocument(layers: <DrawingLayer>[]);
    }

    final decoded = await _codec.decode(bytes);
    final dir = await _dirFor(projectId);

    for (var i = 0; i < decoded.layers.length; i++) {
      final layer = decoded.layers[i];
      if (layer.raster == null) continue;
      // 图层序号同时也是瓦片目录名，这两者必须用同一个下标。
      final tiles = await _tileStore.loadTiles(dir, i);
      // 没有瓦片时保留解码得到的空 surface：图层仍然是位图图层，
      // 只是内容全透明——不能用 null 表示「没读到像素」，那会把它变成矢量层。
      if (tiles.isNotEmpty) attachTiles(layer, tiles);
    }

    return StoredDocument(layers: decoded.layers, error: decoded.error);
  }

  /// 编码并原子写入全部图层。
  ///
  /// 写入顺序是**先瓦片、后文档**：文档里记着「哪些瓦片存在」，若反过来，
  /// 崩溃就会留下一份「引用了不存在瓦片」的文档；而先写瓦片最坏只是多几个
  /// 无人引用的文件，下一次保存会被清掉。
  Future<void> saveDocument(
    String projectId,
    List<DrawingLayer> layers,
  ) async {
    final dir = await _dirFor(projectId);
    await _persistTiles(dir, layers);

    final encoded = await _codec.encode(layers);
    await writeBytes(projectId, encoded);
  }

  /// 把每层位图的脏瓦片落盘，并清理已消失的瓦片与图层目录。
  Future<void> _persistTiles(Directory dir, List<DrawingLayer> layers) async {
    for (var i = 0; i < layers.length; i++) {
      final surface = layers[i].raster;
      if (surface == null) continue;

      final dirty = surface.dirtyTiles;
      final live = surface.liveTiles;
      await _tileStore.saveTiles(
        dir,
        i,
        dirty: <TileKey, Uint8List>{
          for (final key in dirty)
            if (surface.tile(key.$1, key.$2) != null)
              key: surface.tile(key.$1, key.$2)!,
        },
        live: live,
        tileSize: surface.tileSize,
      );
      // 落盘成功后清脏：下次保存只写这次之后新涂的瓦片。
      surface.clearDirty();
    }

    // 图层数量变少时，多出来的瓦片目录必须删掉：序号会整体前移，
    // 留着它们会让「第 N 层」读到上一轮属于另一层的像素。
    await _tileStore.pruneLayers(dir, layers.length);
  }

  /// 直接读取原始字节；文件不存在时返回 null。
  Future<Uint8List?> readBytes(String projectId) async {
    final file = await _existingFileFor(projectId, _fileName);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 读取工程缩略图；尚未生成时返回 null。
  Future<Uint8List?> readThumbnail(String projectId) async {
    final file = await _existingFileFor(projectId, _thumbnailName);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 写入工程缩略图（PNG）。
  Future<void> saveThumbnail(String projectId, Uint8List bytes) async {
    final file = await _fileFor(projectId, _thumbnailName);
    await _writeAtomically(file, bytes);
  }

  /// 原子写入原始字节。
  ///
  /// 先落临时文件并 flush，再重命名覆盖。绝大多数文件系统上 rename 对同分区
  /// 是原子操作，因此读者要么看到上一次的内容、要么看到这一次的，不会读到半截数据。
  Future<void> writeBytes(String projectId, Uint8List bytes) async {
    final file = await _fileFor(projectId);
    await _writeAtomically(file, bytes);
  }

  Future<void> _writeAtomically(File file, Uint8List bytes) async {
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

  /// 删除工程对应的文档目录（删除工程时调用）。
  Future<void> deleteStrokes(String projectId) async {
    final dir = await _dirFor(projectId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 是否已存在文档文件（用于列表页判断有无内容）。
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

  Future<File> _fileFor(String projectId, [String name = _fileName]) async {
    final dir = await _dirFor(projectId);
    return File('${dir.path}/$name');
  }

  /// 只解析路径、不创建目录：读操作不应该留下空工程目录。
  Future<File> _existingFileFor(String projectId, String name) async {
    _assertSafeId(projectId);
    final root = await _libraryRoot();
    return File('${root.path}/$projectId/$name');
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

/// 读取结果：`error` 非空表示文档损坏，此时 [layers] 为已恢复的部分。
class StoredDocument {
  const StoredDocument({required this.layers, this.error});

  final List<DrawingLayer> layers;
  final String? error;

  bool get isEmpty => layers.every((layer) => layer.isEmpty);
}
