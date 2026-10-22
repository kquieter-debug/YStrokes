import 'dart:typed_data';

/// 瓦片坐标，`(x, y)` 以瓦片为单位、原点在左上角。
///
/// 用记录类型而不是自定义类：Dart 记录自带值语义的 `==` / `hashCode`，
/// 可以直接当 Map 键，避免再写一个「只用来做键」的样板类。
typedef TileKey = (int x, int y);

/// 一张位图图层的像素内容：按固定边长的瓦片**惰性分配**。
///
/// 这是 P2 的数据地基，刻意只做「像素怎么存」，不含任何绘制、UI 或 I/O：
/// - 绘制在 `raster_brush.dart`；
/// - 显示在 `raster_renderer.dart`；
/// - 落盘在 `tile_store.dart`。
///
/// ## 为什么是瓦片
///
/// 1080×1920 整层 RGBA 是 8.3 MB。一笔通常只碰到 1–4 块 256×256 瓦片
/// （0.25–1 MB），因此「按瓦片分配」让内存开销与实际涂过的面积成正比，
/// 而不是与画布面积成正比。空白瓦片既不占内存也不占磁盘。
///
/// ## 写时复制
///
/// 撤销需要「一笔之前的样子」。整层深拷贝在瓦片变多后不可接受（几十 MB/笔），
/// 因此 [fork] 只复制**瓦片表**（几十个键），像素缓冲仍然共享；
/// 谁要写入，谁先把自己那份瓦片拷出来（[writableTile]）。
/// 于是快照的成本是一次小 map 拷贝，而真正被改写的瓦片才付一次 memcpy——
/// 恰好等于「这一笔碰到的面积」。
///
/// 不变量：[tile] 返回的缓冲是**只读**的，任何写入必须走 [writableTile]。
class RasterSurface {
  RasterSurface({
    required this.width,
    required this.height,
    this.tileSize = defaultTileSize,
  })  : assert(width > 0, '位图宽度必须为正'),
        assert(height > 0, '位图高度必须为正'),
        assert(tileSize > 0 && tileSize <= maxTileSize, '瓦片边长超出允许范围');

  /// 默认瓦片边长。256 是渲染（上传成本）与碎片（空白浪费）的折中：
  /// 128 会让大画布产生上百块小纹理，512 则让「只涂了几笔」的图层也要多传一份。
  static const int defaultTileSize = 256;

  /// 瓦片边长上限，与 Rust 侧的 `MAX_TILE_SIZE` 保持一致。
  static const int maxTileSize = 512;

  /// 每像素字节数（RGBA8888，**非预乘**）。
  static const int bytesPerPixel = 4;

  /// 位图宽度（像素），恒等于文档宽度（D1：不做超采样）。
  final int width;

  /// 位图高度（像素），恒等于文档高度。
  final int height;

  /// 瓦片边长（像素）。
  final int tileSize;

  /// 已分配的瓦片。键一定是网格内的坐标。
  final Map<TileKey, Uint8List> _tiles = <TileKey, Uint8List>{};

  /// 本实例拥有、可以原地写入的瓦片。`fork` 之后为空，写入时按需补入。
  final Set<TileKey> _owned = <TileKey>{};

  /// 自上次落盘后被改写的瓦片（[clearDirty] 由保存流程调用）。
  final Set<TileKey> _dirty = <TileKey>{};

  /// 从一个已存在的瓦片表构造（仅供 [fork] 与测试使用）。
  RasterSurface._shadow(this.width, this.height, this.tileSize,
      Map<TileKey, Uint8List> tiles) {
    _tiles.addAll(tiles);
  }

  /// 横向瓦片数。
  int get columns => (width + tileSize - 1) ~/ tileSize;

  /// 纵向瓦片数。
  int get rows => (height + tileSize - 1) ~/ tileSize;

  /// 已分配的瓦片坐标（无序）。
  Iterable<TileKey> get allocatedTiles => _tiles.keys;

  /// **实际有内容**的瓦片：至少有一个像素的 alpha 非零。
  ///
  /// 与 [allocatedTiles] 的区别很重要：橡皮擦到全透明之后瓦片仍然分配着，
  /// 但它不需要落盘、也不该出现在文档的瓦片清单里。每次调用都会扫描像素，
  /// 只在保存与编码这类低频路径上使用。
  Set<TileKey> get liveTiles => <TileKey>{
        for (final entry in _tiles.entries)
          if (_hasInk(entry.value, width, height, tileSize, entry.key)) entry.key,
      };

  /// 已分配瓦片的数量。
  int get tileCount => _tiles.length;

  /// 尚未落盘的瓦片坐标。
  Set<TileKey> get dirtyTiles => Set<TileKey>.of(_dirty);

  /// 是否还没有任何瓦片（等价于「整层全透明」）。
  bool get isEmpty => _tiles.isEmpty;

  /// 已分配瓦片的字节总量，用作撤销预算的**保守**估值。
  ///
  /// 写时复制会让共享瓦片被重复计入，因此这个数字偏大；预算宁可紧一点，
  /// 也不要因为低估而在内存上失控。
  int get allocatedByteSize => _tiles.length * tileSize * tileSize * bytesPerPixel;

  /// 坐标是否落在网格内。
  bool containsTile(int tx, int ty) =>
      tx >= 0 && ty >= 0 && tx < columns && ty < rows;

  /// 读取一个瓦片的原始像素；未分配时返回 null。
  ///
  /// **返回的缓冲是只读的**：它与其它快照共享，写入会污染撤销历史。
  Uint8List? tile(int tx, int ty) => _tiles[(tx, ty)];

  /// 取得可写的瓦片缓冲，必要时分配（全透明）并做一次写时复制。
  ///
  /// 这是唯一的像素写入口，所有绘制模块都必须经由它。
  Uint8List writableTile(int tx, int ty) {
    assert(containsTile(tx, ty), '瓦片坐标越界：($tx, $ty)');
    final key = (tx, ty);
    var data = _tiles[key];

    if (data == null) {
      data = Uint8List(tileSize * tileSize * bytesPerPixel);
      _tiles[key] = data;
      _owned.add(key);
    } else if (!_owned.contains(key)) {
      // 与某个快照共享：先拷一份再写，快照保持原样。
      data = Uint8List.fromList(data);
      _tiles[key] = data;
      _owned.add(key);
    }

    _dirty.add(key);
    return data;
  }

  /// 取出整层像素（RGBA8888、非预乘、行优先），用于把整张图交给编码器。
  ///
  /// 只在「栅格化 / 导出」这类一次性操作里调用：它是 O(画布面积) 的全量拷贝。
  Uint8List toPixelBytes() {
    final out = Uint8List(width * height * bytesPerPixel);
    for (final entry in _tiles.entries) {
      final (tx, ty) = entry.key;
      final src = entry.value;
      final x0 = tx * tileSize;
      final y0 = ty * tileSize;
      final w = (width - x0).clamp(0, tileSize);
      final h = (height - y0).clamp(0, tileSize);
      if (w <= 0 || h <= 0) continue;

      for (var row = 0; row < h; row++) {
        final srcStart = row * tileSize * bytesPerPixel;
        final dstStart = ((y0 + row) * width + x0) * bytesPerPixel;
        out.setRange(
          dstStart,
          dstStart + w * bytesPerPixel,
          src,
          srcStart,
        );
      }
    }
    return out;
  }

  /// 读取一块矩形区域的像素（越界部分补透明）。
  ///
  /// 返回 `width × height × 4` 的 RGBA8888 非预乘缓冲，行优先。
  /// 只被「提起浮动选区」这类一次性操作使用，不参与逐笔路径。
  Uint8List readRegion(int left, int top, int width, int height) {
    final out = Uint8List(width * height * bytesPerPixel);
    if (width <= 0 || height <= 0) return out;

    for (var row = 0; row < height; row++) {
      final y = top + row;
      if (y < 0 || y >= this.height) continue;
      final ty = y ~/ tileSize;
      final tileRowBase = (y - ty * tileSize) * tileSize * bytesPerPixel;
      final dstRow = row * width * bytesPerPixel;

      for (var col = 0; col < width; col++) {
        final x = left + col;
        if (x < 0 || x >= this.width) continue;
        final tx = x ~/ tileSize;
        final data = _tiles[(tx, ty)];
        if (data == null) continue; // 空白瓦片 = 全透明，目标缓冲本来就是 0
        final src = tileRowBase + (x - tx * tileSize) * bytesPerPixel;
        final dst = dstRow + col * bytesPerPixel;
        out[dst] = data[src];
        out[dst + 1] = data[src + 1];
        out[dst + 2] = data[src + 2];
        out[dst + 3] = data[src + 3];
      }
    }
    return out;
  }

  /// 从整层像素构造（栅格化、导入图片）。全透明瓦片会被直接丢弃。
  factory RasterSurface.fromPixels(
    int width,
    int height,
    Uint8List rgba, {
    int tileSize = defaultTileSize,
  }) {
    final surface = RasterSurface(
      width: width,
      height: height,
      tileSize: tileSize,
    );
    final stride = width * bytesPerPixel;

    for (var ty = 0; ty < surface.rows; ty++) {
      for (var tx = 0; tx < surface.columns; tx++) {
        final x0 = tx * tileSize;
        final y0 = ty * tileSize;
        final w = (width - x0).clamp(0, tileSize);
        final h = (height - y0).clamp(0, tileSize);

        // 先扫一遍透明度：全透明的瓦片不值得分配（空白占多数是常态）。
        var opaque = false;
        for (var row = 0; row < h && !opaque; row++) {
          var index = (y0 + row) * stride + x0 * bytesPerPixel + 3;
          for (var col = 0; col < w; col++) {
            if (rgba[index] != 0) {
              opaque = true;
              break;
            }
            index += bytesPerPixel;
          }
        }
        if (!opaque) continue;

        final dst = surface.writableTile(tx, ty);
        for (var row = 0; row < h; row++) {
          final srcStart = (y0 + row) * stride + x0 * bytesPerPixel;
          dst.setRange(
            row * tileSize * bytesPerPixel,
            row * tileSize * bytesPerPixel + w * bytesPerPixel,
            rgba,
            srcStart,
          );
        }
      }
    }
    return surface;
  }

  /// 生成一份可写入的快照：像素共享，写入时才分裂。
  ///
  /// **分叉会让双方都放弃所有权**：谁先写，谁先把自己那份瓦片拷出来。
  /// 只让子对象「非拥有」是不够的——源对象如果继续原地写，快照会跟着一起变，
  /// 撤销历史就成了「引用活数据」的空壳。
  ///
  /// 撤销栈持有返回值；`_dirty` 不从源继承——快照本身不需要落盘，
  /// 只有在它被还原成当前内容时才由调用方 [markAllDirty]。
  RasterSurface fork() {
    final shadow = RasterSurface._shadow(width, height, tileSize, _tiles);
    _owned.clear();
    return shadow;
  }

  /// 从「瓦片坐标 → 像素缓冲」构造（加载磁盘时用）。
  ///
  /// 尺寸不符的缓冲会被跳过：PNG 文件被外部改动过时，宁可让那一块变透明，
  /// 也不要让一张 64×64 的图混进 256×256 的网格里越界读写。
  factory RasterSurface.fromTiles({
    required int width,
    required int height,
    required int tileSize,
    required Map<TileKey, Uint8List> tiles,
  }) {
    final surface = RasterSurface(
      width: width,
      height: height,
      tileSize: tileSize,
    );
    final expected = tileSize * tileSize * bytesPerPixel;
    for (final entry in tiles.entries) {
      final (tx, ty) = entry.key;
      if (!surface.containsTile(tx, ty)) continue;
      if (entry.value.length != expected) continue;
      surface._tiles[entry.key] = entry.value;
      surface._owned.add(entry.key);
    }
    return surface;
  }

  /// 把所有已分配瓦片标记为待落盘。
  ///
  /// 撤销 / 重做会把图层内容换成另一份快照，此时「哪些瓦片与磁盘不同」无法
  /// 可靠推断，只能保守地全量重写——撤销是低频操作，这个代价可以接受。
  void markAllDirty() {
    _dirty
      ..clear()
      ..addAll(_tiles.keys);
  }

  /// 清除脏标记（保存成功后调用）。
  void clearDirty() => _dirty.clear();

  /// 尺寸与网格是否兼容另一张 surface（撤销记录换层时用）。
  bool sameShapeAs(RasterSurface other) =>
      width == other.width &&
      height == other.height &&
      tileSize == other.tileSize;

  /// 瓦片内是否还有不透明的像素。
  ///
  /// 只检查 alpha 通道：RGB 为 0 但 alpha 也为 0 的像素等同于没有内容。
  static bool _hasInk(
    Uint8List data,
    int width,
    int height,
    int tileSize,
    TileKey key,
  ) {
    final (tx, ty) = key;
    final x0 = tx * tileSize;
    final y0 = ty * tileSize;
    final w = (width - x0).clamp(0, tileSize);
    final h = (height - y0).clamp(0, tileSize);
    if (w <= 0 || h <= 0) return false;

    for (var row = 0; row < h; row++) {
      var index = row * tileSize * bytesPerPixel + 3;
      for (var col = 0; col < w; col++) {
        if (data[index] != 0) return true;
        index += bytesPerPixel;
      }
    }
    return false;
  }
}
