import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';

/// 归一化笔宽 → 像素笔宽的**唯一换算入口**。
///
/// 画布预览、已提交笔画、缩略图与导出的基准宽度都必须经过这里，否则会出现
/// 「绘制中一种粗细、提交后另一种粗细」——这类偏差只在极细笔画上可见，
/// 排查成本极高。下限 1px 针对的是**输出空间**的像素：屏幕上是逻辑像素，
/// SVG 中是文档像素。
double strokeWidthPx(double widthRatio, double shortestSide) =>
    (widthRatio * shortestSide).clamp(1.0, double.infinity);

/// 一条完整笔画：由若干归一化采样点组成。
///
/// 采样点坐标使用归一化坐标（0.0 ~ 1.0），渲染时再乘以画布尺寸还原，
/// 从而使 Rust 侧几何处理与屏幕分辨率解耦。
class Stroke {
  Stroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.widthRatio,
    required this.points,
  });

  /// 会话内自增 id，用于区分笔画。
  final int id;

  /// 产生该笔画的工具。
  ///
  /// 橡皮同样是「一笔」，只是合成方式不同（清空而非叠加）。把它建模为笔画而不是
  /// 直接改写既有笔画，换来的好处是撤销天然成立、文档格式也不需要存位图。
  final ToolKind tool;

  /// ARGB 颜色值（0xAARRGGBB）；橡皮忽略该值。
  final int color;

  /// 笔画粗细，**归一化比例**：相对画布短边的占比（例如 0.01 表示 1%）。
  ///
  /// 与坐标同为无量纲量，因此更换分辨率、缩放画布或导出图片时笔触比例都不会失真。
  /// 渲染时换算为像素：`widthRatio * size.shortestSide`。
  final double widthRatio;

  /// 归一化坐标采样点（0.0 ~ 1.0）。
  final List<rust.StrokePoint> points;

  /// 是否为擦除笔画。
  bool get isEraser => tool == ToolKind.eraser;

  /// 换算为当前画布下的像素笔宽，并保证至少 1 像素可见。
  double widthInPixels(double shortestSide) =>
      strokeWidthPx(widthRatio, shortestSide);

  /// 转换为 FFI 层结构，供持久化编码使用。
  rust.Stroke toRust() => rust.Stroke(
        id: id,
        tool: tool,
        color: color,
        width: widthRatio,
        points: points,
      );

  /// 从 FFI 层结构还原。
  factory Stroke.fromRust(rust.Stroke source) => Stroke(
        id: source.id,
        tool: source.tool,
        color: source.color,
        widthRatio: source.width,
        points: source.points,
      );
}
