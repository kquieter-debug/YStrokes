import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../models/stroke.dart';
import '../rust/api/stroke.dart' as rust;

/// 选区的变换参数：**等比缩放 + 旋转 + 平移**，全部在归一化文档空间表达。
///
/// 只做等比缩放是刻意的：矢量笔画没有「非等比拉伸线段」这种语义，横向拉伸
/// 一笔就是在改笔宽，而笔宽只有一个标量。等比缩放既符合矢量模型，也让
/// 「拖角」这一个手势足够表达缩放，不必区分 X/Y 手柄。
class StrokeTransform {
  const StrokeTransform({
    this.scale = 1,
    this.rotation = 0,
    this.offset = Offset.zero,
  });

  /// 缩放倍率（1 表示不变）。
  final double scale;

  /// 旋转弧度（顺时针为正，与 `Canvas` 一致）。
  final double rotation;

  /// 平移量（归一化坐标）。
  final Offset offset;

  static const StrokeTransform identity = StrokeTransform();

  bool get isIdentity =>
      scale == 1 && rotation == 0 && offset.dx == 0 && offset.dy == 0;

  StrokeTransform copyWith({double? scale, double? rotation, Offset? offset}) =>
      StrokeTransform(
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        offset: offset ?? this.offset,
      );

  /// 把一点绕 [pivot] 缩放旋转后平移。
  Offset apply(Offset point, Offset pivot) {
    final dx = (point.dx - pivot.dx) * scale;
    final dy = (point.dy - pivot.dy) * scale;
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);
    return Offset(
      pivot.dx + dx * cos - dy * sin + offset.dx,
      pivot.dy + dx * sin + dy * cos + offset.dy,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeTransform &&
      other.scale == scale &&
      other.rotation == rotation &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, rotation, offset);
}

/// 笔宽在变换后的安全范围。
///
/// 刻意比 [ToolSettings.minWidthRatio] 宽松：这里约束的是「几何上还能不能看见」，
/// 而不是「用户能不能在滑杆上选到」。用滑杆的范围夹取会把一次 10 倍缩放
/// 悄悄压成 4 倍，外观与预期不符。
const double _minWidthRatio = 0.0005;
const double _maxWidthRatio = 0.25;

/// 对一组笔画应用变换。
///
/// 笔画是不可变对象，因此这里返回新实例——调用方（变换预览）每帧都用
/// 「原始快照 + 当前变换」重新生成，而不是在原对象上累乘，避免误差累积。
List<Stroke> transformStrokes(
  Iterable<Stroke> strokes,
  StrokeTransform transform,
  Offset pivot,
) {
  if (transform.isIdentity) return List<Stroke>.of(strokes);

  return <Stroke>[
    for (final stroke in strokes)
      _transformStroke(stroke, transform, pivot),
  ];
}

/// 只变换被选中的笔画，其余原样保留（保持引用，避免无谓复制）。
List<Stroke> transformSelection(
  Iterable<Stroke> strokes,
  Set<int> selectedIds,
  StrokeTransform transform,
  Offset pivot,
) {
  if (transform.isIdentity) return List<Stroke>.of(strokes);
  return <Stroke>[
    for (final stroke in strokes)
      selectedIds.contains(stroke.id)
          ? _transformStroke(stroke, transform, pivot)
          : stroke,
  ];
}

Stroke _transformStroke(Stroke stroke, StrokeTransform transform, Offset pivot) {
  final points = <rust.StrokePoint>[
    for (final point in stroke.points)
      _transformPoint(point, transform, pivot),
  ];
  return Stroke(
    id: stroke.id,
    tool: stroke.tool,
    color: stroke.color,
    widthRatio: (stroke.widthRatio * transform.scale)
        .clamp(_minWidthRatio, _maxWidthRatio),
    points: points,
    usesPressure: stroke.usesPressure,
  );
}

rust.StrokePoint _transformPoint(
  rust.StrokePoint point,
  StrokeTransform transform,
  Offset pivot,
) {
  final moved = transform.apply(Offset(point.x, point.y), pivot);
  return rust.StrokePoint(
    x: moved.dx,
    y: moved.dy,
    pressure: point.pressure,
    // 时间戳只服务于「采集时的速度/平滑」，变换不改时间。
    timestampMs: point.timestampMs,
  );
}

/// 一组笔画的归一化包围盒；没有点或全部为空时返回 [Rect.zero]。
Rect boundsOfStrokes(Iterable<Stroke> strokes) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  var any = false;

  for (final stroke in strokes) {
    // 单点笔画（点一下就抬手）也要有尺寸，否则包围盒退化成零面积、手柄点不中。
    final halfWidth = stroke.widthRatio / 2;
    for (final point in stroke.points) {
      any = true;
      if (point.x - halfWidth < minX) minX = point.x - halfWidth;
      if (point.y - halfWidth < minY) minY = point.y - halfWidth;
      if (point.x + halfWidth > maxX) maxX = point.x + halfWidth;
      if (point.y + halfWidth > maxY) maxY = point.y + halfWidth;
    }
  }

  if (!any) return Rect.zero;
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// 射线法判断点是否在多边形内。
///
/// 归一化空间里多边形最多几百个点，O(n) 完全够用；这里不做加速结构，
/// 因为「套索命中」只在抬手时算一次，不在绘制热路径上。
bool polygonContains(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy)) {
      final t = (point.dy - a.dy) / (b.dy - a.dy);
      if (point.dx < a.dx + t * (b.dx - a.dx)) inside = !inside;
    }
  }
  return inside;
}

/// 笔画是否与多边形相交（含「整条在里面」与「穿过一段」）。
///
/// 只判断「点是否在内部」会漏掉高速划过的长笔画：套索横切一笔时，它的采样点
/// 可能全在套索两侧，但笔画本身确实被圈住了。因此再补一次线段相交。
bool strokeTouchesPolygon(Stroke stroke, List<Offset> polygon) {
  if (polygon.length < 3) return false;

  final points = <Offset>[
    for (final point in stroke.points) Offset(point.x, point.y),
  ];
  if (points.isEmpty) return false;

  for (final point in points) {
    if (polygonContains(point, polygon)) return true;
  }
  if (points.length == 1) return false;

  for (var i = 1; i < points.length; i++) {
    for (var j = 0; j < polygon.length; j++) {
      final k = (j + 1) % polygon.length;
      if (_segmentsIntersect(points[i - 1], points[i], polygon[j], polygon[k])) {
        return true;
      }
    }
  }
  return false;
}

/// 命中多边形的笔画 id 集合。
Set<int> strokesInPolygon(Iterable<Stroke> strokes, List<Offset> polygon) {
  return <int>{
    for (final stroke in strokes)
      if (strokeTouchesPolygon(stroke, polygon)) stroke.id,
  };
}

/// 两条线段是否相交（含端点接触），用方向叉积判定。
bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  final d1 = _cross(p3, p4, p1);
  final d2 = _cross(p3, p4, p2);
  final d3 = _cross(p1, p2, p3);
  final d4 = _cross(p1, p2, p4);

  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  // 共线且落在对方范围内的情况（套索边恰好擦过笔画端点）。
  return (d1 == 0 && _onSegment(p3, p4, p1)) ||
      (d2 == 0 && _onSegment(p3, p4, p2)) ||
      (d3 == 0 && _onSegment(p1, p2, p3)) ||
      (d4 == 0 && _onSegment(p1, p2, p4));
}

double _cross(Offset a, Offset b, Offset c) =>
    (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

bool _onSegment(Offset a, Offset b, Offset p) =>
    p.dx >= math.min(a.dx, b.dx) - 1e-9 &&
    p.dx <= math.max(a.dx, b.dx) + 1e-9 &&
    p.dy >= math.min(a.dy, b.dy) - 1e-9 &&
    p.dy <= math.max(a.dy, b.dy) + 1e-9;
