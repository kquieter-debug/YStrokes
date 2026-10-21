import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../rust/api/stroke.dart' as rust;
import 'stroke_outline.dart';

/// 把归一化笔画渲染到文档矩形内，采样点之间以二次贝塞尔平滑连接。
///
/// 直接 `lineTo` 会让快速运笔出现肉眼可见的折角；这里以相邻采样点的中值作为
/// 曲线端点、原始点作为控制点，得到与笔迹走向贴合且切线连续的路径。
///
/// [pressure] 为真时改走「按点宽生成轮廓再填充」的分支（见 [buildStrokeOutline]）。
/// 默认关闭，且关闭时的绘制指令与引入压感之前**逐位相同**——这是零回归的结构性
/// 保证，不靠「参数恰好相等」来达成。
void paintStrokePath(
  Canvas canvas,
  Rect rect,
  List<rust.StrokePoint> points,
  int color,
  double width, {
  bool erase = false,
  bool pressure = false,
}) {
  if (points.isEmpty || rect.isEmpty) return;

  Offset toOffset(rust.StrokePoint p) =>
      Offset(rect.left + p.x * rect.width, rect.top + p.y * rect.height);

  if (pressure) {
    final fillPaint = Paint()
      ..color = Color(color)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    if (erase) fillPaint.blendMode = BlendMode.clear;

    if (points.length == 1) {
      // 单点：轮廓退化为零面积，仍按圆点绘制，半径随该点压力缩放。
      final radius = width * pressureWidthFactor(points.first.pressure) / 2;
      canvas.drawCircle(toOffset(points.first), radius, fillPaint);
      return;
    }

    final outline = buildStrokeOutline(
      points: points,
      spaceWidth: rect.width,
      spaceHeight: rect.height,
      baseWidth: width,
      pressure: true,
    );
    if (outline.isEmpty) return;
    canvas.drawPath(
      outlineToPath(outline, translate: rect.topLeft),
      fillPaint,
    );
    return;
  }

  // 橡皮以「清空」方式合成：颜色无关紧要，混合模式才是关键。
  // 调用方必须先把笔画放进独立图层，否则 clear 会连纸面一起擦掉。
  final strokePaint = Paint()
    ..color = Color(color)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  if (erase) strokePaint.blendMode = BlendMode.clear;

  if (points.length == 1) {
    // 单点：轻点画布应留下一个圆点，而不是什么都没有。
    final dotPaint = Paint()
      ..color = Color(color)
      ..isAntiAlias = true;
    if (erase) dotPaint.blendMode = BlendMode.clear;
    canvas.drawCircle(toOffset(points.first), width / 2, dotPaint);
    return;
  }

  final path = Path();
  final first = toOffset(points.first);
  path.moveTo(first.dx, first.dy);

  for (var i = 1; i < points.length - 1; i++) {
    final current = toOffset(points[i]);
    final next = toOffset(points[i + 1]);
    final mid = Offset((current.dx + next.dx) / 2, (current.dy + next.dy) / 2);
    path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
  }

  final last = toOffset(points.last);
  path.lineTo(last.dx, last.dy);
  canvas.drawPath(path, strokePaint);
}

/// 绘制整篇文档：纸面 + 各图层。
///
/// 每个图层单独 `saveLayer`，原因是它同时承担两件事：
/// 1. 合成不透明度——整层乘一个 alpha；
/// 2. 隔离橡皮的 `BlendMode.clear`——擦除只能作用于本层，若直接画在画布上
///    会把下方纸面甚至其它图层一起擦穿。
///
/// [activeLayerId] 指定时，会把 [activePoints] 当作该图层末尾的一笔一起绘制，
/// 这样橡皮的实时预览发生在图层内部，效果与提交后一致。
///
/// 每条笔画按压感与否**由笔画自己决定**（`Stroke.usesPressure`），不读工具开关：
/// 开关只影响接下来画的笔。活动笔画还没有 `Stroke` 实体，因此由 [activePressure]
/// 单独传入——它取的就是当前工具的开关值。
void paintDocument(
  Canvas canvas,
  Rect rect,
  Color paperColor,
  List<DrawingLayer> layers, {
  String? activeLayerId,
  List<rust.StrokePoint> activePoints = const <rust.StrokePoint>[],
  int activeColor = 0xFF000000,
  double activeWidth = 1,
  bool activeErase = false,
  bool activePressure = false,
  bool drawPaper = true,
}) {
  if (drawPaper) {
    canvas.drawRect(rect, Paint()..color = paperColor);
  }

  for (final layer in layers) {
    if (!layer.visible || layer.opacity <= 0) continue;

    final isActive = layer.id == activeLayerId;
    final hasActive = isActive && activePoints.isNotEmpty;
    if (layer.strokes.isEmpty && !hasActive) continue;

    // 需要离屏合成的三种情况：带不透明度、带混层模式、含擦除笔画
    // （clear 必须限制在本层内）。三者都不成立时直接画，省一次 saveLayer。
    final needsLayer = layer.opacity < 0.999 ||
        !layer.blendMode.isNormal ||
        (activeErase && isActive) ||
        layer.strokes.any((stroke) => stroke.isEraser);
    if (needsLayer) {
      canvas.saveLayer(
        rect,
        Paint()
          ..color = Colors.black.withValues(alpha: layer.opacity)
          ..blendMode = layer.blendMode.blendMode,
      );
    }

    for (final stroke in layer.strokes) {
      paintStrokePath(
        canvas,
        rect,
        stroke.points,
        stroke.color,
        stroke.widthInPixels(rect.shortestSide),
        erase: stroke.isEraser,
        pressure: stroke.usesPressure,
      );
    }
    if (hasActive) {
      paintStrokePath(
        canvas,
        rect,
        activePoints,
        activeColor,
        activeWidth,
        erase: activeErase,
        pressure: activePressure,
      );
    }

    if (needsLayer) canvas.restore();
  }
}
