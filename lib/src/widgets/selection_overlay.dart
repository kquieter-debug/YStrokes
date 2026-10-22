import 'package:flutter/material.dart';

/// 选区与变换的覆盖层（注意：`SelectionOverlay` 这个名字已被 material 占用，
/// 那里指的是文本选区的工具栏，两者无关）。
///
/// 只画**屏幕坐标**：套索路径、变换框、四个角柄与旋转柄。归一化坐标 → 屏幕坐标
/// 的换算由画板完成（那里才有视口与文档矩形），这一层因此不需要知道视口存在。
///
/// 变换框用**四边形**而不是 `Rect`：视口可以旋转，文档里的水平边到了屏幕上就是
/// 斜的。用轴对齐矩形画会在旋转后明显错位，而四个角点的连线在任何视角下都正确。
class SelectionLayer extends StatelessWidget {
  const SelectionLayer({
    super.key,
    this.lasso,
    this.corners,
    this.showHandles = false,
    this.accent = const Color(0xFF2563EB),
  });

  /// 正在画的套索（屏幕坐标，未闭合）；闭合后为 null。
  final List<Offset>? lasso;

  /// 变换框四角（屏幕坐标，顺序为左上、右上、右下、左下）。
  final List<Offset>? corners;

  /// 是否画手柄（只有处于变换态时才画）。
  final bool showHandles;

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _SelectionPainter(
          lasso: lasso,
          corners: corners,
          showHandles: showHandles,
          accent: accent,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 手柄几何常量：绘制与命中测试同源。
///
/// 这两处一旦各写一套，「看起来能拖、实际拖不动」的问题就会反复出现。
class SelectionMetrics {
  const SelectionMetrics._();

  /// 角柄半边长（正方形手柄）。
  static const double handleRadius = 7;

  /// 命中容差：比手柄本身大一圈，手指比鼠标粗。
  static const double hitRadius = 22;

  /// 旋转柄相对上沿中点的外扩距离（屏幕像素）。
  static const double rotateOffset = 32;

  /// 旋转柄半径。
  static const double rotateRadius = 7;
}

/// 旋转柄位置：上沿中点沿「背离中心」方向外扩。
///
/// 用四边形自己的法向而不是固定向上，框旋转后手柄才会跟着转到合适位置。
Offset rotateHandleFor(List<Offset> corners) {
  final topMid = (corners[0] + corners[1]) / 2;
  final center = (corners[0] + corners[2]) / 2;
  final outward = topMid - center;
  final length = outward.distance;
  if (length < 1e-6) {
    return topMid - const Offset(0, SelectionMetrics.rotateOffset);
  }
  return topMid + outward / length * SelectionMetrics.rotateOffset;
}

/// 点是否落在四边形内（用两个三角形判定）。
bool quadContains(List<Offset> corners, Offset point) =>
    _triangleContains(corners[0], corners[1], corners[2], point) ||
    _triangleContains(corners[0], corners[2], corners[3], point);

bool _triangleContains(Offset a, Offset b, Offset c, Offset p) {
  double cross(Offset u, Offset v) => u.dx * v.dy - u.dy * v.dx;
  final ab = cross(b - a, p - a);
  final bc = cross(c - b, p - b);
  final ca = cross(a - c, p - c);
  return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0);
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.lasso,
    required this.corners,
    required this.showHandles,
    required this.accent,
  });

  final List<Offset>? lasso;
  final List<Offset>? corners;
  final bool showHandles;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    _paintLasso(canvas);
    _paintFrame(canvas);
  }

  void _paintLasso(Canvas canvas) {
    final points = lasso;
    if (points == null || points.length < 2) return;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }

    // 闭合填充：让「圈住了什么」一眼可见。
    if (points.length >= 3) {
      canvas.drawPath(
        Path.from(path)..close(),
        Paint()..color = accent.withValues(alpha: 0.10),
      );
    }

    // 先垫一条浅色实线，再叠深色虚线：纸面可深可浅，单色必然在某种底色上消失。
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.75)
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      _dashed(path),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = accent
        ..isAntiAlias = true,
    );
  }

  void _paintFrame(Canvas canvas) {
    final quad = corners;
    if (quad == null) return;

    final path = Path()..addPolygon(quad, true);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.8)
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      _dashed(path),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = accent
        ..isAntiAlias = true,
    );

    if (!showHandles) return;

    final handleFill = Paint()..color = Colors.white;
    final handleStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = accent;

    for (final corner in quad) {
      final square = Rect.fromCenter(
        center: corner,
        width: SelectionMetrics.handleRadius * 2,
        height: SelectionMetrics.handleRadius * 2,
      );
      final rounded = RRect.fromRectAndRadius(square, const Radius.circular(2));
      canvas.drawRRect(rounded, handleFill);
      canvas.drawRRect(rounded, handleStroke);
    }

    // 旋转柄：一根细线连到上沿中点，说明它属于这个框。
    final rotate = rotateHandleFor(quad);
    final topMid = (quad[0] + quad[1]) / 2;
    canvas.drawLine(
      topMid,
      rotate,
      Paint()
        ..strokeWidth = 1.2
        ..color = accent.withValues(alpha: 0.7),
    );
    canvas.drawCircle(rotate, SelectionMetrics.rotateRadius, handleFill);
    canvas.drawCircle(rotate, SelectionMetrics.rotateRadius, handleStroke);
  }

  /// 转成虚线：按 `PathMetric` 逐段截取。
  Path _dashed(Path source) {
    const dash = 6.0;
    const gap = 5.0;
    final result = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        result.addPath(metric.extractPath(distance, end), Offset.zero);
        distance = end + gap;
      }
    }
    return result;
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) =>
      oldDelegate.lasso != lasso ||
      oldDelegate.corners != corners ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.accent != accent;
}
