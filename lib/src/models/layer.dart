import 'dart:typed_data';

import '../rust/api/document.dart' as rust_doc;
import '../rust/api/stroke.dart' as rust_stroke;
import '../services/raster_surface.dart';
import 'stroke.dart';

/// 一个图层。
///
/// 图层本身只承载「一组内容 + 合成参数」，不持有画布尺寸等文档级信息。
/// 顺序即绘制顺序：索引 0 在最底层。
///
/// ## 两种内容
///
/// - **矢量**（[strokes]）：可编辑的笔画对象，现状不变。
/// - **位图**（[raster]）：像素瓦片，见 `RasterSurface`。
///
/// 二选一，不会同时存在——「混合层」（单层内既有笔画又有像素斑块）已明确不做，
/// 因为扁平列表无法表达两种内容的 z 序。图层类型由 [raster] 是否为 null 决定，
/// **不额外存一个 kind 字段**：两个字段表达同一件事时，必然出现「声明与载荷不一致」
/// 的中间态。
class DrawingLayer {
  DrawingLayer({
    required this.id,
    required this.name,
    this.opacity = 1.0,
    this.visible = true,
    this.blendMode = rust_doc.LayerBlendMode.normal,
    List<Stroke>? strokes,
    this.raster,
  }) : strokes = strokes ?? <Stroke>[] {
    assert(
      raster == null || this.strokes.isEmpty,
      '位图图层不能同时携带笔画：两种内容二选一（不做混合层）',
    );
  }

  /// 会话内唯一 id。持久化格式里不存该值——载入时按顺序重新分配即可，
  /// 它只在「选中哪一层」与撤销记录中使用。
  final String id;

  String name;

  /// 不透明度 0.0 ~ 1.0。
  double opacity;

  bool visible;

  /// 与下方图层内容的混合方式。
  rust_doc.LayerBlendMode blendMode;

  /// 矢量内容。位图图层恒为空。
  final List<Stroke> strokes;

  /// 位图内容。矢量图层为 null。
  ///
  /// 用可变字段而不是 final：撤销/重做会整份替换它（快照是 `RasterSurface.fork()`
  /// 的产物），而图层对象本身保持不变，这样「选中哪一层」不会因为一次撤销而失效。
  RasterSurface? raster;

  /// 是否矢量图层（可以导出为纯 SVG、可以按整笔选中）。
  bool get isVector => raster == null;

  /// 是否位图图层（像素级可编辑）。
  bool get isRaster => raster != null;

  /// 是否没有任何内容。
  bool get isEmpty => raster?.isEmpty ?? strokes.isEmpty;

  /// 位图图层的像素字节量（撤销预算用）；矢量图层为 0。
  int get pixelByteSize => raster?.allocatedByteSize ?? 0;

  /// 转成持久化结构。
  ///
  /// 位图图层只写「**有内容**的瓦片坐标」——擦到全透明的瓦片既不该出现在
  /// 文档清单里，也不该占磁盘。
  rust_doc.Layer toRust() {
    final surface = raster;
    if (surface == null) {
      return rust_doc.Layer(
        name: name,
        opacity: opacity,
        visible: visible,
        blendMode: blendMode,
        strokes: strokes.map((stroke) => stroke.toRust()).toList(),
      );
    }

    return rust_doc.Layer(
      name: name,
      opacity: opacity,
      visible: visible,
      blendMode: blendMode,
      strokes: const <rust_stroke.Stroke>[],
      raster: rust_doc.RasterInfo(
        width: surface.width,
        height: surface.height,
        tileSize: surface.tileSize,
        tiles: <rust_doc.TileRef>[
          for (final (x, y) in surface.liveTiles) rust_doc.TileRef(x: x, y: y),
        ],
      ),
    );
  }

  /// 从持久化结构还原。
  ///
  /// [tiles] 由 `DocumentStore` 从瓦片文件读出后传入——像素 I/O 不在模型层做，
  /// 否则这个类会依赖文件系统，单元测试就得造目录。
  factory DrawingLayer.fromRust(
    rust_doc.Layer source, {
    required String id,
    Map<TileKey, Uint8List>? tiles,
  }) {
    final info = source.raster;
    final raster = info == null
        ? null
        : RasterSurface.fromTiles(
            width: info.width,
            height: info.height,
            tileSize: info.tileSize,
            tiles: tiles ?? <TileKey, Uint8List>{},
          );

    return DrawingLayer(
      id: id,
      name: source.name,
      opacity: source.opacity.clamp(0.0, 1.0),
      visible: source.visible,
      blendMode: source.blendMode,
      strokes: raster == null
          ? source.strokes.map(Stroke.fromRust).toList()
          : const <Stroke>[],
      raster: raster,
    );
  }
}
