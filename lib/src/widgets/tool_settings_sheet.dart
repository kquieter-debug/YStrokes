import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/tool_settings.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';
import '../services/stroke_outline.dart';
import 'hsv_color_picker.dart';

/// 工具设置面板：长按工具图标后弹出。
///
/// 布局参照 Photoshop 的工具选项——颜色、粗细与压感属于「工具的参数」，
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
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('tool-pressure-switch'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _settings.pressureEnabled,
              onChanged: (value) => setState(
                () => _settings = _settings.copyWith(pressureEnabled: value),
              ),
              title: Text('压感', style: theme.textTheme.titleSmall),
              subtitle: Text(
                '笔宽随压力变化；切换后已有笔画随之重绘',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _StrokePreview(
              color: _isBrush ? _settings.color : theme.colorScheme.outline,
              widthRatio: _settings.widthRatio,
              pressureEnabled: _settings.pressureEnabled,
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
///
/// 压感开启时不再画「固定宽描边」，而是用与画布完全相同的 `buildStrokeOutline`
/// 生成轮廓——预览若用另一套近似，它就会在开关打开后立刻说谎。
class _StrokePreview extends StatelessWidget {
  const _StrokePreview({
    required this.color,
    required this.widthRatio,
    required this.pressureEnabled,
  });

  final Color color;
  final double widthRatio;
  final bool pressureEnabled;

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
        painter: _StrokePreviewPainter(
          color: color,
          widthRatio: widthRatio,
          pressureEnabled: pressureEnabled,
        ),
        size: const Size(double.infinity, 72),
      ),
    );
  }
}

class _StrokePreviewPainter extends CustomPainter {
  const _StrokePreviewPainter({
    required this.color,
    required this.widthRatio,
    required this.pressureEnabled,
  });

  final Color color;
  final double widthRatio;
  final bool pressureEnabled;

  /// 预览曲线的采样密度：足以让轮廓平滑，又不至于让步进感可见。
  static const int _samples = 48;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 以预览区短边模拟文档短边，笔宽换算关系与画板一致。
    final width = (widthRatio * size.height).clamp(1.0, size.height * 0.8);

    if (!pressureEnabled) {
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
      return;
    }

    final points = <rust.StrokePoint>[
      for (var i = 0; i < _samples; i++) _sampleAt(i / (_samples - 1), size),
    ];
    final outline = buildStrokeOutline(
      points: points,
      spaceWidth: size.width,
      spaceHeight: size.height,
      baseWidth: width,
      pressure: true,
    );
    if (outline.isEmpty) return;
    canvas.drawPath(
      outlineToPath(outline),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  /// 沿预览曲线取一点，并给出「起笔轻、中段重、收笔轻」的模拟压力。
  rust.StrokePoint _sampleAt(double t, Size size) {
    final x = _cubic(
      size.width * 0.12,
      size.width * 0.34,
      size.width * 0.64,
      size.width * 0.88,
      t,
    );
    final y = _cubic(
      size.height * 0.68,
      size.height * 0.12,
      size.height * 0.92,
      size.height * 0.34,
      t,
    );
    return rust.StrokePoint(
      x: x / size.width,
      y: y / size.height,
      // 两端 0.3、中段 1.0：与实际书写时的手感分布一致。
      pressure: 0.3 +
          0.7 * math.pow(math.sin(math.pi * t), 0.6).toDouble(),
      timestampMs: 0,
    );
  }

  double _cubic(double a, double b, double c, double d, double t) {
    final u = 1 - t;
    return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
  }

  @override
  bool shouldRepaint(covariant _StrokePreviewPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.widthRatio != widthRatio ||
      oldDelegate.pressureEnabled != pressureEnabled;
}
