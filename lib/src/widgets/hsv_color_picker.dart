import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 色相环 + 饱和度/明度方块取色器。
///
/// 几何关系：
/// - 外圈是色相环（sweep 渐变），拖动改变 H；
/// - 内接正方形是 SV 区，横轴为饱和度、纵轴为明度（上亮下暗）。
///
/// 交互取舍：色相环与方块各自独立响应拖动，但一旦按下就不允许在两者之间
/// 切换——否则手指划出边界时色相会突然跳到别处，是这类控件最常见的糟糕手感。
class HsvColorPicker extends StatefulWidget {
  const HsvColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 240,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final double size;

  @override
  State<HsvColorPicker> createState() => _HsvColorPickerState();
}

class _HsvColorPickerState extends State<HsvColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);

  /// 最近一次由本控件发出的颜色，用于区分「外部改色」与「回声」。
  Color? _emitted;

  /// 当前拖动区域：0 未拖、1 色相环、2 SV 方块。
  int _activeRegion = 0;

  double get _outerRadius => widget.size / 2 - 2;
  double get _ringWidth => widget.size * 0.13;

  /// SV 方块的半边长度：取内接正方形并留一点余量。
  double get _halfSide =>
      (_outerRadius - _ringWidth) * 0.94 / math.sqrt2;

  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  Rect get _squareRect => Rect.fromCenter(
        center: _center,
        width: _halfSide * 2,
        height: _halfSide * 2,
      );

  @override
  void didUpdateWidget(HsvColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color != oldWidget.color && widget.color != _emitted) {
      _hsv = HSVColor.fromColor(widget.color);
    }
  }

  void _handlePan(Offset local, {required bool isStart}) {
    if (isStart) {
      _activeRegion = _squareRect.contains(local) ? 2 : 1;
    }

    if (_activeRegion == 2) {
      final rect = _squareRect;
      final s = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
      final v = 1 - ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
      _emit(_hsv.withSaturation(s).withValue(v));
      return;
    }

    final delta = local - _center;
    if (delta.distanceSquared < 1) return;
    // atan2 在屏幕坐标系（y 向下）里正好是顺时针增长，与 sweep 渐变方向一致。
    final angle = math.atan2(delta.dy, delta.dx);
    final hue = ((angle / (2 * math.pi)) % 1 + 1) % 1 * 360;
    _emit(_hsv.withHue(hue));
  }

  void _emit(HSVColor value) {
    setState(() => _hsv = value);
    final color = value.toColor();
    _emitted = color;
    widget.onChanged(color);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _handlePan(details.localPosition, isStart: true),
      onTapUp: (_) => _activeRegion = 0,
      onPanStart: (details) => _handlePan(details.localPosition, isStart: true),
      onPanUpdate: (details) =>
          _handlePan(details.localPosition, isStart: false),
      onPanEnd: (_) => _activeRegion = 0,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _HsvPainter(
            hsv: _hsv,
            outerRadius: _outerRadius,
            ringWidth: _ringWidth,
            squareRect: _squareRect,
          ),
        ),
      ),
    );
  }
}

class _HsvPainter extends CustomPainter {
  const _HsvPainter({
    required this.hsv,
    required this.outerRadius,
    required this.ringWidth,
    required this.squareRect,
  });

  final HSVColor hsv;
  final double outerRadius;
  final double ringWidth;
  final Rect squareRect;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringMid = outerRadius - ringWidth / 2;

    // ---- 色相环 ----
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..isAntiAlias = true
      ..shader = const SweepGradient(
        colors: <Color>[
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(
        Rect.fromCircle(center: center, radius: ringMid + ringWidth),
      );
    canvas.drawCircle(center, ringMid, ringPaint);

    // 环上的当前色相指示器。
    final hueAngle = hsv.hue / 180 * math.pi;
    final marker = Offset(
      center.dx + math.cos(hueAngle) * ringMid,
      center.dy + math.sin(hueAngle) * ringMid,
    );
    canvas.drawCircle(marker, ringWidth * 0.42, Paint()..color = Colors.white);
    canvas.drawCircle(
      marker,
      ringWidth * 0.42,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black26,
    );

    // ---- SV 方块 ----
    // 底层是当前色相的全饱和色，其上叠加「白→透明」与「透明→黑」两个渐变。
    final base = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    final rect = squareRect;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(rect, Paint()..color = base);

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    canvas.restore();

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white24,
    );

    // SV 指示器。
    final cursor = Offset(
      rect.left + hsv.saturation * rect.width,
      rect.top + (1 - hsv.value) * rect.height,
    );
    canvas.drawCircle(cursor, 9, Paint()..color = Colors.white);
    canvas.drawCircle(
      cursor,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black45,
    );
  }

  @override
  bool shouldRepaint(covariant _HsvPainter oldDelegate) =>
      oldDelegate.hsv != hsv ||
      oldDelegate.outerRadius != outerRadius ||
      oldDelegate.ringWidth != ringWidth ||
      oldDelegate.squareRect != squareRect;
}
