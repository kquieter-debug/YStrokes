import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../services/app_settings.dart';
import '../services/drawing_engine.dart';

/// 图层气泡的内容区。
///
/// 只负责「内容 + 交互」，外框、定位与出入场动画由 [LayersBubble] 提供；
/// 这也让它能在测试里被单独挂载（不需要真实路由）。
///
/// 自上而下按「顶层在前」展示，与 Photoshop 的面板顺序一致；引擎内部则用
/// 自下而上的顺序绘制，两者只在展示处反转一次。
///
/// 交互约定：
/// - 点按行 → 选中该层；长按行 → 拖拽排序。
/// - 拖拽默认**不**即时重绘画布（见 [AppSettings.liveLayerReorder]）：
///   拖动只更新列表占位，松手才提交顺序，避免逐帧重建合成结果。
/// - 每行的「更多」菜单提供重命名、向下合并、删除。
/// - 底部的「清空当前图层」需要二次确认；确认后清空并**关闭气泡**，
///   让画布结果与随之出现的提示都可见。
class LayersPanel extends StatefulWidget {
  const LayersPanel({
    super.key,
    required this.engine,
    required this.onChanged,
    required this.onClose,
    required this.onCleared,
    required this.onTransform,
    required this.onFlip,
  });

  final DrawingEngine engine;

  /// 图层状态改变后回调：通知画板重绘并触发自动保存。
  final VoidCallback onChanged;

  /// 请求关闭气泡（清空图层后使用）。
  final VoidCallback onClose;

  /// 刚刚清空过当前图层，由画板负责弹提示。
  final VoidCallback onCleared;

  /// 请求对该图层做整体变换；画板负责关气泡并进入变换态。
  final ValueChanged<String> onTransform;

  /// 翻转整层：`(layerId, 是否水平)`。与变换不同，它一步到位，不进交互模式。
  final void Function(String layerId, bool horizontal) onFlip;

  @override
  State<LayersPanel> createState() => _LayersPanelState();
}

class _LayersPanelState extends State<LayersPanel> {
  /// 拖拽中的**展示顺序**（顶层在前）。
  ///
  /// 默认模式下拖动只改这份预览顺序：列表跟手，画布不动，松手才写回引擎。
  /// 即时模式下该字段为 null，直接改引擎顺序。
  List<String>? _displayOrder;

  /// 拖拽反馈的宽度，取面板自身的宽度（构建期派生值）。
  ///
  /// 不能再用「屏幕宽度的 82%」：气泡比屏幕窄得多，那样拖起来的影子会飞出面板。
  double _feedbackWidth = 240;

  DrawingEngine get _engine => widget.engine;

  /// 当前用于渲染的图层列表（顶层在前）。
  List<DrawingLayer> get _displayLayers {
    final order = _displayOrder;
    if (order == null) return _engine.layers.reversed.toList();

    final byId = <String, DrawingLayer>{
      for (final layer in _engine.layers) layer.id: layer,
    };
    return <DrawingLayer>[
      for (final id in order)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  void _mutate(VoidCallback action) {
    setState(action);
    widget.onChanged();
  }

  // ---- 拖拽排序 ----

  void _onDragStarted() {
    if (AppSettings.liveLayerReorder.value) return;
    setState(() {
      _displayOrder =
          _engine.layers.reversed.map((layer) => layer.id).toList();
    });
  }

  void _onHoverTarget(String fromId, String toId) {
    if (fromId == toId) return;

    if (AppSettings.liveLayerReorder.value) {
      // 即时模式：每次滑入新行就改写引擎顺序，画布随拖动实时重绘。
      _moveLayerTo(fromId, toId);
      setState(() {});
      return;
    }

    // 默认模式：只在预览顺序里挪动，画布保持原样。
    final order = _displayOrder;
    if (order == null) return;
    final from = order.indexOf(fromId);
    final to = order.indexOf(toId);
    if (from < 0 || to < 0 || from == to) return;

    setState(() {
      final id = order.removeAt(from);
      order.insert(to, id);
    });
  }

  void _onDragEnd(String fromId) {
    final order = _displayOrder;
    setState(() => _displayOrder = null);
    if (AppSettings.liveLayerReorder.value || order == null) return;

    // 预览顺序是顶层在前，引擎是底层在前：换算成引擎索引后一次性提交。
    final displayIndex = order.indexOf(fromId);
    if (displayIndex < 0) return;
    final from = _engine.layers.indexWhere((layer) => layer.id == fromId);
    final to = _engine.layers.length - 1 - displayIndex;
    if (from < 0 || from == to) return;
    if (_engine.moveLayer(from, to)) widget.onChanged();
  }

  void _moveLayerTo(String fromId, String toId) {
    final from = _engine.layers.indexWhere((layer) => layer.id == fromId);
    final to = _engine.layers.indexWhere((layer) => layer.id == toId);
    if (from < 0 || to < 0 || from == to) return;
    if (_engine.moveLayer(from, to)) widget.onChanged();
  }

  // ---- 行内操作 ----

  Future<void> _rename(DrawingLayer layer) async {
    final controller = TextEditingController(text: layer.name);
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名图层'),
        content: TextField(
          key: const Key('layer-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '图层名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('layer-rename-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (input == null || !mounted) return;
    _mutate(() => _engine.renameLayer(layer.id, input));
  }

  Future<void> _mergeDown(DrawingLayer layer) async {
    final index = _engine.layers.indexWhere((item) => item.id == layer.id);
    if (index <= 0) return;

    // 上方图层若带非默认的合成参数，合并后这些参数会被丢弃，外观可能改变。
    // 矢量笔画无法像像素图层那样把它们烘焙进像素，只能先告知用户。
    final losesEffects = layer.opacity < 0.999 || !layer.blendMode.isNormal;

    if (losesEffects) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('向下合并'),
          content: const Text('该图层带有不透明度或混合模式，合并后外观可能发生变化。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    _mutate(() => _engine.mergeDown(layer.id));
  }

  /// 清空当前图层：先二次确认，确认后清空并关闭气泡。
  ///
  /// 清空本身可撤销（引擎里是一条 `_ClearLayerEdit`），但误触的代价是
  /// 「以为自己删错了」的一整轮慌乱，因此仍然要求确认。
  Future<void> _clearActiveLayer() async {
    final layer = _engine.activeLayer;
    if (layer.strokes.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空图层'),
        content: Text(
          '将清空「${layer.name}」的 ${layer.strokes.length} 笔内容。\n'
          '此操作可以通过撤销恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('layer-clear-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!_engine.clear()) return;

    widget.onChanged();
    setState(() {});
    // 关掉气泡：清空后画布立刻可见，画板弹出的提示也不会被面板遮住。
    widget.onCleared();
    widget.onClose();
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layers = _engine.layers;
    final active = _engine.activeLayer;

    return LayoutBuilder(
      builder: (context, constraints) {
        _feedbackWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _feedbackWidth;

        final list = SingleChildScrollView(
          child: Column(
            // 顶层在前。
            children: [
              for (final layer in _displayLayers) _buildRow(context, layer),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('图层', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Text(
                    '${layers.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const Key('layer-add'),
                    tooltip: '新建图层',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _mutate(_engine.addLayer),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              // 有界高度时让列表吃掉剩余空间（气泡的高矮随屏幕变化）；
              // 无界高度时（例如测试里直接挂载面板）退回到固定上限。
              if (constraints.maxHeight.isFinite)
                Flexible(child: list)
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: list,
                ),
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('不透明度', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    '${(active.opacity * 100).round()}%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const Key('layer-opacity'),
                  value: active.opacity.clamp(0.0, 1.0),
                  onChanged: (value) => _mutate(
                    () => _engine.setLayerOpacity(_engine.activeLayerId, value),
                  ),
                ),
              ),
              Row(
                children: [
                  Text('混合模式', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  DropdownButton<LayerBlendMode>(
                    key: const Key('layer-blend'),
                    value: active.blendMode,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: theme.textTheme.bodyMedium,
                    items: [
                      for (final mode in kLayerBlendModes)
                        DropdownMenuItem<LayerBlendMode>(
                          value: mode,
                          child: Text(mode.label),
                        ),
                    ],
                    onChanged: (mode) {
                      if (mode == null) return;
                      _mutate(
                        () => _engine.setLayerBlendMode(
                          _engine.activeLayerId,
                          mode,
                        ),
                      );
                    },
                  ),
                ],
              ),
              const Divider(height: 1),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('layer-clear'),
                  onPressed: active.strokes.isEmpty ? null : _clearActiveLayer,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.layers_clear_outlined, size: 18),
                  label: const Text('清空当前图层'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, DrawingLayer layer) {
    final index = _engine.layers.indexWhere((item) => item.id == layer.id);
    final canDelete = _engine.layers.length > 1;
    final canMerge = index > 0;

    return DragTarget<String>(
      key: ValueKey<String>(layer.id),
      onWillAcceptWithDetails: (details) {
        _onHoverTarget(details.data, layer.id);
        return true;
      },
      builder: (context, candidateData, rejectedData) {
        final content = _buildRowContent(
          context,
          layer,
          canDelete: canDelete,
          canMerge: canMerge,
          highlighted: candidateData.isNotEmpty,
        );

        return LongPressDraggable<String>(
          data: layer.id,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragStarted: _onDragStarted,
          onDraggableCanceled: (_, _) => _onDragEnd(layer.id),
          onDragEnd: (_) => _onDragEnd(layer.id),
          feedback: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: _feedbackWidth,
              child: _buildRowContent(
                context,
                layer,
                canDelete: canDelete,
                canMerge: canMerge,
                interactive: false,
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: content),
          child: content,
        );
      },
    );
  }

  Widget _buildRowContent(
    BuildContext context,
    DrawingLayer layer, {
    required bool canDelete,
    required bool canMerge,
    bool highlighted = false,
    bool interactive = true,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = layer.id == _engine.activeLayerId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: highlighted
            ? scheme.primaryContainer.withValues(alpha: 0.75)
            : active
                ? scheme.primaryContainer.withValues(alpha: 0.45)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: interactive
              ? () => _mutate(() => _engine.selectLayer(layer.id))
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Row(
              children: [
                IconButton(
                  tooltip: layer.visible ? '隐藏图层' : '显示图层',
                  visualDensity: VisualDensity.compact,
                  onPressed: interactive
                      ? () => _mutate(
                            () => _engine.setLayerVisible(
                              layer.id,
                              !layer.visible,
                            ),
                          )
                      : null,
                  icon: Icon(
                    layer.visible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 19,
                    color: layer.visible
                        ? scheme.onSurfaceVariant
                        : scheme.outline,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        layer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: active ? FontWeight.w600 : null,
                          color: layer.visible
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${layer.strokes.length} 笔 · '
                        '${(layer.opacity * 100).round()}%'
                        '${layer.blendMode.isNormal ? '' : ' · ${layer.blendMode.label}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (interactive)
                  PopupMenuButton<String>(
                    tooltip: '图层操作',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (action) {
                      switch (action) {
                        case 'rename':
                          _rename(layer);
                        case 'duplicate':
                          _mutate(() => _engine.duplicateLayer(layer.id));
                        case 'transform':
                          widget.onTransform(layer.id);
                        case 'flip-h':
                          widget.onFlip(layer.id, true);
                        case 'flip-v':
                          widget.onFlip(layer.id, false);
                        case 'merge':
                          _mergeDown(layer);
                        case 'delete':
                          _mutate(() => _engine.removeLayer(layer.id));
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: 'rename',
                        child: Text('重命名'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'duplicate',
                        child: Text('复制图层'),
                      ),
                      PopupMenuItem<String>(
                        value: 'transform',
                        // 空图层没有可变换的内容，置灰比让他点一下才知道更省事。
                        enabled: layer.strokes.isNotEmpty,
                        child: const Text('变换图层'),
                      ),
                      PopupMenuItem<String>(
                        value: 'flip-h',
                        enabled: layer.strokes.isNotEmpty,
                        child: const Text('水平翻转'),
                      ),
                      PopupMenuItem<String>(
                        value: 'flip-v',
                        enabled: layer.strokes.isNotEmpty,
                        child: const Text('垂直翻转'),
                      ),
                      PopupMenuItem<String>(
                        value: 'merge',
                        enabled: canMerge,
                        child: Text(canMerge ? '向下合并' : '已在最底层'),
                      ),
                      PopupMenuItem<String>(
                        value: 'delete',
                        enabled: canDelete,
                        child: Text(canDelete ? '删除' : '至少保留一个图层'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
