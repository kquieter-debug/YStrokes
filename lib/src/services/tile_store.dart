import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'raster_surface.dart';

/// 位图瓦片的磁盘读写。
///
/// 存储布局：
/// ```
/// <projectDir>/tiles/<layerOrdinal>/<x>_<y>.png
/// ```
///
/// 三条设计约束：
///
/// 1. **文档只存索引，像素存文件**。Rust 侧不引入压缩依赖，而 PNG 在 Dart 侧已有；
///    同时 PNG 能直接用看图软件打开，排查「导出与屏幕不一致」时省事。
/// 2. **本类不解析工程路径**。它只接收一个已经定位好的工程目录，
///    目录解析（`path_provider`、id 校验）留在 `DocumentStore`。
///    这样它可以在测试里对任意临时目录工作，不需要 mock 平台通道。
/// 3. **逐文件原子写**。`*.tmp` + rename，与文档写入同一套约定：
///    半截 PNG 比没有 PNG 更糟，解码会抛错而不是回退成透明。
class TileStore {
  const TileStore();

  /// 瓦片文件扩展名。PNG 是刻意选的（见类注释）。
  static const String extension = 'png';

  /// 子目录名。
  static const String directoryName = 'tiles';

  /// 读取某一层的全部瓦片。目录或文件缺失时**跳过而非报错**：
  /// 瓦片丢失的表现应当是「那块透明」，而不是整个图层打不开。
  Future<Map<TileKey, Uint8List>> loadTiles(
    Directory projectDir,
    int layerOrdinal,
  ) async {
    final dir = _layerDir(projectDir, layerOrdinal);
    if (!await dir.exists()) return <TileKey, Uint8List>{};

    final out = <TileKey, Uint8List>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final key = _parseTileName(entity.uri.pathSegments.last);
      if (key == null) continue;

      final bytes = await entity.readAsBytes();
      final decoded = img.decodePng(bytes);
      if (decoded == null) continue;

      out[key] = _toRgba(decoded);
    }
    return out;
  }

  /// 写入有变化的瓦片，并删除「已不存在」的瓦片文件。
  ///
  /// [dirty] 只包含需要重写的瓦片；[live] 是该层当前仍然存在的瓦片全集。
  /// 分成两个参数是因为它们服务于不同的问题：前者省写放大，后者防文件泄漏——
  /// 擦掉一块区域后，文件不会自己消失。
  Future<void> saveTiles(
    Directory projectDir,
    int layerOrdinal, {
    required Map<TileKey, Uint8List> dirty,
    required Set<TileKey> live,
    required int tileSize,
  }) async {
    final dir = _layerDir(projectDir, layerOrdinal);

    if (live.isEmpty) {
      // 整层被清空：目录本身没有存在意义，删掉比留一堆透明 PNG 干净。
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    }
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final entry in dirty.entries) {
      final (x, y) = entry.key;
      if (!live.contains(entry.key)) continue;
      await _writeTile(
        File('${dir.path}/${x}_$y.$extension'),
        entry.value,
        tileSize,
      );
    }

    // 清理已不在 live 集合里的旧文件（擦除 / 撤销后多出来的那些）。
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final key = _parseTileName(entity.uri.pathSegments.last);
      if (key == null) continue;
      if (!live.contains(key)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // 删不掉不影响正确性：下次保存会再试一次。
        }
      }
    }
  }

  /// 只写这些瓦片，**不删除任何文件**。
  ///
  /// 与 [saveTiles] 的分工：那个是「完整保存」，需要知道哪些瓦片还活着才能
  /// 清理孤儿；这个用于笔画抬手时的即时落盘——此时只关心「这一笔改了哪几块」，
  /// 而判断 `live` 要扫一遍整层像素（O(画布面积)），每笔都做太贵。
  ///
  /// 擦成透明的瓦片会暂时留在磁盘上，由下一次完整保存清掉。崩溃恢复宁可多
  /// 保留几块透明 PNG，也不该为了清理而多扫两百万个像素。
  Future<void> writeDirtyTiles(
    Directory projectDir,
    int layerOrdinal,
    Map<TileKey, Uint8List> tiles,
    int tileSize,
  ) async {
    if (tiles.isEmpty) return;
    final dir = _layerDir(projectDir, layerOrdinal);
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final entry in tiles.entries) {
      final (x, y) = entry.key;
      await _writeTile(
        File('${dir.path}/${x}_$y.$extension'),
        entry.value,
        tileSize,
      );
    }
  }

  /// 删除不再存在的图层对应的瓦片目录。
  ///
  /// 图层序号是按顺序推导的，因此删掉中间一层会让其后的序号整体前移——
  /// 那时「第 N 层」的瓦片目录已经属于另一层了。调用方必须在**保存文档之前**
  /// 用它把超出范围的目录清掉，否则会读到上一轮的像素。
  Future<void> pruneLayers(Directory projectDir, int keepCount) async {
    final root = Directory('${projectDir.path}/$directoryName');
    if (!await root.exists()) return;

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final ordinal = int.tryParse(entity.uri.pathSegments
          .lastWhere((segment) => segment.isNotEmpty, orElse: () => ''));
      if (ordinal == null || ordinal >= keepCount) {
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // 同上：残留目录不会让解码失败，只是占空间。
        }
      }
    }
  }

  /// 删除整个瓦片目录（删除工程时调用）。
  Future<void> deleteAll(Directory projectDir) async {
    final root = Directory('${projectDir.path}/$directoryName');
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// 某一层的瓦片是否已存在（用于「首次写入」的判断与诊断）。
  Future<bool> hasTiles(Directory projectDir, int layerOrdinal) =>
      _layerDir(projectDir, layerOrdinal).exists();

  Directory _layerDir(Directory projectDir, int layerOrdinal) =>
      Directory('${projectDir.path}/$directoryName/$layerOrdinal');

  Future<void> _writeTile(File file, Uint8List rgba, int tileSize) async {
    final image = img.Image.fromBytes(
      width: tileSize,
      height: tileSize,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final png = img.encodePng(image, level: 6);

    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(png, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows 上 rename 到已存在文件会失败，需先删目标。
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
  }

  /// 从文件名解析瓦片坐标；不认识的名字返回 null。
  static TileKey? _parseTileName(String name) {
    if (!name.endsWith('.$extension')) return null;
    final stem = name.substring(0, name.length - extension.length - 1);
    final parts = stem.split('_');
    if (parts.length != 2) return null;
    final x = int.tryParse(parts[0]);
    final y = int.tryParse(parts[1]);
    if (x == null || y == null || x < 0 || y < 0) return null;
    return (x, y);
  }

  /// 把解码结果整理成 RGBA8888 非预乘的连续缓冲。
  static Uint8List _toRgba(img.Image source) {
    final out = Uint8List(source.width * source.height * 4);
    var index = 0;
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        out[index++] = pixel.r.toInt();
        out[index++] = pixel.g.toInt();
        out[index++] = pixel.b.toInt();
        out[index++] = pixel.a.toInt();
      }
    }
    return out;
  }
}
