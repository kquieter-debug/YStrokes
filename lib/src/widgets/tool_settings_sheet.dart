import 'package:flutter/material.dart';

import '../models/tool_settings.dart';
import '../rust/api/tools.dart';
import 'hsv_color_picker.dart';

/// 工具设置面板：长按工具图标后弹出。
///
/// 布局参照 Photoshop 的工具选项——颜色与粗细属于「工具的参数」，
/// 而不是常驻在工具栏上的控件，因此只在选中该工具并进入设置时才出现。
class ToolSettingsSheet extends StatefulWidget {
  const ToolSettingsSheet({
    super.key,
    required this.tool,
    required this.initial,
  });

  final ToolKind tool;
  final ToolSettings initial;

  @override
  State<ToolSettingsSheet> createState() => _ToolSettingsSheetState();
}

class _ToolSettingsSheetState extends State<ToolSettingsSheet> {
  late ToolSettings _settings = widget.initial;

  bool get _isBrush => widget.tool == ToolKind.brush;

  String get _title => _isBrush ? '画笔设置' : '橡皮设置';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(_title, style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_settings),
                  child: const Text('完成'),
                ),
              ],
            ),
            if (_isBrush) ...[
              const SizedBox(height: 4),
              Center(
                child: HsvColorPicker(
                  color: _settings.color,
                  onChanged: (color) =>
                      setState(() => _settings = _settings.copyWith(color: color)),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: _ColorReadout(color: _settings.color)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Text('粗细', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  _settings.widthLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('tool-width-slider'),
              value: _settings.widthRatio.clamp(
                ToolSettings.minWidthRatio,
                ToolSettings.maxWidthRatio,
              ),
              min: ToolSettings.minWidthRatio,
              max: ToolSettings.maxWidthRatio,
              onChanged: (value) => setState(
                () => _settings = _settings.copyWith(widthRatio: value),
              ),
            ),
            const SizedBox(height: 8),
            _StrokePreview(
              color: _isBrush ? _settings.color : theme.colorScheme.outline,
              widthRatio: _settings.widthRatio,
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前颜色的色块与十六进制值。
class _ColorReadout extends StatelessWidget {
  const _ColorReadout({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hex = color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '#${hex.substring(2)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 笔触预览：用真实笔宽比例画一段 S 形曲线。
class _StrokePreview extends StatelessWidget {
  const _StrokePreview({required this.color, required this.widthRatio});

  final Color color;
  final double widthRatio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: CustomPaint(
        painter: _StrokePreviewPainter(color: color, widthRatio: widthRatio),
        size: const Size(double.infinity, 72),
      ),
    );
  }
}

class _StrokePreviewPainter extends CustomPainter {
  const _StrokePreviewPainter({required this.color, required this.widthRatio});

  final Color color;
  final double widthRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 以预览区短边模拟文档短边，笔宽换算关系与画板一致。
    final width = (widthRatio * size.height).clamp(1.0, size.height * 0.8);
    final path = Path()
      ..moveTo(size.width * 0.12, size.height * 0.68)
      ..cubicTo(
        size.width * 0.34,
        size.height * 0.12,
        size.width * 0.64,
        size.height * 0.92,
        size.width * 0.88,
        size.height * 0.34,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _StrokePreviewPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.widthRatio != widthRatio;
}
