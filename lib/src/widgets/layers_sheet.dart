import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../services/drawing_engine.dart';

/// 图层面板（底部弹出）。
///
/// 自上而下按「顶层在前」展示，与 Photoshop 的面板顺序一致；引擎内部则用
/// 自下而上的顺序绘制，两者只在展示处反转一次。
///
/// 面板直接操作引擎（引擎是本页唯一的事实来源），并通过 [onChanged] 通知画板
/// 重绘与触发自动保存。
class LayersSheet extends StatefulWidget {
  const LayersSheet({
    super.key,
    required this.engine,
    required this.onChanged,
  });

  final DrawingEngine engine;
  final VoidCallback onChanged;

  @override
  State<LayersSheet> createState() => _LayersSheetState();
}

class _LayersSheetState extends State<LayersSheet> {
  DrawingEngine get _engine => widget.engine;

  void _mutate(VoidCallback action) {
    setState(action);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layers = _engine.layers;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                  onPressed: () => _mutate(_engine.addLayer),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView(
                shrinkWrap: true,
                children: [
                  // 顶层在前。
                  for (final layer in layers.reversed) _buildRow(context, layer),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('不透明度', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  '${(_engine.activeLayer.opacity * 100).round()}%',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('layer-opacity'),
              value: _engine.activeLayer.opacity.clamp(0.0, 1.0),
              onChanged: (value) => _mutate(
                () => _engine.setLayerOpacity(_engine.activeLayerId, value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, DrawingLayer layer) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = layer.id == _engine.activeLayerId;
    final canDelete = _engine.layers.length > 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _mutate(() => _engine.selectLayer(layer.id)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: layer.visible ? '隐藏图层' : '显示图层',
                  onPressed: () => _mutate(
                    () => _engine.setLayerVisible(layer.id, !layer.visible),
                  ),
                  icon: Icon(
                    layer.visible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
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
                        '${(layer.opacity * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: canDelete ? '删除图层' : '至少保留一个图层',
                  onPressed: canDelete
                      ? () => _mutate(() => _engine.removeLayer(layer.id))
                      : null,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
