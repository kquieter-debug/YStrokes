import '../models/stroke.dart';
import '../rust/api.dart' as rust;

/// 画板引擎：管理笔画列表与撤销/重做栈，并把几何处理委托给 Rust。
///
/// 职责划分：
/// - Rust 负责计算密集的平滑/简化（`smooth_stroke` / `simplify_stroke`）。
/// - Dart 负责会话状态（笔画顺序、撤销/重做）与最终渲染。
class DrawingEngine {
  /// 平滑窗口大小（奇数更对称）。
  static const int smoothWindow = 5;

  /// Douglas-Peucker 容差（归一化坐标量纲）。
  static const double simplifyTolerance = 0.002;

  final List<Stroke> _strokes = [];
  final List<Stroke> _redoStack = [];
  int _nextId = 0;

  /// 当前可见笔画（只读）。
  List<Stroke> get strokes => List.unmodifiable(_strokes);

  bool get canUndo => _strokes.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  int get strokeCount => _strokes.length;

  /// 处理并添加一笔：先平滑去抖、再简化采样点，然后入栈。
  ///
  /// [raw] 为归一化坐标的原始采样点（按时间顺序）。
  Future<Stroke> addStroke(
    List<rust.StrokePoint> raw, {
    required int color,
    required double width,
  }) async {
    var points = raw;
    if (points.length >= 3) {
      points = await rust.smoothStroke(points: points, window: smoothWindow);
      points =
          await rust.simplifyStroke(points: points, tolerance: simplifyTolerance);
    }
    final stroke = Stroke(
      id: _nextId++,
      color: color,
      width: width,
      points: points,
    );
    _strokes.add(stroke);
    _redoStack.clear();
    return stroke;
  }

  /// 撤销最后一笔；成功返回 true。
  bool undo() {
    if (_strokes.isEmpty) return false;
    _redoStack.add(_strokes.removeLast());
    return true;
  }

  /// 重做最近撤销的一笔；成功返回 true。
  bool redo() {
    if (_redoStack.isEmpty) return false;
    _strokes.add(_redoStack.removeLast());
    return true;
  }

  /// 清空画布（同时清空撤销/重做栈）。
  void clear() {
    _strokes.clear();
    _redoStack.clear();
  }
}
