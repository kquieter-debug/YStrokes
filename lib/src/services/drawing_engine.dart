import 'dart:math' as math;

import '../models/layer.dart';
import '../rust/api/document.dart' show LayerBlendMode;
import '../models/stroke.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';

/// 画板引擎：管理图层、笔画与撤销/重做栈。
///
/// 职责划分：
/// - 几何平滑在采集阶段由 `StrokeSmoother` 增量完成（见该类注释）。
/// - 本类只维护会话状态：图层顺序、当前图层、撤销/重做、版本号。
/// - 持久化不在本类内：由 `DocumentStore` 负责 I/O，画板界面负责编排。
///
/// `addStroke` 是**同步**的：绘画应用里「抬手」必须当帧完成提交，任何异步等待
/// 都会表现为笔画消失一帧再出现。跨语言调用一律不进入输入热路径。
class DrawingEngine {
  /// 构造即保证「至少有一个图层」：界面在文档载入完成前就会读取
  /// [activeLayer]（例如清空按钮的可用状态），不能让它处于空列表状态。
  DrawingEngine() {
    _ensureInitialLayer();
  }

  final List<DrawingLayer> _layers = <DrawingLayer>[];
  final List<_Edit> _undoStack = <_Edit>[];
  final List<_Edit> _redoStack = <_Edit>[];

  String _activeLayerId = '';
  int _nextLayerSeq = 0;
  int _nextStrokeId = 0;
  int _revision = 0;

  /// 图层列表（自下而上，只读视图）。
  List<DrawingLayer> get layers => List<DrawingLayer>.unmodifiable(_layers);

  /// 当前图层。任何时刻至少存在一个图层。
  DrawingLayer get activeLayer {
    for (final layer in _layers) {
      if (layer.id == _activeLayerId) return layer;
    }
    return _layers.first;
  }

  String get activeLayerId => activeLayer.id;

  /// 状态版本号，内容变化时递增。
  int get revision => _revision;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 所有图层都没有内容。
  bool get isEmpty => _layers.every((layer) => layer.strokes.isEmpty);

  int get strokeCount =>
      _layers.fold<int>(0, (sum, layer) => sum + layer.strokes.length);

  /// 载入已持久化的图层，重置撤销/重做历史。
  ///
  /// 载入后不产生撤销记录：历史属于「本次会话」，跨会话撤销会把用户带回
  /// 无法理解的状态。图层 id 按顺序重新分配。
  void load(List<DrawingLayer> layers) {
    _layers
      ..clear()
      ..addAll(layers);
    _ensureInitialLayer();

    // 让图层序号越过已有 id：载入的图层形如 layer-N，若把序号重置为图层数量，
    // 之后新建图层就会与已有 id 撞车（表现为选中/删除错层）。
    var maxSeq = _nextLayerSeq;
    for (final layer in _layers) {
      final parsed = int.tryParse(layer.id.replaceFirst('layer-', ''));
      if (parsed != null) maxSeq = math.max(maxSeq, parsed + 1);
    }
    _nextLayerSeq = maxSeq;

    // 打开工程时选中顶层，与 Photoshop 的行为一致。
    _activeLayerId = _layers.last.id;

    _undoStack.clear();
    _redoStack.clear();
    _nextStrokeId = 0;
    for (final layer in _layers) {
      for (final stroke in layer.strokes) {
        _nextStrokeId = math.max(_nextStrokeId, stroke.id + 1);
      }
    }
    _revision++;
  }

  /// 提交一笔到当前图层。
  ///
  /// [points] 必须是 `StrokeSmoother.finish()` 的产出——即已经平滑、且与屏幕上
  /// 显示的点列完全一致，本类不再做任何几何加工。
  Stroke addStroke(
    List<rust.StrokePoint> points, {
    required ToolKind tool,
    required int color,
    required double widthRatio,
    required bool usesPressure,
  }) {
    final stroke = Stroke(
      id: _nextStrokeId++,
      tool: tool,
      color: color,
      widthRatio: widthRatio,
      points: points,
      usesPressure: usesPressure,
    );
    final layer = activeLayer;
    layer.strokes.add(stroke);
    _undoStack.add(_AddStrokeEdit(layer.id, stroke));
    _redoStack.clear();
    _revision++;
    return stroke;
  }

  // ---- 图层操作 ----

  /// 在当前图层上方新建图层并选中它。
  DrawingLayer addLayer({String? name}) {
    final layer = DrawingLayer(
      id: 'layer-${_nextLayerSeq++}',
      name: name ?? '图层 ${_layers.length + 1}',
    );
    final index = _layers.indexWhere((item) => item.id == _activeLayerId);
    final insertAt = index < 0 ? _layers.length : index + 1;
    final previousActive = _activeLayerId;

    _layers.insert(insertAt, layer);
    _activeLayerId = layer.id;
    _undoStack.add(_AddLayerEdit(layer, insertAt, previousActive));
    _redoStack.clear();
    _revision++;
    return layer;
  }

  /// 删除图层。只剩一个图层时拒绝删除（文档必须至少有一层）。
  bool removeLayer(String id) {
    if (_layers.length <= 1) return false;
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (index < 0) return false;

    final layer = _layers[index];
    final previousActive = _activeLayerId;
    _layers.removeAt(index);

    if (_activeLayerId == id) {
      // 选中被删图层的下一层；删的是顶层则回落到新的顶层。
      _activeLayerId = _layers[math.min(index, _layers.length - 1)].id;
    }

    _undoStack.add(_RemoveLayerEdit(layer, index, previousActive));
    _redoStack.clear();
    _revision++;
    return true;
  }

  void selectLayer(String id) {
    if (_activeLayerId == id) return;
    if (!_layers.any((layer) => layer.id == id)) return;
    _activeLayerId = id;
    _revision++;
  }

  /// 调整不透明度。拖动滑杆会高频调用，因此不进入撤销栈。
  void setLayerOpacity(String id, double opacity) {
    final layer = _layerById(id);
    if (layer == null) return;
    final next = opacity.clamp(0.0, 1.0);
    if (layer.opacity == next) return;
    layer.opacity = next;
    _revision++;
  }

  /// 切换可见性。同样不进入撤销栈：它更像「视图开关」而非内容编辑。
  void setLayerVisible(String id, bool visible) {
    final layer = _layerById(id);
    if (layer == null || layer.visible == visible) return;
    layer.visible = visible;
    _revision++;
  }

  /// 设置混合模式。与不透明度同类：属于合成参数，不进撤销栈。
  void setLayerBlendMode(String id, LayerBlendMode mode) {
    final layer = _layerById(id);
    if (layer == null || layer.blendMode == mode) return;
    layer.blendMode = mode;
    _revision++;
  }

  /// 重命名图层。改名属于内容编辑，可撤销。
  bool renameLayer(String id, String name) {
    final layer = _layerById(id);
    final next = name.trim();
    if (layer == null || next.isEmpty || next == layer.name) return false;

    final previous = layer.name;
    layer.name = next;
    _undoStack.add(_RenameLayerEdit(id, previous, next));
    _redoStack.clear();
    _revision++;
    return true;
  }

  /// 移动图层位置，索引均为**自下而上**。
  bool moveLayer(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    if (fromIndex < 0 || fromIndex >= _layers.length) return false;
    if (toIndex < 0 || toIndex >= _layers.length) return false;

    final layer = _layers.removeAt(fromIndex);
    _layers.insert(toIndex, layer);
    _undoStack.add(_MoveLayerEdit(fromIndex, toIndex));
    _redoStack.clear();
    _revision++;
    return true;
  }

  /// 向下合并：把指定图层并入它下方那一层。
  ///
  /// 合并结果**沿用下方图层的合成参数**（不透明度 / 混合模式 / 名称），
  /// 上方图层的这些参数会被丢弃——这与像素图层的「合并向下」不同：
  /// 后者可以烘焙像素，而矢量笔画无法在保留可编辑性的前提下烘焙混合效果。
  /// 调用方应在丢弃非默认参数前向用户确认。
  ///
  /// 已在最底层时返回 null。
  DrawingLayer? mergeDown(String id) {
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (index <= 0) return null;

    final upper = _layers[index];
    final lower = _layers[index - 1];
    final merged = List<Stroke>.of(upper.strokes);
    final previousActive = _activeLayerId;

    lower.strokes.addAll(upper.strokes);
    _layers.removeAt(index);
    _activeLayerId = lower.id;

    _undoStack.add(_MergeDownEdit(
      lowerId: lower.id,
      upperLayer: upper,
      upperIndex: index,
      mergedStrokes: merged,
      previousActiveId: previousActive,
    ));
    _redoStack.clear();
    _revision++;
    return lower;
  }

  // ---- 撤销 / 重做 ----

  bool undo() {
    if (_undoStack.isEmpty) return false;
    final edit = _undoStack.removeLast();
    edit.undo(this);
    _redoStack.add(edit);
    _revision++;
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    final edit = _redoStack.removeLast();
    edit.redo(this);
    _undoStack.add(edit);
    _revision++;
    return true;
  }

  /// 清空当前图层。此操作可撤销——误触清空不应造成不可逆损失。
  bool clear() {
    final layer = activeLayer;
    if (layer.strokes.isEmpty) return false;
    _undoStack.add(_ClearLayerEdit(layer.id, List<Stroke>.of(layer.strokes)));
    _redoStack.clear();
    layer.strokes.clear();
    _revision++;
    return true;
  }

  // ---- 内部辅助 ----

  void _ensureInitialLayer() {
    if (_layers.isEmpty) {
      final layer = DrawingLayer(id: 'layer-${_nextLayerSeq++}', name: '图层 1');
      _layers.add(layer);
      _activeLayerId = layer.id;
    }
    if (_activeLayerId.isEmpty ||
        !_layers.any((layer) => layer.id == _activeLayerId)) {
      _activeLayerId = _layers.last.id;
    }
  }

  DrawingLayer? _layerById(String id) {
    for (final layer in _layers) {
      if (layer.id == id) return layer;
    }
    return null;
  }
}

/// 可撤销的编辑操作。
///
/// 操作直接持有引擎引用：图层的增删会改变索引，仅凭「笔画列表」无法定位，
/// 因此这里以图层 id 作为寻址依据。
abstract class _Edit {
  void undo(DrawingEngine engine);
  void redo(DrawingEngine engine);
}

class _AddStrokeEdit implements _Edit {
  _AddStrokeEdit(this.layerId, this.stroke);

  final String layerId;
  final Stroke stroke;

  @override
  void undo(DrawingEngine engine) {
    final layer = engine._layerById(layerId);
    if (layer == null) return;
    if (layer.strokes.isNotEmpty && layer.strokes.last.id == stroke.id) {
      layer.strokes.removeLast();
    } else {
      layer.strokes.removeWhere((item) => item.id == stroke.id);
    }
  }

  @override
  void redo(DrawingEngine engine) {
    engine._layerById(layerId)?.strokes.add(stroke);
  }
}

class _ClearLayerEdit implements _Edit {
  _ClearLayerEdit(this.layerId, this.removed);

  final String layerId;
  final List<Stroke> removed;

  @override
  void undo(DrawingEngine engine) {
    engine._layerById(layerId)?.strokes.addAll(removed);
  }

  @override
  void redo(DrawingEngine engine) {
    engine._layerById(layerId)?.strokes.clear();
  }
}

class _AddLayerEdit implements _Edit {
  _AddLayerEdit(this.layer, this.index, this.previousActiveId);

  final DrawingLayer layer;
  final int index;
  final String previousActiveId;

  @override
  void undo(DrawingEngine engine) {
    engine._layers.removeWhere((item) => item.id == layer.id);
    engine._activeLayerId = previousActiveId;
  }

  @override
  void redo(DrawingEngine engine) {
    final at = index.clamp(0, engine._layers.length);
    engine._layers.insert(at, layer);
    engine._activeLayerId = layer.id;
  }
}

/// 重命名图层。
class _RenameLayerEdit implements _Edit {
  _RenameLayerEdit(this.layerId, this.previousName, this.nextName);

  final String layerId;
  final String previousName;
  final String nextName;

  @override
  void undo(DrawingEngine engine) {
    final layer = engine._layerById(layerId);
    if (layer != null) layer.name = previousName;
  }

  @override
  void redo(DrawingEngine engine) {
    final layer = engine._layerById(layerId);
    if (layer != null) layer.name = nextName;
  }
}

/// 移动图层位置。
class _MoveLayerEdit implements _Edit {
  _MoveLayerEdit(this.fromIndex, this.toIndex);

  final int fromIndex;
  final int toIndex;

  @override
  void undo(DrawingEngine engine) {
    final layer = engine._layers.removeAt(toIndex);
    engine._layers.insert(fromIndex, layer);
  }

  @override
  void redo(DrawingEngine engine) {
    final layer = engine._layers.removeAt(fromIndex);
    engine._layers.insert(toIndex, layer);
  }
}

/// 向下合并。
class _MergeDownEdit implements _Edit {
  _MergeDownEdit({
    required this.lowerId,
    required this.upperLayer,
    required this.upperIndex,
    required this.mergedStrokes,
    required this.previousActiveId,
  });

  final String lowerId;
  final DrawingLayer upperLayer;
  final int upperIndex;

  /// 被并入下方图层的那些笔画，撤销时按引用移除。
  final List<Stroke> mergedStrokes;
  final String previousActiveId;

  @override
  void undo(DrawingEngine engine) {
    final lower = engine._layerById(lowerId);
    if (lower != null) {
      lower.strokes.removeWhere(mergedStrokes.contains);
    }
    engine._layers.insert(upperIndex, upperLayer);
    engine._activeLayerId = previousActiveId;
  }

  @override
  void redo(DrawingEngine engine) {
    final lower = engine._layerById(lowerId);
    lower?.strokes.addAll(mergedStrokes);
    engine._layers.removeWhere((layer) => layer.id == upperLayer.id);
    engine._activeLayerId = lowerId;
  }
}

class _RemoveLayerEdit implements _Edit {
  _RemoveLayerEdit(this.layer, this.index, this.previousActiveId);

  final DrawingLayer layer;
  final int index;
  final String previousActiveId;

  @override
  void undo(DrawingEngine engine) {
    final at = index.clamp(0, engine._layers.length);
    engine._layers.insert(at, layer);
    engine._activeLayerId = previousActiveId;
  }

  @override
  void redo(DrawingEngine engine) {
    engine._layers.removeWhere((item) => item.id == layer.id);
    if (engine._activeLayerId == layer.id && engine._layers.isNotEmpty) {
      engine._activeLayerId =
          engine._layers[math.min(index, engine._layers.length - 1)].id;
    }
  }
}
