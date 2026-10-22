import 'dart:typed_data';

import '../models/layer.dart';
import '../rust/api/document.dart' as rust;
import 'raster_surface.dart';

/// 解码结果。
class DecodedDocument {
  const DecodedDocument({required this.layers, this.error});

  /// 已还原的图层。位图图层此时只有尺寸与网格，**像素尚未读取**——
  /// 瓦片在磁盘上是独立文件，由 `DocumentStore` 在这一步之后补进来。
  final List<DrawingLayer> layers;

  /// 非空表示文档损坏；[layers] 是已恢复的部分。
  final String? error;
}

/// 文档字节 ↔ 图层的编解码接口。
///
/// 为什么要抽这一层：存储编排里有几处只在真机上才会跑到的危险分支——
/// 瓦片与文档的写入顺序、脏标记清理、图层序号前移后的孤儿目录。
/// 若 `DocumentStore` 直接调用 FFI，这些分支就必须加载 Rust 动态库才能测，
/// 实际结果就是「没人测」。有了这个接缝，测试可以注入一个纯 Dart 的假编解码器，
/// 于是顺序与清理逻辑变成可断言的行为。
abstract class DocumentCodec {
  Future<Uint8List> encode(List<DrawingLayer> layers);
  Future<DecodedDocument> decode(Uint8List bytes);
}

/// 生产实现：转调 Rust。
///
/// 格式的往返与容错由 `cargo test` 覆盖（v6 的图层类型分支、截断恢复、
/// 越界瓦片丢弃），这里只做类型搬运。
class RustDocumentCodec implements DocumentCodec {
  const RustDocumentCodec();

  @override
  Future<Uint8List> encode(List<DrawingLayer> layers) => rust.encodeDocument(
        layers: <rust.Layer>[for (final layer in layers) layer.toRust()],
      );

  @override
  Future<DecodedDocument> decode(Uint8List bytes) async {
    final outcome = await rust.decodeDocument(bytes: bytes);
    return DecodedDocument(
      layers: <DrawingLayer>[
        for (var i = 0; i < outcome.layers.length; i++)
          // 图层 id 不落盘：按顺序重新分配，保证会话内唯一即可。
          // 同一个下标也用作瓦片目录名，两者必须一致。
          DrawingLayer.fromRust(outcome.layers[i], id: 'layer-$i'),
      ],
      error: outcome.error,
    );
  }
}

/// 给位图图层补上像素。
///
/// 抽成函数是为了让「解码 → 读瓦片」的顺序在一个地方表达，而不是散在 store 里。
DrawingLayer attachTiles(DrawingLayer layer, Map<TileKey, Uint8List> tiles) {
  final surface = layer.raster;
  if (surface == null || tiles.isEmpty) return layer;
  layer.raster = RasterSurface.fromTiles(
    width: surface.width,
    height: surface.height,
    tileSize: surface.tileSize,
    tiles: tiles,
  );
  return layer;
}
