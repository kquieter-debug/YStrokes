import 'dart:math' as math;
import 'dart:ui';

/// 画布视口：把「文档坐标」映射到「屏幕坐标」。
///
/// 变换形式（以文档矩形中心为轴心）：
///
/// ```
/// screen = center + offset + R(rotation) · (scale · (doc - center))
/// ```
///
/// 之所以绕中心而不是左上角：缩放与旋转时画布不会突然跑出视野，
/// 这也是 Photoshop 的默认手感。
///
/// 该类是纯计算、无副作用，手势、渲染与命中测试共用同一份实现，
/// 避免三处各写一套三角函数导致偏差。
class CanvasViewport {
  const CanvasViewport({
    this.scale = 1.0,
    this.rotation = 0.0,
    this.offset = Offset.zero,
  });

  /// 缩放倍数，1.0 表示「适配画布」。
  final double scale;

  /// 旋转弧度。
  final double rotation;

  /// 屏幕空间平移（像素）。
  final Offset offset;

  static const double minScale = 0.25;
  static const double maxScale = 12.0;

  bool get isIdentity =>
      scale == 1.0 && rotation == 0.0 && offset == Offset.zero;

  CanvasViewport copyWith({
    double? scale,
    double? rotation,
    Offset? offset,
  }) =>
      CanvasViewport(
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        offset: offset ?? this.offset,
      );

  /// 文档坐标 → 屏幕坐标。
  Offset toScreen(Offset doc, Rect docRect) {
    final center = docRect.center;
    final v = doc - center;
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);
    return Offset(
          center.dx + offset.dx + (v.dx * cos - v.dy * sin) * scale,
          center.dy + offset.dy + (v.dx * sin + v.dy * cos) * scale,
        );
  }

  /// 屏幕坐标 → 文档坐标（[toScreen] 的逆）。
  Offset toDocument(Offset screen, Rect docRect) {
    if (scale <= 0) return docRect.center;
    final center = docRect.center;
    final d = screen - center - offset;
    final cos = math.cos(-rotation);
    final sin = math.sin(-rotation);
    final rx = d.dx * cos - d.dy * sin;
    final ry = d.dx * sin + d.dy * cos;
    return Offset(center.dx + rx / scale, center.dy + ry / scale);
  }

  /// 把变换应用到画布上；调用方负责 [Canvas.save] / [Canvas.restore]。
  void applyTo(Canvas canvas, Rect docRect) {
    final center = docRect.center;
    canvas.translate(center.dx + offset.dx, center.dy + offset.dy);
    canvas.rotate(rotation);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);
  }

  /// 由一次双指手势得到新的视口。
  ///
  /// 采用「焦点锚定」：手势开始时双指中点下的那个文档点，在手势结束后仍应
  /// 落在双指中点下。否则缩放会围绕画布中心跑，手指一动画面就漂走。
  ///
  /// - [startCentroid] / [currentCentroid]：屏幕坐标的双指中点
  /// - [scaleFactor]：本次手势的缩放倍数
  /// - [rotationDelta]：本次手势的旋转增量（弧度）
  CanvasViewport applyGesture({
    required Offset startCentroid,
    required Offset currentCentroid,
    required double scaleFactor,
    required double rotationDelta,
    required Rect docRect,
  }) {
    final anchor = toDocument(startCentroid, docRect);
    final nextScale = (scale * scaleFactor).clamp(minScale, maxScale);
    final nextRotation = _normalizeAngle(rotation + rotationDelta);

    final center = docRect.center;
    final v = anchor - center;
    final cos = math.cos(nextRotation);
    final sin = math.sin(nextRotation);
    final rotated = Offset(
      (v.dx * cos - v.dy * sin) * nextScale,
      (v.dx * sin + v.dy * cos) * nextScale,
    );

    return CanvasViewport(
      scale: nextScale,
      rotation: nextRotation,
      offset: currentCentroid - center - rotated,
    );
  }

  /// 归一化到 (-π, π]，避免长时间旋转后角度无限增长（影响数值精度）。
  static double _normalizeAngle(double radians) {
    const twoPi = math.pi * 2;
    var value = radians % twoPi;
    if (value <= -math.pi) value += twoPi;
    if (value > math.pi) value -= twoPi;
    return value;
  }
}
