import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/services/document_codec.dart';
import 'package:ystrokes/src/services/document_store.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// 内存编解码器：刻意不模拟字节格式（那是 Rust 的责任），只保留一件关键行为——
/// **解码后位图图层只有尺寸，没有像素**，像素必须由 store 从瓦片目录补回来。
class MemoryCodec implements DocumentCodec {
  List<DrawingLayer> lastEncoded = <DrawingLayer>[];
  int encodeCount = 0;

  /// 编码时机的探针：用来断言「写文档之前瓦片已经在磁盘上」。
  void Function()? beforeEncode;

  @override
  Future<Uint8List> encode(List<DrawingLayer> layers) async {
    encodeCount++;
    beforeEncode?.call();
    lastEncoded = layers;
    return Uint8List.fromList(<int>[layers.length]);
  }

  @override
  Future<DecodedDocument> decode(Uint8List bytes) async {
    return DecodedDocument(
      layers: <DrawingLayer>[
        for (var i = 0; i < lastEncoded.length; i++)
          DrawingLayer(
            id: 'layer-$i',
            name: lastEncoded[i].name,
            opacity: lastEncoded[i].opacity,
            visible: lastEncoded[i].visible,
            blendMode: lastEncoded[i].blendMode,
            raster: lastEncoded[i].raster == null
                ? null
                : RasterSurface(
                    width: lastEncoded[i].raster!.width,
                    height: lastEncoded[i].raster!.height,
                    tileSize: lastEncoded[i].raster!.tileSize,
                  ),
          ),
      ],
    );
  }
}

/// 存储编排：瓦片与文档的顺序、脏标记、孤儿清理、加载时贴回像素。
///
/// 这些分支原本只在真机上跑到，因此单独用假编解码器覆盖。
void main() {
  late Directory temp;
  late Directory projectDir;
  late MemoryCodec codec;
  late DocumentStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ystrokes_persist_test_');
    projectDir = Directory('${temp.path}/projects/p1');
    codec = MemoryCodec();
    store = DocumentStore(rootDirectory: temp, codec: codec);
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 文件句柄可能滞后释放。
    }
  });

  RasterSurface surfaceWithDot() {
    final surface = RasterSurface(width: 32, height: 32, tileSize: 8);
    final data = surface.writableTile(0, 0);
    data[0] = 255;
    data[3] = 255;
    return surface;
  }

  test('保存位图图层时，瓦片先于文档落盘', () async {
    var tilesExistedWhenEncoding = false;
    codec.beforeEncode = () {
      tilesExistedWhenEncoding =
          Directory('${projectDir.path}/tiles/0').existsSync();
    };

    final layer = DrawingLayer(
      id: 'l0',
      name: '位图',
      raster: surfaceWithDot(),
    );
    await store.saveDocument('p1', <DrawingLayer>[layer]);

    expect(tilesExistedWhenEncoding, isTrue,
        reason: '文档里记着瓦片清单，反过来写会留下「引用不存在瓦片」的文档');
  });

  test('保存成功会清空脏标记，下次只写新涂的瓦片', () async {
    final surface = surfaceWithDot();
    final layer = DrawingLayer(id: 'l0', name: '位图', raster: surface);

    await store.saveDocument('p1', <DrawingLayer>[layer]);
    expect(surface.dirtyTiles, isEmpty);

    // 再涂一个新的瓦片：只有它应该是脏的。
    surface.writableTile(1, 0)[3] = 255;
    expect(surface.dirtyTiles, {(1, 0)});
  });

  test('重新加载后像素回到位图图层，且类型不变', () async {
    final layer = DrawingLayer(id: 'l0', name: '位图', raster: surfaceWithDot());
    await store.saveDocument('p1', <DrawingLayer>[layer]);

    final loaded = await store.loadDocument('p1');
    expect(loaded.error, isNull);
    expect(loaded.layers, hasLength(1));

    final restored = loaded.layers.single;
    expect(restored.isRaster, isTrue);
    expect(restored.strokes, isEmpty);
    final data = restored.raster!.tile(0, 0);
    expect(data, isNotNull);
    expect(data![0], 255);
    expect(data[3], 255);
  });

  test('没有任何瓦片的位图图层仍然是位图图层', () async {
    final layer = DrawingLayer(
      id: 'l0',
      name: '空位图',
      raster: RasterSurface(width: 32, height: 32, tileSize: 8),
    );
    await store.saveDocument('p1', <DrawingLayer>[layer]);

    final restored = (await store.loadDocument('p1')).layers.single;
    expect(restored.isRaster, isTrue,
        reason: '用 null 表示「没读到像素」会把它静默变成矢量层');
    expect(restored.isEmpty, isTrue);
  });

  test('图层减少后，越界的瓦片目录被清掉', () async {
    final layers = <DrawingLayer>[
      DrawingLayer(id: 'l0', name: 'A', raster: surfaceWithDot()),
      DrawingLayer(id: 'l1', name: 'B', raster: surfaceWithDot()),
      DrawingLayer(id: 'l2', name: 'C', raster: surfaceWithDot()),
    ];
    await store.saveDocument('p1', layers);
    expect(Directory('${projectDir.path}/tiles/2').existsSync(), isTrue);

    // 删掉最后一层再存：序号 2 的目录必须消失，否则下次它会被当成别的层。
    await store.saveDocument('p1', layers.sublist(0, 2));
    expect(Directory('${projectDir.path}/tiles/2').existsSync(), isFalse);
  });

  test('矢量图层不产生瓦片目录', () async {
    await store.saveDocument('p1', <DrawingLayer>[
      DrawingLayer(id: 'l0', name: '线稿'),
    ]);
    expect(Directory('${projectDir.path}/tiles').existsSync(), isFalse);
  });

  test('文档缺失时返回空列表而不抛错', () async {
    final loaded = await store.loadDocument('nope');
    expect(loaded.layers, isEmpty);
    expect(loaded.error, isNull);
  });

  test('flushTiles 只写瓦片，不重编码文档', () async {
    final surface = surfaceWithDot();
    final layer = DrawingLayer(id: 'l0', name: '位图', raster: surface);
    await store.saveDocument('p1', [layer]);
    expect(codec.encodeCount, 1);

    // 再涂一块，然后只冲瓦片。
    final buffer = surface.writableTile(1, 0);
    buffer[0] = 255;
    buffer[3] = 255;
    expect(surface.dirtyTiles, isNotEmpty);

    await store.flushTiles('p1', [layer]);

    expect(codec.encodeCount, 1, reason: '像素落盘不该触发文档编码');
    expect(
      File('${projectDir.path}/tiles/0/1_0.png').existsSync(),
      isTrue,
      reason: '新瓦片应当已经写到磁盘',
    );
    expect(surface.dirtyTiles, isEmpty, reason: '落盘后脏标记要清掉');
  });

  test('瓦片比文档新时，加载仍然读得到像素', () async {
    final surface = surfaceWithDot();
    final layer = DrawingLayer(id: 'l0', name: '位图', raster: surface);
    await store.saveDocument('p1', [layer]);

    // 模拟「保存文档之后又画了几笔，并且这些瓦片已经即时落盘」。
    final buffer = surface.writableTile(1, 0);
    buffer[3] = 255;
    await store.flushTiles('p1', [layer]);

    final loaded = await store.loadDocument('p1');
    final raster = loaded.layers.first.raster;
    expect(raster, isNotNull);
    expect(raster!.tile(1, 0), isNotNull, reason: '加载端以瓦片目录为准');
  });
}
