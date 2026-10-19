import 'dart:async';
import 'dart:math' as math;

import '../models/stroke.dart';
import '../rust/api.dart' as rust;

/// 画板引擎：管理笔画列表与撤销/重做栈，并把几何处理委托给 Rust。
///
/// 职责划分：
/// - Rust 负责计算密集的平滑/简化（`smooth_stroke` / `simplify_stroke`）。
/// - Dart 负责会话状态（笔画顺序、撤销/重做）与最终渲染。
/// - 持久化不在本类内：由 `DocumentStore` 负责 I/O，画板界面负责编排。
class DrawingEngine {
  /// 平滑窗口大小（奇数更对称）。
  static const int smoothWindow = 5;

  /// Douglas-Peucker 容差（归一化坐标量纲）。
  static const double simplifyTolerance = 0.002;

  final List<Stroke> _strokes = [];
  final List<_Edit> _undoStack = [];
  final List<_Edit> _redoStack = [];

  int _nextId = 0;

  /// 状态版本号：每次内容变化自增，供渲染层判断是否需要重建缓存。
  int _revision = 0;

  /// 串行化闸门：保证同时抬笔的多笔按抬笔顺序入栈。
  ///
  /// 平滑/简化是异步 FFI 调用，若并发处理，短笔画可能先返回并插队，
  /// 导致层叠顺序与用户实际绘制顺序不一致。此处用 Future 链强制 FIFO。
  Future<void> _tail = Future<void>.value();

  /// 当前可见笔画（只读视图；调用方无需关心内部结构）。
  List<Stroke> get strokes => List.unmodifiable(_strokes);

  /// 状态版本号，内容变化时递增。
  int get revision => _revision;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get isEmpty => _strokes.isEmpty;
  int get strokeCount => _strokes.length;

  /// 载入已持久化的笔画，重置撤销/重做历史。
  ///
  /// 载入后不产生撤销记录：历史属于「本次会话」，跨会话撤销会把用户带回
  /// 无法理解的状态。
  void load(List<Stroke> strokes) {
    _strokes
      ..clear()
      ..addAll(strokes);
    _undoStack.clear();
    _redoStack.clear();
    _nextId = strokes.fold(0, (maxId, s) => math.max(maxId, s.id + 1));
    _revision++;
  }

  /// 处理并添加一笔：先平滑去抖、再简化采样点，然后入栈。
  ///
  /// [raw] 为归一化坐标的原始采样点（按时间顺序）。
  /// [widthRatio] 为归一化笔宽（相对画布短边）。
  Future<Stroke> addStroke(
    List<rust.StrokePoint> raw, {
    required int color,
    required double widthRatio,
  }) {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return _process(previous, gate, raw, color: color, widthRatio: widthRatio);
  }

  Future<Stroke> _process(
    Future<void> previous,
    Completer<void> gate,
    List<rust.StrokePoint> raw, {
    required int color,
    required double widthRatio,
  }) async {
    try {
      await previous;

      var points = raw;
      if (points.length >= 3) {
        points = await rust.smoothStroke(points: points, window: smoothWindow);
        points = await rust.simplifyStroke(
          points: points,
          tolerance: simplifyTolerance,
        );
      }

      final stroke = Stroke(
        id: _nextId++,
        color: color,
        widthRatio: widthRatio,
        points: points,
      );
      _strokes.add(stroke);
      _undoStack.add(_AddEdit(stroke));
      _redoStack.clear();
      _revision++;
      return stroke;
    } finally {
      // 无论成功与否都必须放行后续笔画，否则整条队列会永久阻塞。
      gate.complete();
    }
  }

  /// 撤销上一步；无历史时返回 false。
  bool undo() {
    if (_undoStack.isEmpty) return false;
    final edit = _undoStack.removeLast();
    edit.undo(_strokes);
    _redoStack.add(edit);
    _revision++;
    return true;
  }

  /// 重做最近撤销的一步；无历史时返回 false。
  bool redo() {
    if (_redoStack.isEmpty) return false;
    final edit = _redoStack.removeLast();
    edit.redo(_strokes);
    _undoStack.add(edit);
    _revision++;
    return true;
  }

  /// 清空画布。与旧实现不同，此操作可撤销——误触清空不应造成不可逆损失。
  bool clear() {
    if (_strokes.isEmpty) return false;
    _undoStack.add(_ClearEdit(List<Stroke>.of(_strokes)));
    _redoStack.clear();
    _strokes.clear();
    _revision++;
    return true;
  }
}

/// 可撤销的编辑操作。
abstract class _Edit {
  void undo(List<Stroke> strokes);
  void redo(List<Stroke> strokes);
}

/// 新增一笔。
class _AddEdit implements _Edit {
  _AddEdit(this.stroke);

  final Stroke stroke;

  @override
  void undo(List<Stroke> strokes) {
    // 正常情况下新增的笔画总在末尾；若因外部载入导致位置变化，退化为按 id 查找。
    if (strokes.isNotEmpty && strokes.last.id == stroke.id) {
      strokes.removeLast();
    } else {
      strokes.removeWhere((s) => s.id == stroke.id);
    }
  }

  @override
  void redo(List<Stroke> strokes) => strokes.add(stroke);
}

/// 清空画布，撤销时整批恢复。
class _ClearEdit implements _Edit {
  _ClearEdit(this.removed);

  final List<Stroke> removed;

  @override
  void undo(List<Stroke> strokes) => strokes.addAll(removed);

  @override
  void redo(List<Stroke> strokes) => strokes.clear();
}
