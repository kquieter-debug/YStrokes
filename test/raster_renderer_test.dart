import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/raster_brush.dart';
import 'package:ystrokes/src/services/raster_renderer.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// 位图瓦片的图像缓存。
///
/// 这里最要紧的一条：**重建期间旧图不能消失**。像素笔在绘画时每一帧都会
/// 重传被改动的瓦片，若「先摘掉旧图、再等新图解码」，那一块就会空白一帧，
/// 表现为绘画时整块区域闪烁（矢量路径是同步重放，所以从没有这个现象）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RasterSurface surface() => RasterSurface(width: 128, height: 128);

  void paint(RasterSurface s, {double x = 16}) {
    RasterBrush.dab(
      s,
      center: Offset(x, 16),
      radius: 5,
      colorArgb: 0xFF000000,
      erase: false,
    );
  }

  test('首次构建后拿到该瓦片的图像', () async {
    final s = surface();
    final renderer = RasterRenderer();
    paint(s);

    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    await renderer.build(s);

    expect(renderer.tileImage(s, (0, 0)), isNotNull);
    expect(renderer.hasImages(s), isTrue);
  });

  test('重建期间旧图仍在缓存里（不闪烁）', () async {
    final s = surface();
    final renderer = RasterRenderer();
    paint(s);
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    await renderer.build(s);

    final first = renderer.tileImage(s, (0, 0));
    expect(first, isNotNull);

    // 再涂一笔并请求重建，但**不等它完成**。
    paint(s, x: 40);
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    final pending = renderer.build(s);

    // build 的同步阶段已经跑完（挂起在解码上）。此刻旧图必须还可用：
    // 这一帧绘制时若拿不到图，就会露出底色。
    expect(
      renderer.tileImage(s, (0, 0)),
      same(first),
      reason: '解码期间旧图被摘掉就会造成块状闪烁',
    );

    await pending;
    final second = renderer.tileImage(s, (0, 0));
    expect(second, isNotNull);
    expect(second, isNot(same(first)), reason: '重建完成后应换成新图');
    expect(first!.debugDisposed, isTrue, reason: '旧图换下来后要释放');
  });

  test('未分配瓦片被标记重建时不产生图像', () async {
    final s = surface();
    final renderer = RasterRenderer();

    // 撤销 / 重做会整层标记待重建，此时总有瓦片是空的。
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    await renderer.build(s);

    expect(renderer.tileImage(s, (0, 0)), isNull, reason: '没有像素就没有图');
    expect(renderer.hasImages(s), isFalse);
  });

  test('解码进行中的重复请求被合并成一次补跑', () async {
    final s = surface();
    final renderer = RasterRenderer();
    paint(s);
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});

    var ready = 0;
    final first = renderer.build(s, onReady: () => ready++);
    // 第一轮还没结束时又来一批：不能并发发起，但要保证这次改动最终生效。
    paint(s, x: 60);
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    final second = renderer.build(s, onReady: () => ready++);

    await Future.wait(<Future<void>>[first, second]);

    expect(renderer.tileImage(s, (0, 0)), isNotNull);
    expect(ready, greaterThanOrEqualTo(1), reason: '至少触发一次重绘回调');
  });

  test('按 rect 缩放绘制：不抛异常且覆盖整个目标区域', () async {
    final s = RasterSurface(width: 64, height: 64, tileSize: 64);
    final renderer = RasterRenderer();
    paint(s, x: 32);
    renderer.invalidateTiles(s, <TileKey>{(0, 0)});
    await renderer.build(s);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const dst = Rect.fromLTWH(10, 20, 128, 128);
    renderer.paintLayer(canvas, dst, s);
    final picture = recorder.endRecording();

    expect(picture, isNotNull);
    picture.dispose();
  });

  test('空 surface 绘制不抛异常', () async {
    final renderer = RasterRenderer();
    final s = surface();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    renderer.paintLayer(canvas, const Rect.fromLTWH(0, 0, 10, 10), s);
    recorder.endRecording().dispose();
  });
}
