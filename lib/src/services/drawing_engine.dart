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

  /// 撤销步数上限。
  ///
  /// 每一笔都完整持有自己的点列，没有上限时内存只增不减——一个长会话（几千笔）
  /// 会把几十兆的历史一直留着。25 步覆盖了「连续几次画错」的真实使用，
  /// 超出后丢弃最旧的一条：这里选择**静默丢弃**而不是提醒，
  /// 因为弹窗打断绘画比少一步历史更烦人。
  static const int maxUndoSteps = 25;

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
    _pushEdit(_AddStrokeEdit(layer.id, stroke));
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
    _pushEdit(_AddLayerEdit(layer, insertAt, previousActive));
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

    _pushEdit(_RemoveLayerEdit(layer, index, previousActive));
    _revision++;
    return true;
  }

  /// 复制图层：副本插在源图层上方并选中，笔画按新 id 复制。
  ///
  /// 笔画重新分配 id 而不是沿用：id 在文档内唯一，撤销/日志都按 id 寻址，
  /// 两层共用同一批 id 会让「删掉其中一层的一笔」误伤另一层。
  DrawingLayer? duplicateLayer(String id) {
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (index < 0) return null;
    final source = _layers[index];

    final copy = DrawingLayer(
      id: 'layer-${_nextLayerSeq++}',
      name: '${source.name} 副本',
      opacity: source.opacity,
      visible: source.visible,
      blendMode: source.blendMode,
      strokes: <Stroke>[
        for (final stroke in source.strokes)
          Stroke(
            id: _nextStrokeId++,
            tool: stroke.tool,
            color: stroke.color,
            widthRatio: stroke.widthRatio,
            points: stroke.points,
            usesPressure: stroke.usesPressure,
          ),
      ],
    );

    final previousActive = _activeLayerId;
    _layers.insert(index + 1, copy);
    _activeLayerId = copy.id;
    _pushEdit(_AddLayerEdit(copy, index + 1, previousActive));
    _revision++;
    return copy;
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
    _pushEdit(_RenameLayerEdit(id, previous, next));
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
    _pushEdit(_MoveLayerEdit(fromIndex, toIndex));
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

    _pushEdit(_MergeDownEdit(
      lowerId: lower.id,
      upperLayer: upper,
      upperIndex: index,
      mergedStrokes: merged,
      previousActiveId: previousActive,
    ));
    _revision++;
    return lower;
  }

  // ---- 笔画整段替换（选区/图层变换）----

  /// 取某图层当前笔画的快照。
  ///
  /// 变换会话以「原始快照」为基准逐帧重算，避免在结果上累乘导致误差与
  /// 抖动；快照同时充当撤销记录里的 `before`。
  List<Stroke> snapshotStrokes(String layerId) =>
      List<Stroke>.of(_layerById(layerId)?.strokes ?? const <Stroke>[]);

  /// 直接替换某图层的笔画列表，**不进撤销栈**。
  ///
  /// 只用于变换过程中的实时预览：每一帧都会调用，若每次都入栈，
  /// 撤销栈会被几百条中间态填满。
  void setStrokes(String layerId, List<Stroke> strokes) {
    final layer = _layerById(layerId);
    if (layer == null) return;
    layer.strokes
      ..clear()
      ..addAll(strokes);
    _revision++;
  }

  /// 变换提交：把 [before] 到当前状态记为**一条**撤销记录。
  void commitStrokes(String layerId, List<Stroke> before) {
    final layer = _layerById(layerId);
    if (layer == null) return;
    _pushEdit(_ReplaceStrokesEdit(layerId, before, List<Stroke>.of(layer.strokes)));
    _revision++;
  }

  /// 把崩溃日志里的笔画补进内存，返回补回的条数。
  ///
  /// 按图层下标定位、按笔画 id 去重：日志只覆盖「最后一次完整保存之后」的增量，
  /// 但清空日志本身也可能被打断，因此重放时必须容忍重复。
  int restoreStrokes(Map<int, List<Stroke>> byLayer) {
    var added = 0;
    for (final entry in byLayer.entries) {
      if (entry.key < 0 || entry.key >= _layers.length) continue;
      final layer = _layers[entry.key];
      final existing = layer.strokes.map((stroke) => stroke.id).toSet();
      for (final stroke in entry.value) {
        if (!existing.add(stroke.id)) continue;
        layer.strokes.add(stroke);
        added++;
      }
    }

    if (added > 0) {
      // 新笔画的 id 必须越过恢复出来的那些，否则下一次抬笔会撞 id。
      for (final layer in _layers) {
        for (final stroke in layer.strokes) {
          _nextStrokeId = math.max(_nextStrokeId, stroke.id + 1);
        }
      }
      _revision++;
    }
    return added;
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

  /// 删除指定笔画（选区删除）。可撤销。
  ///
  /// 返回实际删除的条数。按 id 而不是下标移除：变换与删除期间用户可能已经
  /// 撤销过别的操作，下标不再可信。
  int removeStrokes(String layerId, Set<int> ids) {
    final layer = _layerById(layerId);
    if (layer == null || ids.isEmpty) return 0;
    final removed = <Stroke>[
      for (final stroke in layer.strokes)
        if (ids.contains(stroke.id)) stroke,
    ];
    if (removed.isEmpty) return 0;

    _pushEdit(_RemoveStrokesEdit(layerId, removed));
    layer.strokes.removeWhere((stroke) => ids.contains(stroke.id));
    _revision++;
    return removed.length;
  }

  /// 入栈并裁剪到上限。
  ///
  /// 所有编辑都必须走这里：早期各方法各自 `_undoStack.add(...)` + `_redoStack.clear()`，
  /// 加上限时漏一处就会让上限形同虚设。
  void _pushEdit(_Edit edit) {
    _undoStack.add(edit);
    _redoStack.clear();
    if (_undoStack.length > maxUndoSteps) {
      _undoStack.removeRange(0, _undoStack.length - maxUndoSteps);
    }
  }

  /// 清空当前图层。此操作可撤销——误触清空不应造成不可逆损失。
  bool clear() {
    final layer = activeLayer;
    if (layer.strokes.isEmpty) return false;
    _pushEdit(_ClearLayerEdit(layer.id, List<Stroke>.of(layer.strokes)));
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

/// 整段替换某图层的笔画（选区变换、图层整体变换）。
///
/// 与 `_ClearLayerEdit` 的区别在于它是「替换」而不是「清空+添加」：
/// 变换后笔画数量不变、但每个点的坐标都变了，按 id 逐笔对账反而更容易出错。
class _ReplaceStrokesEdit implements _Edit {
  _ReplaceStrokesEdit(this.layerId, this.before, this.after);

  final String layerId;
  final List<Stroke> before;
  final List<Stroke> after;

  @override
  void undo(DrawingEngine engine) => _apply(engine, before);

  @override
  void redo(DrawingEngine engine) => _apply(engine, after);

  void _apply(DrawingEngine engine, List<Stroke> strokes) {
    final layer = engine._layerById(layerId);
    if (layer == null) return;
    layer.strokes
      ..clear()
      ..addAll(strokes);
  }
}

/// 按 id 删除若干笔画（选区删除）。
class _RemoveStrokesEdit implements _Edit {
  _RemoveStrokesEdit(this.layerId, this.removed);

  final String layerId;
  final List<Stroke> removed;

  @override
  void undo(DrawingEngine engine) {
    engine._layerById(layerId)?.strokes.addAll(removed);
  }

  @override
  void redo(DrawingEngine engine) {
    final ids = removed.map((stroke) => stroke.id).toSet();
    engine._layerById(layerId)?.strokes.removeWhere(
          (stroke) => ids.contains(stroke.id),
        );
  }
}
