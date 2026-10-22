import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/tile_store.dart';

/// 瓦片是「文档 + 目录」这套存储里最容易出错的一半：
/// 文件名解析、脏写、孤儿清理、图层序号前移都属于「错了才发现」的类型。
void main() {
  late Directory temp;
  late Directory projectDir;
  const store = TileStore();
  const tileSize = 8;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ystrokes_tile_test_');
    projectDir = Directory('${temp.path}/p1')..createSync(recursive: true);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上文件句柄可能还没释放；删不掉不影响断言。
    }
  });

  /// 造一块纯色瓦片。
  Uint8List tile(int r, int g, int b, int a) {
    final data = Uint8List(tileSize * tileSize * 4);
    for (var i = 0; i < tileSize * tileSize; i++) {
      data[i * 4] = r;
      data[i * 4 + 1] = g;
      data[i * 4 + 2] = b;
      data[i * 4 + 3] = a;
    }
    return data;
  }

  List<String> tileFiles(int layer) {
    final dir = Directory('${projectDir.path}/tiles/$layer');
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList()
      ..sort();
  }

  test('写入后能原样读回', () async {
    await store.saveTiles(
      projectDir,
      0,
      dirty: {(0, 0): tile(255, 0, 0, 255)},
      live: {(0, 0)},
      tileSize: tileSize,
    );

    final loaded = await store.loadTiles(projectDir, 0);
    expect(loaded.keys, [(0, 0)]);
    final data = loaded[(0, 0)]!;
    expect(data.length, tileSize * tileSize * 4);
    expect(data[0], 255);
    expect(data[1], 0);
    expect(data[3], 255);
  });

  test('文件名带坐标且按层分目录', () async {
    await store.saveTiles(
      projectDir,
      2,
      dirty: {(3, 5): tile(255, 0, 0, 255)},
      live: {(3, 5)},
      tileSize: tileSize,
    );
    expect(tileFiles(2), ['3_5.png']);
  });

  test('目录不存在时读取返回空而不是报错', () async {
    expect(await store.loadTiles(projectDir, 7), isEmpty);
    expect(await store.hasTiles(projectDir, 7), isFalse);
  });

  test('只写脏瓦片，但会删掉已不在 live 里的文件', () async {
    await store.saveTiles(
      projectDir,
      0,
      dirty: {(0, 0): tile(255, 0, 0, 255), (1, 0): tile(0, 255, 0, 255)},
      live: {(0, 0), (1, 0)},
      tileSize: tileSize,
    );
    expect(tileFiles(0), ['0_0.png', '1_0.png']);

    // 第二次只报 (0,0) 是脏的，且 (1,0) 已被擦掉。
    await store.saveTiles(
      projectDir,
      0,
      dirty: {(0, 0): tile(0, 0, 255, 255)},
      live: {(0, 0)},
      tileSize: tileSize,
    );
    expect(tileFiles(0), ['0_0.png'], reason: '擦掉的瓦片文件必须删除');

    final loaded = await store.loadTiles(projectDir, 0);
    expect(loaded[(0, 0)]![2], 255, reason: '内容应更新为脏瓦片的新值');
  });

  test('整层清空时目录被删掉', () async {
    await store.saveTiles(
      projectDir,
      0,
      dirty: {(0, 0): tile(255, 0, 0, 255)},
      live: {(0, 0)},
      tileSize: tileSize,
    );
    expect(tileFiles(0), isNotEmpty);

    await store.saveTiles(
      projectDir,
      0,
      dirty: const {},
      live: const {},
      tileSize: tileSize,
    );
    expect(await store.hasTiles(projectDir, 0), isFalse);
  });

  test('pruneLayers 删掉序号超出范围的目录', () async {
    for (var layer = 0; layer < 4; layer++) {
      await store.saveTiles(
        projectDir,
        layer,
        dirty: {(0, 0): tile(255, 0, 0, 255)},
        live: {(0, 0)},
        tileSize: tileSize,
      );
    }

    await store.pruneLayers(projectDir, 2);

    final root = Directory('${projectDir.path}/tiles');
    final remaining = root
        .listSync()
        .whereType<Directory>()
        .map((dir) => int.parse(dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty)))
        .toList()
      ..sort();
    expect(remaining, [0, 1]);
  });

  test('不认识的文件与损坏的 PNG 被忽略', () async {
    final dir = Directory('${projectDir.path}/tiles/0')..createSync(recursive: true);
    File('${dir.path}/notes.txt').writeAsStringSync('not a tile');
    File('${dir.path}/0_0.png').writeAsBytesSync([1, 2, 3, 4]);

    final loaded = await store.loadTiles(projectDir, 0);
    expect(loaded, isEmpty, reason: '损坏的 PNG 应当被跳过而不是抛错');
  });
}
