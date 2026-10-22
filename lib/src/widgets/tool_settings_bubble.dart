import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/tool_settings.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';
import '../services/stroke_outline.dart';
import 'bubble_surface.dart';
import 'hsv_color_picker.dart';

/// 工具设置气泡：贴在悬浮工具栏旁边的小面板。
///
/// 与之前的底部弹窗相比有三处刻意的差异：
///
/// 1. **不遮全屏**。设置只影响「接下来画的笔」，没有理由把画布盖住；
///    气泡旁边的画面仍然可见，方便对照。
/// 2. **没有确认按钮**。每次改动立即回调 [onChanged]，关闭时无需提交任何东西——
///    因此系统返回键、点气泡外、拖动工具栏这几种关闭方式都不会丢改动。
/// 3. **关闭由外部负责**：气泡只上报 [onClose]，不自己 pop，方便按路由或按普通
///    组件两种方式使用（测试里就不需要真实路由）。
///
/// 改动即时生效之所以安全：宽度与颜色只影响之后画的笔，压感标记也记在笔画上
/// （ADR-019），因此拨开关不会触发整篇内容重烘焙。
///
/// 出入场动画由 [BubbleSurface] 负责，缩放锚点贴在朝向工具栏的那一侧：
/// 气泡看起来是从工具栏边缘长出来的，而不是在屏幕中央凭空放大。
class ToolSettingsBubble extends StatefulWidget {
  const ToolSettingsBubble({
    super.key,
    required this.tool,
    required this.initial,
    required this.anchor,
    required this.onChanged,
    required this.onClose,
    this.animation,
  });

  final ToolKind tool;
  final ToolSettings initial;

  /// 工具栏面板在全局坐标下的矩形；气泡贴在它旁边。
  final Rect anchor;

  /// 每次改动都会回调，画板据此即时更新当前工具参数。
  final ValueChanged<ToolSettings> onChanged;

  /// 气泡被要求关闭（点外部 / 尝试拖动工具栏）。
  final VoidCallback onClose;

  /// 出入场动画；为空时直接呈现（便于单独测试布局）。
  final Animation<double>? animation;

  @override
  State<ToolSettingsBubble> createState() => _ToolSettingsBubbleState();
}

class _ToolSettingsBubbleState extends State<ToolSettingsBubble> {
  late ToolSettings _settings = widget.initial;

  bool get _isBrush => widget.tool == ToolKind.brush;

  String get _title => _isBrush ? '画笔' : '橡皮';

  /// 气泡与工具栏、屏幕边缘的最小间距。
  static const double _gap = 12;

  /// 气泡宽度上限与下限。
  static const double _maxWidth = 300;
  static const double _minWidth = 216;

  /// 就地更新并上报。
  void _update(ToolSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final inset = media.padding;

    // 优先放在工具栏右侧；右侧放不下就翻到左侧。两边都窄时取空间大的一侧，
    // 由下面的 clamp 保证不出屏。
    final spaceRight = screen.width - widget.anchor.right - _gap - inset.right;
    final spaceLeft = widget.anchor.left - _gap - inset.left;
    final onRight = spaceRight >= spaceLeft;
    final available = onRight ? spaceRight : spaceLeft;
    final width = available.clamp(_minWidth, _maxWidth);

    final left = onRight
        ? widget.anchor.right + _gap
        : widget.anchor.left - _gap - width;
    final maxHeight = math.max(
      160.0,
      screen.height - inset.top - inset.bottom - _gap * 2,
    );
    // 顶端与工具栏对齐，但不出上下安全区。
    final top = widget.anchor.top
        .clamp(inset.top + _gap, math.max(inset.top + _gap, screen.height - inset.bottom - _gap - 320));

    return Stack(
      children: [
        BubbleBarrier(
          key: const Key('tool-settings-barrier'),
          onClose: widget.onClose,
        ),
        Positioned(
          key: const Key('tool-settings-bubble'),
          left: left.clamp(inset.left + _gap, screen.width),
          top: top.toDouble(),
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: BubbleSurface(
              animation: widget.animation,
              // 锚在朝向工具栏的那条边：右侧展开时贴左边缘，翻到左侧时贴右边缘。
              alignment: onRight ? Alignment.centerLeft : Alignment.centerRight,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: _buildContent(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _isBrush ? Icons.brush_outlined : Icons.auto_fix_normal_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(_title, style: theme.textTheme.titleSmall),
            ],
          ),
          if (_isBrush) ...[
            const SizedBox(height: 10),
            Center(
              child: HsvColorPicker(
                color: _settings.color,
                size: 190,
                onChanged: (color) =>
                    _update(_settings.copyWith(color: color)),
              ),
            ),
            const SizedBox(height: 10),
            Center(child: _ColorReadout(color: _settings.color)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Text('粗细', style: theme.textTheme.bodyMedium),
              const Spacer(),
              Text(
                _settings.widthLabel,
                style: theme.textTheme.bodySmall?.copyWith(
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
            onChanged: (value) =>
                _update(_settings.copyWith(widthRatio: value)),
          ),
          _pressureRow(theme),
          const SizedBox(height: 8),
          _StrokePreview(
            color: _isBrush ? _settings.color : theme.colorScheme.outline,
            widthRatio: _settings.widthRatio,
            pressureEnabled: _settings.pressureEnabled,
          ),
        ],
      ),
    );
  }

  /// 压感开关。
  ///
  /// 不用 `SwitchListTile`：它要求最近的 Material 祖先提供水波纹宿主，
  /// 这里已经在一个带圆角的 Material 内，直接用紧凑的 Row 更可控。
  Widget _pressureRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('压感', style: theme.textTheme.bodyMedium),
              Text(
                '只影响之后画的笔，已画内容不变',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(
          key: const Key('tool-pressure-switch'),
          value: _settings.pressureEnabled,
          onChanged: (value) =>
              _update(_settings.copyWith(pressureEnabled: value)),
        ),
      ],
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
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
        ),
        const SizedBox(width: 8),
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
/// 气泡里的改动不即时作用到画布，所以这块预览是唯一的即时反馈——
/// 它必须与实际渲染同源，否则开关一拨，预览和画布就会说两套话。
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
      height: 62,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
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
        size: const Size(double.infinity, 62),
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
      pressure: 0.3 + 0.7 * math.pow(math.sin(math.pi * t), 0.6).toDouble(),
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
