import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/stroke.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';

/// 一笔「刚画下、还没进完整快照」的记录。
class JournalEntry {
  const JournalEntry({required this.layerIndex, required this.stroke});

  /// 目标图层在**自下而上**列表中的下标。日志只覆盖最后一次完整保存之后的
  /// 增量，这个窗口内不做图层结构调整，因此下标是稳定的。
  final int layerIndex;
  final Stroke stroke;
}

/// 崩溃恢复日志。
///
/// 解决的问题很具体：自动保存有 800ms 节流窗，进程在这个窗口内被系统杀掉，
/// 最后 1~2 笔就丢了。完整快照的写法（整篇编码 + 原子写）每笔都做太重，
/// 因此这里改为**只追加**一笔的记录，成本与笔画长度成正比，抬笔即可写。
///
/// 生命周期：
/// 1. 抬笔 → `appendStroke` 追加一条；
/// 2. 完整保存成功 → `clear` 删掉整个日志；
/// 3. 启动时 → `read` 读回日志，按 id 去重后补进内存，随后立刻完整保存一次。
///
/// 之所以有独立于 Rust 编解码的迷你格式：日志是**临时**的，读回后马上会被
/// 完整快照取代；为它引入一套 Rust API 与 codegen 不值得。代价是两份编码逻辑，
/// 因此格式故意做得极窄（只有「加一笔」），不承载任何会演进的结构。
class EditJournal {
  EditJournal({Directory? rootDirectory}) : _rootOverride = rootDirectory;

  static const String _fileName = 'edits.journal';
  static const String _libraryDirName = 'projects';

  /// 日志条目类型。将来若加「改一笔」，再补一个编号即可。
  static const int _typeAddStroke = 1;

  final Directory? _rootOverride;
  Directory? _resolvedRoot;

  /// 追加是串行的：多条写入并发 append 会互相覆盖文件指针。
  Future<void> _tail = Future<void>.value();

  /// 追加一笔。调用方不必等待（抬笔路径不能等 I/O），失败静默——
  /// 丢一条恢复日志不应影响正常绘画与保存。
  Future<void> appendStroke({
    required String projectId,
    required int layerIndex,
    required Stroke stroke,
  }) {
    final bytes = _encodeEntry(layerIndex, stroke);
    // 用 catchError 而不是 await：一次写失败不能让后续所有追加都跟着失败。
    _tail = _tail.then((_) => _append(projectId, bytes)).catchError((_) {});
    return _tail;
  }

  /// 读回全部条目。截断或损坏的尾部被丢弃（只保留完整帧）。
  Future<List<JournalEntry>> read(String projectId) async {
    final file = await _fileFor(projectId, createDir: false);
    if (!await file.exists()) return <JournalEntry>[];

    final bytes = await file.readAsBytes();
    final entries = <JournalEntry>[];
    var cursor = 0;
    while (cursor + 4 <= bytes.length) {
      final length = _u32(bytes, cursor);
      final start = cursor + 4;
      // 帧不完整说明进程在写入中途被杀：丢弃这一帧及其后的全部内容。
      if (length == 0 || start + length > bytes.length) break;
      final entry = _decodeEntry(bytes, start, length);
      if (entry != null) entries.add(entry);
      cursor = start + length;
    }
    return entries;
  }

  /// 删除日志（完整保存成功后调用）。
  Future<void> clear(String projectId) {
    _tail = _tail.then((_) async {
      final file = await _fileFor(projectId, createDir: false);
      if (await file.exists()) await file.delete();
    }).catchError((_) {});
    return _tail;
  }

  // ---- 编码 ----

  Uint8List _encodeEntry(int layerIndex, Stroke stroke) {
    final points = stroke.points;
    final payload = 1 + 2 + 4 + 1 + 4 + 4 + 1 + 4 + points.length * 16;
    final data = ByteData(4 + payload);
    var offset = 0;

    data.setUint32(offset, payload, Endian.little);
    offset += 4;
    data.setUint8(offset, _typeAddStroke);
    offset += 1;
    data.setUint16(offset, layerIndex.clamp(0, 0xFFFF), Endian.little);
    offset += 2;
    data.setUint32(offset, stroke.id, Endian.little);
    offset += 4;
    data.setUint8(offset, stroke.tool.index);
    offset += 1;
    data.setUint32(offset, stroke.color, Endian.little);
    offset += 4;
    data.setFloat32(offset, stroke.widthRatio, Endian.little);
    offset += 4;
    data.setUint8(offset, stroke.usesPressure ? 1 : 0);
    offset += 1;
    data.setUint32(offset, points.length, Endian.little);
    offset += 4;

    for (final point in points) {
      data.setFloat32(offset, point.x, Endian.little);
      data.setFloat32(offset + 4, point.y, Endian.little);
      data.setFloat32(offset + 8, point.pressure, Endian.little);
      data.setUint32(offset + 12, point.timestampMs, Endian.little);
      offset += 16;
    }
    return data.buffer.asUint8List();
  }

  JournalEntry? _decodeEntry(Uint8List bytes, int start, int length) {
    try {
      var offset = start;
      final end = start + length;
      if (_u8(bytes, offset) != _typeAddStroke) return null;
      offset += 1;
      final layerIndex = _u16(bytes, offset);
      offset += 2;
      final id = _u32(bytes, offset);
      offset += 4;
      final toolIndex = _u8(bytes, offset);
      offset += 1;
      final color = _u32(bytes, offset);
      offset += 4;
      final width = _f32(bytes, offset);
      offset += 4;
      final usesPressure = _u8(bytes, offset) != 0;
      offset += 1;
      final count = _u32(bytes, offset);
      offset += 4;

      if (toolIndex >= ToolKind.values.length) return null;
      if (count > (end - offset) ~/ 16) return null;

      final points = <rust.StrokePoint>[];
      for (var i = 0; i < count; i++) {
        final x = _f32(bytes, offset);
        final y = _f32(bytes, offset + 4);
        final pressure = _f32(bytes, offset + 8);
        final timestamp = _u32(bytes, offset + 12);
        offset += 16;
        if (!x.isFinite || !y.isFinite || !pressure.isFinite) return null;
        points.add(
          rust.StrokePoint(
            x: x,
            y: y,
            pressure: pressure,
            timestampMs: timestamp,
          ),
        );
      }

      return JournalEntry(
        layerIndex: layerIndex,
        stroke: Stroke(
          id: id,
          tool: ToolKind.values[toolIndex],
          color: color,
          widthRatio: width,
          points: points,
          usesPressure: usesPressure,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  int _u8(Uint8List bytes, int offset) => bytes[offset];
  int _u16(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);
  int _u32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
  double _f32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 4).getFloat32(0, Endian.little);

  // ---- I/O ----

  Future<void> _append(String projectId, Uint8List bytes) async {
    final file = await _fileFor(projectId, createDir: true);
    // 追加模式打开并要求 flush：系统随时可能杀进程，缓冲里的一笔等于没写。
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  Future<File> _fileFor(String projectId, {required bool createDir}) async {
    _assertSafeId(projectId);
    final root = _resolvedRoot ??= await _resolveRoot(createDir: createDir);
    final dir = Directory('${root.path}/$projectId');
    if (createDir && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }

  Future<Directory> _resolveRoot({required bool createDir}) async {
    final base = _rootOverride ?? await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/$_libraryDirName');
    if (createDir && !await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  void _assertSafeId(String projectId) {
    if (projectId.isEmpty ||
        projectId.contains('/') ||
        projectId.contains(r'\') ||
        projectId.contains('..')) {
      throw ArgumentError.value(projectId, 'projectId', '工程 id 不能为空或包含路径分隔符');
    }
  }
}

/// 便于测试与调试：把条目按图层分组。
Map<int, List<Stroke>> groupByLayer(Iterable<JournalEntry> entries) {
  final grouped = SplayTreeMap<int, List<Stroke>>();
  for (final entry in entries) {
    grouped.putIfAbsent(entry.layerIndex, () => <Stroke>[]).add(entry.stroke);
  }
  return grouped;
}
