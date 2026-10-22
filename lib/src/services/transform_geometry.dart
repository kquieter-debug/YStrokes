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
    this.flipX = false,
    this.flipY = false,
  });

  /// 缩放倍率（1 表示不变）。
  final double scale;

  /// 旋转弧度（顺时针为正，与 `Canvas` 一致）。
  final double rotation;

  /// 平移量（归一化坐标）。
  final Offset offset;

  /// 是否沿垂直中轴镜像（左右翻转）。
  ///
  /// 翻转不是「缩放 -1」：负缩放会让旋转方向与手柄语义一起反掉，
  /// 而独立的翻转位只影响一个轴，组合起来仍然可读。
  final bool flipX;

  /// 是否沿水平中轴镜像（上下翻转）。
  final bool flipY;

  static const StrokeTransform identity = StrokeTransform();

  bool get isIdentity =>
      scale == 1 &&
      rotation == 0 &&
      offset.dx == 0 &&
      offset.dy == 0 &&
      !flipX &&
      !flipY;

  StrokeTransform copyWith({
    double? scale,
    double? rotation,
    Offset? offset,
    bool? flipX,
    bool? flipY,
  }) =>
      StrokeTransform(
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        offset: offset ?? this.offset,
        flipX: flipX ?? this.flipX,
        flipY: flipY ?? this.flipY,
      );

  /// 把一点绕 [pivot] 缩放旋转后平移。
  Offset apply(Offset point, Offset pivot) {
    var dx = (point.dx - pivot.dx) * scale;
    var dy = (point.dy - pivot.dy) * scale;
    // 镜像在缩放之后、旋转之前：先决定内容朝哪边，再整体旋转，
    // 这样「翻转 + 旋转」的顺序与用户在画布上看到的一致。
    if (flipX) dx = -dx;
    if (flipY) dy = -dy;
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
      other.offset == offset &&
      other.flipX == flipX &&
      other.flipY == flipY;

  @override
  int get hashCode => Object.hash(scale, rotation, offset, flipX, flipY);
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

/// 把一条笔画的点列按多边形边界切开，返回「落在区域内」的若干段点列。
///
/// 规则：
/// - 只在**穿出/穿入边界**处切；切点用线段与多边形边的交点插值（压力与时间戳同样插值）。
/// - 完全在区域内的笔画返回单段（原样），调用方据此判断「没有发生切分」。
/// - 完全在区域外的笔画返回空列表。
///
/// 不做路径布尔运算：笔画是折线，按段裁剪足以表达「选区里的那一段」，
/// 而布尔运算会引入自相交、退化边等一整套问题，收益与成本不成比例。
List<List<rust.StrokePoint>> splitPolylineAtPolygon(
  List<rust.StrokePoint> points,
  List<Offset> polygon,
) {
  if (points.isEmpty || polygon.length < 3) {
    return <List<rust.StrokePoint>>[List<rust.StrokePoint>.of(points)];
  }

  final fragments = <List<rust.StrokePoint>>[];
  var current = <rust.StrokePoint>[];
  var inside = polygonContains(Offset(points.first.x, points.first.y), polygon);
  if (inside) current.add(points.first);

  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final pa = Offset(a.x, a.y);
    final pb = Offset(b.x, b.y);

    // 关键点：一条线段可能在同一段内**穿入又穿出**（快速划线、套索很窄时都会发生）。
    // 因此不能只看两端点的内外状态，而要枚举这条线段上的全部交点，逐个翻转内外。
    final crossings = _crossingParams(pa, pb, polygon);

    for (final t in crossings) {
      if (t <= 1e-9 || t >= 1 - 1e-9) continue;
      final cut = _lerpPointAt(a, b, t);
      if (inside) {
        // 穿出：把切点收进当前段并封口。
        current.add(cut);
        fragments.add(current);
        current = <rust.StrokePoint>[];
      } else {
        // 穿入：从切点开新段。
        current = <rust.StrokePoint>[cut];
      }
      inside = !inside;
    }

    // 端点兜底。交点只覆盖「严格落在段内部」的穿越：当采样点恰好压在选区边界上
    // （套索的边正好过某个顶点），交点参数会退化成 0 或 1 而被丢弃，内外状态就漏翻了，
    // 于是「压在边界上的顶点之后那截尾巴」会被整段留在区内。
    // 这里用终点自身的包含关系校正；终点贴在边界上时内外本身就模糊，保持原状态不动。
    final state = _pointState(pb, polygon);
    if (state != null && state != inside) {
      if (inside) {
        // 由内到外：a 就是切点，current 已经以它结尾，直接封口（不把界外的 b 收进来）。
        if (current.isNotEmpty) fragments.add(current);
        current = <rust.StrokePoint>[];
      } else {
        // 由外到内：b 是第一个落在区内的采样点，从这里开新段。
        current = <rust.StrokePoint>[b];
      }
      inside = state;
      continue;
    }

    // 线段内的翻转处理完之后，尾点归属由当前内外状态决定。
    if (inside) current.add(b);
  }

  if (current.isNotEmpty) fragments.add(current);
  return fragments;
}

/// 点相对多边形的位置：`true` 在内、`false` 在外、`null` 恰好压在边界上。
///
/// 边界上的点没有「内外」可言，调用方需要据此跳过判断，而不是硬判成其中一边。
bool? _pointState(Offset point, List<Offset> polygon) {
  for (var i = 0; i < polygon.length; i++) {
    final j = (i + 1) % polygon.length;
    if (_distanceToSegment(point, polygon[i], polygon[j]) <= 1e-9) return null;
  }
  return polygonContains(point, polygon);
}

/// 点到线段的距离。
double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared <= 1e-24) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared)
      .clamp(0.0, 1.0);
  return (p - Offset(a.dx + ab.dx * t, a.dy + ab.dy * t)).distance;
}

/// 线段 a→b 与多边形各边的交点参数，按从小到大排序并去重。
List<double> _crossingParams(Offset a, Offset b, List<Offset> polygon) {
  final params = <double>[];
  for (var i = 0; i < polygon.length; i++) {
    final c = polygon[i];
    final d = polygon[(i + 1) % polygon.length];
    final t = _segmentParam(a, b, c, d);
    if (t == null || t <= 1e-9 || t >= 1 - 1e-9) continue;
    // 交点落在多边形顶点上时，两条相邻边会各报一次，去重避免来回翻转两次。
    if (params.any((existing) => (existing - t).abs() < 1e-9)) continue;
    params.add(t);
  }
  params.sort();
  return params;
}

/// 线段 a→b 与 c→d 的交点在 a→b 上的参数（0~1）；不相交返回 null。
double? _segmentParam(Offset a, Offset b, Offset c, Offset d) {
  final r = b - a;
  final s = d - c;
  final denominator = r.dx * s.dy - r.dy * s.dx;
  if (denominator.abs() < 1e-12) return null; // 平行（含共线）

  final t = ((c.dx - a.dx) * s.dy - (c.dy - a.dy) * s.dx) / denominator;
  final u = ((c.dx - a.dx) * r.dy - (c.dy - a.dy) * r.dx) / denominator;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return t;
}

/// 按参数 t 在两点之间插值（坐标、压力、时间戳一起插值）。
rust.StrokePoint _lerpPointAt(rust.StrokePoint a, rust.StrokePoint b, double t) {
  final ts = a.timestampMs + ((b.timestampMs - a.timestampMs) * t).round();
  return rust.StrokePoint(
    x: a.x + (b.x - a.x) * t,
    y: a.y + (b.y - a.y) * t,
    pressure: a.pressure + (b.pressure - a.pressure) * t,
    timestampMs: ts < 0 ? 0 : ts,
  );
}
