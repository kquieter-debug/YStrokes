import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

/// 像素矩形（整数、闭开区间 `[left, left+width) × [top, top+height)`）。
///
/// 用整型而不是 `Rect`：选区蒙版是按像素工作的，半像素边界在这里毫无意义，
/// 而且每次遍历都要 `floor`/`round` 一遍纯属浪费。
class PixelBounds {
  const PixelBounds(this.left, this.top, this.width, this.height);

  final int left;
  final int top;
  final int width;
  final int height;

  int get right => left + width;
  int get bottom => top + height;

  @override
  bool operator ==(Object other) =>
      other is PixelBounds &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'PixelBounds($left, $top, ${width}x$height)';
}

/// 像素级选区：一张按像素存的覆盖率表。
///
/// 「选区内」不是一个布尔判断，而是**覆盖率**（0–255）。边界像素取中间值，
/// 这样移动 / 裁切像素时边缘是渐层过渡而不是硬齿——和画笔的抗锯齿是同一个道理。
///
/// ## 为什么用一整张表而不是多边形
///
/// 多边形只描述边界，每次取样都要做一次点内判断（O(边数)）；而选区的实际用途
/// 是「逐像素遍历一遍」，那样就成了 O(面积 × 边数)。一次栅格化成表之后，
/// 所有后续操作都是 O(面积 / 8) 的查表。代价是一张 `Uint8List(width × height)`，
/// 1080×1920 约 2 MB，且只在选区存在期间持有。
///
/// ## 抗锯齿的做法
///
/// 垂直方向 4 倍子扫描线、水平方向解析求交：交点精确到亚像素，段内按
/// 重叠长度累加。这样水平边缘是解析精确的，垂直边缘有 4 级灰阶，
/// 成本是 O(高度 × 4 × 边数 + 跨度面积)，而不是 16 倍面积的超采样。
class RasterMask {
  RasterMask._(this.width, this.height, this._coverage);

  /// 全空选区（每个像素覆盖率都是 0）。
  factory RasterMask.empty(int width, int height) =>
      RasterMask._(width, height, Uint8List(width * height));

  /// 整块全选。
  factory RasterMask.full(int width, int height) =>
      RasterMask._(width, height, Uint8List(width * height)..fillRange(0, width * height, 255));

  /// 由**多边形**栅格化而来。折线按 even-odd 规则闭合，无需首尾重合。
  ///
  /// [polygon] 的坐标是图层像素坐标（原点在图层左上角），可以超出画布，
  /// 超出部分会被裁掉——套索画到画布外是正常操作，不该报错。
  factory RasterMask.fromPolygon(
    int width,
    int height,
    List<Offset> polygon,
  ) {
    final mask = RasterMask.empty(width, height);
    if (polygon.length < 3 || width <= 0 || height <= 0) return mask;

    // 累加器用定点：一条子扫描线的满覆盖记 [_spanUnit]（= 255 的定点），
    // 4 条子扫描线累加后除以 [_subSamples] 正好回到 0–255。
    const unit = _spanUnit;
    final acc = Int32List(width * height);
    final xs = <double>[];

    for (var row = 0; row < height; row++) {
      final rowBase = row * width;
      for (var sub = 0; sub < _subSamples; sub++) {
        final y = row + (sub + 0.5) / _subSamples;
        _collectCrossings(polygon, y, xs);
        if (xs.length < 2) continue;
        xs.sort();

        for (var i = 0; i + 1 < xs.length; i += 2) {
          _accumulateSpan(acc, rowBase, width, xs[i], xs[i + 1], unit);
        }
      }
    }

    final coverage = mask._coverage;
    for (var i = 0; i < coverage.length; i++) {
      final value = acc[i] ~/ _subSamples;
      if (value > 0) coverage[i] = value > 255 ? 255 : value;
    }
    return mask;
  }

  /// 垂直子扫描线条数。4 已经足够：再多一级灰阶肉眼看不出，成本却翻倍。
  static const int _subSamples = 4;

  /// 一条子扫描线满覆盖时累加器里的值。
  ///
  /// 取 256 而不是 255：与 [_subSamples] 相除后正好是满覆盖（256），
  /// 最后统一 clamp 到 255。用 255 会让「四条子扫描线都满覆盖」得到 255.0 的
  /// 取整误差，边界像素莫名其妙少一个灰阶。
  static const int _spanUnit = 256;

  final int width;
  final int height;
  final Uint8List _coverage;

  /// 该像素的覆盖率，0–255。
  int coverageAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return _coverage[y * width + x];
  }

  /// 该像素是否被选区碰到（含部分覆盖）。
  bool contains(int x, int y) => coverageAt(x, y) > 0;

  /// 是否有任意一个像素被选中。
  bool get isEmpty {
    for (final value in _coverage) {
      if (value != 0) return false;
    }
    return true;
  }

  /// 至少有一个像素有覆盖的筛选区域；全空时返回 null。
  ///
  /// 逐行扫描并记录首末非空行 / 列，遇到全空可以直接跳过整行——空白选区
  /// 往往只覆盖画布一角，逐像素遍历整张表没有必要。
  PixelBounds? get bounds {
    var top = -1;
    var bottom = -1;
    var left = width;
    var right = -1;

    for (var y = 0; y < height; y++) {
      final rowBase = y * width;
      var rowLeft = -1;
      var rowRight = -1;
      for (var x = 0; x < width; x++) {
        if (_coverage[rowBase + x] == 0) continue;
        if (rowLeft < 0) rowLeft = x;
        rowRight = x;
      }
      if (rowLeft < 0) continue;
      if (top < 0) top = y;
      bottom = y;
      left = math.min(left, rowLeft);
      right = math.max(right, rowRight);
    }

    if (top < 0) return null;
    return PixelBounds(left, top, right - left + 1, bottom - top + 1);
  }

  /// 覆盖率总量（按像素计），用于「选中了多少」的提示。
  double get selectedPixels {
    var sum = 0;
    for (final value in _coverage) {
      sum += value;
    }
    return sum / 255;
  }

  /// 平移后的副本，用于「选区跟着内容一起移动」。
  ///
  /// 只支持平移：旋转与缩放后的选区边界无法用整数网格精确表达，那两种自由度
  /// 需要重新栅格化多边形。当前交互只暴露平移（旋转/缩放的入口留给后续）。
  RasterMask translated(int dx, int dy) {
    if (dx == 0 && dy == 0) return this;
    final out = Uint8List(_coverage.length);
    for (var y = 0; y < height; y++) {
      final ty = y + dy;
      if (ty < 0 || ty >= height) continue;
      final srcRow = y * width;
      final dstRow = ty * width;
      for (var x = 0; x < width; x++) {
        final value = _coverage[srcRow + x];
        if (value == 0) continue;
        final tx = x + dx;
        if (tx < 0 || tx >= width) continue;
        out[dstRow + tx] = value;
      }
    }
    return RasterMask._(width, height, out);
  }

  /// 反向选择。全空选区取反后是全选——这与矢量侧「补集」的语义一致。
  RasterMask inverted() {
    final out = Uint8List(_coverage.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = 255 - _coverage[i];
    }
    return RasterMask._(width, height, out);
  }

  /// 并集（加选）。
  RasterMask union(RasterMask other) {
    _requireSameShape(other);
    return _merge(other, (a, b) => a > b ? a : b);
  }

  /// 差集（减选）。
  RasterMask subtract(RasterMask other) {
    _requireSameShape(other);
    return _merge(other, (a, b) {
      final left = a - b;
      return left < 0 ? 0 : left;
    });
  }

  /// 交集。
  ///
  /// 覆盖率按乘积合并：两个半覆盖的像素相交，只该有四分之一的权重。
  /// 取最小值会让「两个都半透明的边」叠加成全不透明，边缘会变硬。
  RasterMask intersect(RasterMask other) {
    _requireSameShape(other);
    return _merge(other, (a, b) => (a * b) ~/ 255);
  }

  RasterMask _merge(RasterMask other, int Function(int a, int b) combine) {
    final out = Uint8List(_coverage.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = combine(_coverage[i], other._coverage[i]);
    }
    return RasterMask._(width, height, out);
  }

  void _requireSameShape(RasterMask other) {
    assert(
      other.width == width && other.height == height,
      '选区蒙版尺寸不一致：$width×$height vs ${other.width}×${other.height}',
    );
  }

  /// 求扫描线 y 与多边形各边的全部交点横坐标（结果写入 [out]）。
  ///
  /// 半开区间判断 `(a.dy <= y) != (b.dy <= y)` 让顶点只被计入一次，
  /// 水平边则完全不产生交点——这正是 even-odd 规则需要的。
  static void _collectCrossings(List<Offset> polygon, double y, List<double> out) {
    out.clear();
    final n = polygon.length;
    for (var i = 0; i < n; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % n];
      if ((a.dy <= y) == (b.dy <= y)) continue;
      final t = (y - a.dy) / (b.dy - a.dy);
      out.add(a.dx + t * (b.dx - a.dx));
    }
  }

  /// 把 `[x0, x1)` 这段覆盖按重叠长度累加进一行。
  ///
  /// 两端像素按实际重叠比例计入，中间整像素直接加满——这样水平方向的
  /// 抗锯齿是解析精确的，不依赖超采样密度。
  static void _accumulateSpan(
    Int32List acc,
    int rowBase,
    int width,
    double x0,
    double x1,
    int unit,
  ) {
    final lo = math.max(0.0, x0);
    final hi = math.min(width.toDouble(), x1);
    if (hi <= lo) return;

    final first = lo.floor();
    final last = math.min(hi.ceil() - 1, width - 1);

    if (first == last) {
      acc[rowBase + first] += ((hi - lo) * unit).round();
      return;
    }

    acc[rowBase + first] += ((first + 1 - lo) * unit).round();
    for (var x = first + 1; x < last; x++) {
      acc[rowBase + x] += unit;
    }
    acc[rowBase + last] += ((hi - last) * unit).round();
  }
}
