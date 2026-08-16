import '../rust/api.dart';

/// 一条完整笔画：由若干归一化采样点组成。
///
/// 采样点坐标使用归一化坐标（0.0 ~ 1.0），渲染时再乘以画布尺寸还原，
/// 从而使 Rust 侧几何处理与屏幕分辨率解耦。
class Stroke {
  Stroke({
    required this.id,
    required this.color,
    required this.width,
    required this.points,
  });

  /// 会话内自增 id，用于区分笔画。
  final int id;

  /// ARGB 颜色值（0xAARRGGBB）。
  final int color;

  /// 笔画粗细（逻辑像素）。
  final double width;

  /// 归一化坐标采样点（0.0 ~ 1.0）。
  final List<StrokePoint> points;
}
