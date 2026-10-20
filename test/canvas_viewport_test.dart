import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/canvas_viewport.dart';

/// 视口变换的纯数学行为。
void main() {
  const docRect = Rect.fromLTWH(0, 0, 300, 400);
  final center = docRect.center;

  test('默认视口不改变坐标', () {
    const viewport = CanvasViewport();
    expect(viewport.isIdentity, isTrue);

    const p = Offset(123, 45);
    expect(viewport.toScreen(p, docRect), p);
    expect(viewport.toDocument(p, docRect), p);
  });

  test('屏幕与文档坐标可互相还原', () {
    const viewport = CanvasViewport(
      scale: 2.4,
      rotation: 0.7,
      offset: Offset(35, -18),
    );

    for (final point in <Offset>[
      const Offset(0, 0),
      const Offset(300, 400),
      const Offset(150, 200),
      const Offset(-40, 520),
    ]) {
      final screen = viewport.toScreen(point, docRect);
      final back = viewport.toDocument(screen, docRect);
      expect(back.dx, closeTo(point.dx, 1e-9));
      expect(back.dy, closeTo(point.dy, 1e-9));
    }
  });

  test('缩放时双指中点下的文档点保持不动', () {
    const start = CanvasViewport();
    const startCentroid = Offset(90, 120);

    final anchor = start.toDocument(startCentroid, docRect);
    final zoomed = start.applyGesture(
      startCentroid: startCentroid,
      currentCentroid: startCentroid,
      scaleFactor: 2.0,
      rotationDelta: 0,
      docRect: docRect,
    );

    expect(zoomed.scale, closeTo(2.0, 1e-9));
    final anchorAfter = zoomed.toScreen(anchor, docRect);
    expect(anchorAfter.dx, closeTo(startCentroid.dx, 1e-6));
    expect(anchorAfter.dy, closeTo(startCentroid.dy, 1e-6));
  });

  test('双指整体平移等价于视口平移', () {
    const start = CanvasViewport();
    const from = Offset(100, 100);
    const to = Offset(140, 130);

    final moved = start.applyGesture(
      startCentroid: from,
      currentCentroid: to,
      scaleFactor: 1.0,
      rotationDelta: 0,
      docRect: docRect,
    );

    expect(moved.scale, 1.0);
    expect(moved.offset.dx, closeTo(40, 1e-9));
    expect(moved.offset.dy, closeTo(30, 1e-9));
  });

  test('旋转后锚点仍在双指中点', () {
    const start = CanvasViewport(scale: 1.5);
    const startCentroid = Offset(180, 140);

    final anchor = start.toDocument(startCentroid, docRect);
    final rotated = start.applyGesture(
      startCentroid: startCentroid,
      currentCentroid: startCentroid,
      scaleFactor: 1.0,
      rotationDelta: math.pi / 3,
      docRect: docRect,
    );

    expect(rotated.rotation, closeTo(math.pi / 3, 1e-9));
    final anchorAfter = rotated.toScreen(anchor, docRect);
    expect(anchorAfter.dx, closeTo(startCentroid.dx, 1e-6));
    expect(anchorAfter.dy, closeTo(startCentroid.dy, 1e-6));
  });

  test('缩放被夹在允许范围内', () {
    const start = CanvasViewport(scale: 1);

    final tooBig = start.applyGesture(
      startCentroid: center,
      currentCentroid: center,
      scaleFactor: 100,
      rotationDelta: 0,
      docRect: docRect,
    );
    expect(tooBig.scale, CanvasViewport.maxScale);

    final tooSmall = start.applyGesture(
      startCentroid: center,
      currentCentroid: center,
      scaleFactor: 0.0001,
      rotationDelta: 0,
      docRect: docRect,
    );
    expect(tooSmall.scale, CanvasViewport.minScale);
  });

  test('旋转角被归一化到 (-π, π]', () {
    const start = CanvasViewport();
    final spun = start.applyGesture(
      startCentroid: center,
      currentCentroid: center,
      scaleFactor: 1,
      rotationDelta: 10 * math.pi,
      docRect: docRect,
    );

    expect(spun.rotation, greaterThan(-math.pi - 1e-9));
    expect(spun.rotation, lessThanOrEqualTo(math.pi + 1e-9));
  });

  test('scale 为 0 时反算退化为文档中心，不产生除零', () {
    const broken = CanvasViewport(scale: 0);
    expect(broken.toDocument(const Offset(10, 10), docRect), docRect.center);
  });
}
