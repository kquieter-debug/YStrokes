import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'raster_surface.dart';

/// 供给 `paintDocument` 的位图来源。
///
/// 抽成接口是因为像素到 [ui.Image] 的转换**天生是异步的**
/// （`decodeImageFromPixels` 只能回调），而 `Canvas` 绘制必须同步。
/// 接口因此只暴露「画这一层」，异步补齐由实现方在绘制之前完成，
/// 绘制路径本身保持纯粹、可被导出与缩略图复用。
abstract class RasterTileSource {
  /// 把某一层的像素画到 [rect] 内。调用方已经处理不透明度与混合。
  void paintLayer(Canvas canvas, Rect rect, RasterSurface surface);
}

/// 位图瓦片的图像缓存与绘制。
///
/// ## 为什么按瓦片而不是整层
///
/// 一层 1080×1920 是 8 MB。若要每帧上传整层，等于把绘制成本绑在画布面积上；
/// 而一笔通常只改 1–4 块 256×256 瓦片，重传 0.25–1 MB 就够了。
/// 瓦片还天然是脏区缓存的单位（ROADMAP R14/R15）。
///
/// ## 与「活动笔画」的关系
///
/// 像素笔**不做第二套预览几何**：笔画直接写进 surface，然后重建被改动的瓦片。
/// 这样「屏幕上的像素」与「存下来的像素」是同一份数据，不存在
/// 预览与提交结果不一致的可能（ADR-006 对矢量笔画的要求，在像素上同样成立）。
/// 代价是像素内容比手指慢一帧——这是异步上传的下限，不是实现瑕疵。
class RasterRenderer implements RasterTileSource {
  final Expando<_SurfaceCache> _caches = Expando<_SurfaceCache>('rasterTiles');

  /// 正在构建的 surface（避免同一帧重复发起）。
  final Set<RasterSurface> _building = <RasterSurface>{};

  /// 构建期间又被要求重建的 surface（合并成一次补跑）。
  final Set<RasterSurface> _rerun = <RasterSurface>{};

  _SurfaceCache _cacheFor(RasterSurface surface) =>
      _caches[surface] ??= _SurfaceCache();

  /// 取某个瓦片已就绪的图像；未就绪返回 null（这一帧先不画它）。
  ui.Image? tileImage(RasterSurface surface, TileKey key) =>
      _cacheFor(surface).images[key];

  /// 把某个 surface 的全部瓦片标记为待重建。
  ///
  /// 撤销 / 重做 / 栅格化会整份替换内容，此时无法推断改了哪几块，
  /// 只能全量重建——这些都是低频操作。
  void invalidateAll(RasterSurface surface) {
    final cache = _cacheFor(surface);
    cache.pending
      ..clear()
      ..addAll(surface.allocatedTiles);
    // 之前有图、现在可能已经没有像素的瓦片也要重建（否则残留旧内容）。
    cache.pending.addAll(cache.images.keys);
  }

  /// 把指定瓦片标记为待重建（笔画过程中用 `surface.dirtyTiles`）。
  void invalidateTiles(RasterSurface surface, Iterable<TileKey> keys) {
    _cacheFor(surface).pending.addAll(keys);
  }

  /// 重建待办瓦片；[onReady] 在有内容更新时回调一次（用于触发重绘）。
  ///
  /// 重复调用会被合并：一次构建进行中再来的请求，等这次结束后补跑一遍，
  /// 而不是并发发起两批解码。
  Future<void> build(RasterSurface surface, {VoidCallback? onReady}) async {
    final cache = _cacheFor(surface);
    if (cache.pending.isEmpty && !_rerun.contains(surface)) return;

    if (_building.contains(surface)) {
      _rerun.add(surface);
      return;
    }
    _building.add(surface);

    var built = false;
    try {
      do {
        _rerun.remove(surface);
        final keys = Set<TileKey>.of(cache.pending);
        cache.pending.clear();
        if (keys.isEmpty) break;

        for (final key in keys) {
          final data = surface.tile(key.$1, key.$2);

          // 瓦片不存在了（整层被替换 / 内容被丢弃）：这一块必须清空。
          if (data == null) {
            final removed = cache.images.remove(key);
            if (removed != null) {
              removed.dispose();
              built = true;
            }
            continue;
          }

          // 解码是异步的，期间像素笔还在往同一块缓冲里写。直接传活缓冲会让
          // 上传的图像与「此刻的像素」错开半帧，表现为笔迹边缘抖动。
          final image =
              await _decodeTile(Uint8List.fromList(data), surface.tileSize);
          if (image == null) continue;

          // **新图就绪之后才换下旧图**。先移除再 await 会让这块瓦片在解码期间
          // 缺席一帧，绘制时直接跳过它——这就是绘画过程中看到的「块状闪烁」。
          final old = cache.images[key];
          cache.images[key] = image;
          old?.dispose();
          built = true;
        }
      } while (_rerun.contains(surface));
    } finally {
      _building.remove(surface);
    }

    if (built) onReady?.call();
  }

  /// 同步判断某层是否还有未就绪的瓦片（绘制方据此决定要不要再等一帧）。
  bool hasPending(RasterSurface surface) => _cacheFor(surface).pending.isNotEmpty;

  /// 画一整层。调用方负责已 `saveLayer`（不透明度 / 混合模式 / 擦除隔离）。
  @override
  void paintLayer(Canvas canvas, Rect rect, RasterSurface surface) {
    if (rect.isEmpty) return;
    final scaleX = rect.width / surface.width;
    final scaleY = rect.height / surface.height;
    final paint = Paint()..filterQuality = FilterQuality.low;

    for (final entry in _cacheFor(surface).images.entries) {
      final (tx, ty) = entry.key;
      final dst = Rect.fromLTWH(
        rect.left + tx * surface.tileSize * scaleX,
        rect.top + ty * surface.tileSize * scaleY,
        surface.tileSize * scaleX,
        surface.tileSize * scaleY,
      );
      canvas.drawImageRect(
        entry.value,
        Rect.fromLTWH(
          0,
          0,
          entry.value.width.toDouble(),
          entry.value.height.toDouble(),
        ),
        dst,
        paint,
      );
    }
  }

  /// 该 surface 是否已经至少有一块可画的瓦片（用于「还没准备好」的判断）。
  bool hasImages(RasterSurface surface) => _cacheFor(surface).images.isNotEmpty;

  /// 释放全部缓存图像。同一时刻可能有多个 surface（一个位图图层一张）。
  void disposeSurface(RasterSurface surface) {
    final cache = _caches[surface];
    if (cache == null) return;
    for (final image in cache.images.values) {
      image.dispose();
    }
    cache.images.clear();
    cache.pending.clear();
  }

  void dispose() {
    // Expando 无法枚举，逐一释放交给调用方按 surface 调用 [disposeSurface]。
  }

  /// 像素缓冲 → [ui.Image]。
  ///
  /// `rgba8888` 是**非预乘**格式，与 [RasterSurface] 的存储约定一致；
  /// Flutter 会把预乘转换做在解码里，因此这里不需要自己乘 alpha。
  static Future<ui.Image?> _decodeTile(Uint8List data, int tileSize) {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      data,
      tileSize,
      tileSize,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!completer.isCompleted) completer.complete(image);
      },
    );
    return completer.future;
  }
}

/// 单个 surface 的缓存状态。
///
/// 独立成类是为了让 `Expando` 只管理一处生命周期：surface 被回收时，
/// 缓存对象随之消失（图像本身仍需要显式 dispose，见 [RasterRenderer.disposeSurface]）。
class _SurfaceCache {
  final Map<TileKey, ui.Image> images = <TileKey, ui.Image>{};
  final Set<TileKey> pending = <TileKey>{};
}
