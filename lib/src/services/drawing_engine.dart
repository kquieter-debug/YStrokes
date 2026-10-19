import 'dart:math' as math;

import '../models/stroke.dart';
import '../rust/api.dart' as rust;

/// 画板引擎：管理笔画列表与撤销/重做栈。
///
/// 职责划分：
/// - 几何平滑在采集阶段由 `StrokeSmoother` 增量完成（见该类注释）。
/// - 本类只维护会话状态：笔画顺序、撤销/重做、版本号。
/// - 持久化不在本类内：由 `DocumentStore` 负责 I/O，画板界面负责编排。
///
/// `addStroke` 是**同步**的：绘画应用里「抬手」必须当帧完成提交，任何异步等待
/// 都会表现为笔画消失一帧再出现。跨语言调用一律不进入输入热路径。
class DrawingEngine {
  final List<Stroke> _strokes = [];
  final List<_Edit> _undoStack = [];
  final List<_Edit> _redoStack = [];

  int _nextId = 0;

  /// 状态版本号：每次内容变化自增，供渲染层判断是否需要重建缓存。
  int _revision = 0;

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

  /// 提交一笔。
  ///
  /// [points] 必须是 `StrokeSmoother.finish()` 的产出——即已经平滑、且与屏幕上
  /// 显示的点列完全一致，本类不再做任何几何加工。
  /// [widthRatio] 为归一化笔宽（相对画布短边）。
  Stroke addStroke(
    List<rust.StrokePoint> points, {
    required int color,
    required double widthRatio,
  }) {
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

  /// 清空画布。此操作可撤销——误触清空不应造成不可逆损失。
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
