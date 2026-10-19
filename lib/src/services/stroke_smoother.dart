import '../rust/api.dart' as rust;

/// 笔画增量平滑器。
///
/// 语义与 Rust 侧的 `smooth_stroke`（中心移动平均）保持一致：点 `i` 的平滑窗口是
/// `[i-half, i+half]`，因此只要再收到 `half` 个采样点，点 `i` 的取值就永久固定。
/// 由此得到两个关键性质：
///
/// 1. **所见即所存**。抬手时 `finish()` 返回的点列，与绘制过程中屏幕上的点列完全相同，
///    笔画形态不会在抬手瞬间发生变化。
/// 2. **单帧成本与笔画长度无关**。每帧只重算尾部 `half` 个未定稿的点，已定稿部分
///    只追加、不改写。
///
/// 之所以放在 Dart 而非跨 FFI：指针事件是 60~120Hz 的热路径，每次事件一次跨语言
/// 异步往返就足以引入可见延迟与抖动。批量几何处理（导出、历史文档重算）仍由 Rust 承担。
class StrokeSmoother {
  StrokeSmoother({
    required this.shortestSide,
    this.window = 5,
    this.minDistancePx = 0.75,
  }) : assert(window >= 3 && window.isOdd, '平滑窗口需为不小于 3 的奇数');

  /// 画布短边（逻辑像素），用于把归一化距离换算成屏幕距离。
  final double shortestSide;

  /// 平滑窗口大小，奇数。
  final int window;

  /// 抽稀阈值（逻辑像素）：与上一保留点距离小于该值的点会被丢弃。
  ///
  /// 亚像素级别的抽稀不会改变可见形状，但能显著压缩高速运笔产生的冗余采样。
  final double minDistancePx;

  final List<rust.StrokePoint> _raw = [];
  final List<rust.StrokePoint> _points = [];

  /// 下一条待定稿的原始点下标。
  int _nextRawToFinalize = 0;

  /// `_points` 中已定稿的前缀长度；其后为临时尾部。
  int _finalizedCount = 0;

  /// 点数不足 3 时原样透传（平滑会把两点笔画压成近乎一个点，必须避免）。
  bool _passthrough = true;

  int get _half => window ~/ 2;

  double get _scale =>
      shortestSide.isFinite && shortestSide > 0 ? shortestSide : 1.0;

  /// 当前应渲染的点列（已定稿 + 临时尾部）。
  List<rust.StrokePoint> get points => _points;

  bool get isEmpty => _points.isEmpty;

  /// 已接收的原始采样点数量。
  int get rawPointCount => _raw.length;

  /// 送入一个原始采样点。
  void add(rust.StrokePoint point) {
    _raw.add(point);
    _refresh();
  }

  /// 笔画结束：以最终边界重算尾部，返回可直接提交与持久化的点列。
  List<rust.StrokePoint> finish() {
    _refresh();
    return List<rust.StrokePoint>.of(_points);
  }

  void _refresh() {
    final n = _raw.length;
    if (n < 3) {
      _points
        ..clear()
        ..addAll(_raw);
      _finalizedCount = _points.length;
      _nextRawToFinalize = n;
      return;
    }

    if (_passthrough) {
      // 首次达到 3 点：清掉透传内容，从头按平滑规则重算。
      _passthrough = false;
      _nextRawToFinalize = 0;
      _finalizedCount = 0;
      _points.clear();
    }

    // 1) 丢弃上一帧的临时尾部，只保留已定稿部分。
    _points.length = _finalizedCount;

    // 2) 追加本轮可定稿的点：窗口右端 i+half 已存在，取值不再变化。
    final lastFinal = n - 1 - _half;
    for (var i = _nextRawToFinalize; i <= lastFinal; i++) {
      final smoothed = _smoothAt(i);
      if (_keep(smoothed)) {
        _points.add(smoothed);
        _finalizedCount++;
      }
      _nextRawToFinalize = i + 1;
    }

    // 3) 尾部：窗口尚不完整，每次重算覆盖。最后一个点始终保留，
    //    以保证笔迹终点跟随笔尖，不被抽稀吞掉。
    for (var i = _nextRawToFinalize; i < n; i++) {
      final smoothed = _smoothAt(i);
      if (i == n - 1 || _keep(smoothed)) {
        _points.add(smoothed);
      }
    }
  }

  /// 对原始点 `i` 做中心移动平均。
  ///
  /// 累加顺序与 Rust 实现一致（升序、f64 求和后除以计数），因此同一输入的平滑结果
  /// 与 `rust.smoothStroke` 等价——这是「绘制中/提交后形状相同」的算术基础。
  rust.StrokePoint _smoothAt(int i) {
    final start = i - _half < 0 ? 0 : i - _half;
    final end = i + _half + 1 > _raw.length ? _raw.length : i + _half + 1;
    var sx = 0.0;
    var sy = 0.0;
    var sp = 0.0;
    for (var k = start; k < end; k++) {
      sx += _raw[k].x;
      sy += _raw[k].y;
      sp += _raw[k].pressure;
    }
    final count = (end - start).toDouble();
    return rust.StrokePoint(
      x: sx / count,
      y: sy / count,
      pressure: sp / count,
      timestampMs: _raw[i].timestampMs,
    );
  }

  bool _keep(rust.StrokePoint point) {
    if (_points.isEmpty || minDistancePx <= 0) return true;
    final last = _points.last;
    final dx = (point.x - last.x) * _scale;
    final dy = (point.y - last.y) * _scale;
    return dx * dx + dy * dy >= minDistancePx * minDistancePx;
  }
}
