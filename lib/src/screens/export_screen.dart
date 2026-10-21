import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/export_destination.dart';
import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../models/project.dart';
import '../services/app_settings.dart';
import '../services/document_painter.dart';
import '../services/export_bridge.dart';
import '../services/exporter.dart';
import '../widgets/section_card.dart';

/// 导出页面。
///
/// 结构：预览 → 格式 → 范围 → 尺寸 → 选项 → 保存位置。所有能力都围绕一个判据展开：
/// **可见图层是否全部为矢量**。含位图时 SVG 置灰并提示，自动落到 PNG；
/// 隐藏图层不参与判定，也不进入导出结果。
///
/// 这里**只负责把文件写出来**，不再唤起系统分享：分享面板会打断「导出 → 继续画」
/// 的节奏，而且路径不可见。导出完成后由画板把所在目录提示出来。
class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    required this.project,
    required this.layers,
    required this.activeLayerId,
    this.exporter,
    this.bridge,
  });

  final DrawingProject project;

  /// 导出时的图层快照。
  final List<DrawingLayer> layers;

  final String activeLayerId;

  /// 仅测试注入。
  final DocumentExporter? exporter;

  /// 仅测试注入；生产环境走平台通道 / 系统目录选择器。
  final ExportBridge? bridge;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

/// 输出尺寸档位。
enum _SizePreset { x1, x2, x3, custom }

class _ExportScreenState extends State<ExportScreen> {
  late final DocumentExporter _exporter =
      widget.exporter ?? DocumentExporter();

  ExportFormat _format = ExportFormat.png;
  ExportScope _scope = ExportScope.document;
  _SizePreset _preset = _SizePreset.x1;

  late final TextEditingController _widthController;
  late final TextEditingController _heightController;
  bool _lockAspect = true;

  late final ExportBridge _bridge =
      widget.bridge ?? const PlatformExportBridge();

  /// 当前导出目标；进入页面时沿用上次的选择。
  ExportDestination _destination = ExportDestination.platformDefault;

  /// 平台默认目录（异步解析，失败时保持 null，界面回落到中性文案）。
  String? _defaultDir;

  /// 系统目录选择器是否正在前台。
  bool _picking = false;

  bool _transparent = true;
  int _quality = 92;

  bool _busy = false;
  String? _error;

  int get _baseWidth => widget.project.document.widthPx;
  int get _baseHeight => widget.project.document.heightPx;

  /// 参与导出的图层：可见、非空、且符合当前范围。
  List<DrawingLayer> get _selectedLayers => <DrawingLayer>[
        for (final layer in widget.layers)
          if (layer.visible &&
              layer.opacity > 0 &&
              layer.strokes.isNotEmpty &&
              (_scope == ExportScope.document ||
                  layer.id == widget.activeLayerId))
            layer,
      ];

  /// 可见图层是否全部为矢量。含位图图层时不允许导出 SVG。
  bool get _canExportSvg => widget.layers
      .where((layer) => layer.visible && layer.strokes.isNotEmpty)
      .every((layer) => layer.isVector);

  bool get _hasNonNormalBlend => _selectedLayers
      .any((layer) => layer.visible && !layer.blendMode.isNormal);

  int get _outputWidth => switch (_preset) {
        _SizePreset.x1 => _baseWidth,
        _SizePreset.x2 => _baseWidth * 2,
        _SizePreset.x3 => _baseWidth * 3,
        _SizePreset.custom => int.tryParse(_widthController.text) ?? 0,
      };

  int get _outputHeight => switch (_preset) {
        _SizePreset.x1 => _baseHeight,
        _SizePreset.x2 => _baseHeight * 2,
        _SizePreset.x3 => _baseHeight * 3,
        _SizePreset.custom => int.tryParse(_heightController.text) ?? 0,
      };

  @override
  void initState() {
    super.initState();
    _widthController = TextEditingController(text: '$_baseWidth');
    _heightController = TextEditingController(text: '$_baseHeight');
    _destination = AppSettings.exportDestination.value;
    _loadDefaultDir();
  }

  /// 读出平台默认目录用于展示。
  ///
  /// 失败不影响导出（导出时会重新解析），因此只吞掉异常、让界面显示
  /// 「默认位置」四个字。
  Future<void> _loadDefaultDir() async {
    try {
      final path = await DocumentExporter.defaultOutputPath();
      if (!mounted) return;
      setState(() => _defaultDir = path);
    } catch (_) {
      // 忽略：路径只是提示，不参与逻辑。
    }
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  /// 唤起系统文件管理器选择导出目录。
  ///
  /// 桌面端是原生目录对话框（拿到绝对路径），Android 是 SAF 目录树（拿到
  /// `content://` 树 URI）。两者的差异由 [ExportBridge] 吸收，这里只关心
  /// 「选到了什么」。
  Future<void> _pickDirectory() async {
    if (_picking || _busy) return;
    setState(() {
      _picking = true;
      _error = null;
    });

    try {
      final picked = await _bridge.pickDirectory();
      if (!mounted) return;
      if (picked == null) return; // 用户取消

      final destination = picked.path != null
          ? ExportDestination.directory(picked.path!)
          : ExportDestination.tree(uri: picked.uri!, label: picked.label);
      setState(() => _destination = destination);
      await AppSettings.setExportDestination(destination);
    } on ExportBridgeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开目录选择器：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 恢复平台默认位置。
  Future<void> _resetDestination() async {
    setState(() => _destination = ExportDestination.platformDefault);
    await AppSettings.setExportDestination(ExportDestination.platformDefault);
  }

  /// 当前选项是否可用；不可用时给出原因。
  String? get _blockingError {
    if (_selectedLayers.isEmpty) return '没有可导出的内容';
    if (_format == ExportFormat.svg) return null;

    if (_preset == _SizePreset.custom) {
      final w = int.tryParse(_widthController.text);
      final h = int.tryParse(_heightController.text);
      if (w == null || h == null || w <= 0 || h <= 0) {
        return '请输入有效的宽高';
      }
    }
    final pixels = _outputWidth * _outputHeight;
    if (pixels > DocumentExporter.maxPixels) {
      return '输出尺寸过大（约 ${(pixels / 1000000).toStringAsFixed(0)} MP，上限 '
          '${DocumentExporter.maxPixels ~/ 1000000} MP）';
    }
    return null;
  }

  /// 某档倍率是否可用（受像素上限约束）。
  bool _presetAllowed(_SizePreset preset) {
    final w = switch (preset) {
      _SizePreset.x1 => _baseWidth,
      _SizePreset.x2 => _baseWidth * 2,
      _SizePreset.x3 => _baseWidth * 3,
      _SizePreset.custom => 0,
    };
    final h = switch (preset) {
      _SizePreset.x1 => _baseHeight,
      _SizePreset.x2 => _baseHeight * 2,
      _SizePreset.x3 => _baseHeight * 3,
      _SizePreset.custom => 0,
    };
    if (preset == _SizePreset.custom) return true;
    return w * h <= DocumentExporter.maxPixels;
  }

  void _onFormatChanged(ExportFormat format) {
    setState(() {
      _format = format;
      _error = null;
    });
  }

  void _onPresetChanged(_SizePreset preset) {
    setState(() {
      _preset = preset;
      if (preset == _SizePreset.custom) {
        _widthController.text = '$_outputWidth';
        _heightController.text = '$_outputHeight';
      }
    });
  }

  void _onWidthChanged(String value) {
    setState(() {
      if (_lockAspect) {
        final w = int.tryParse(value);
        if (w != null && w > 0) {
          final h = (w * _baseHeight / _baseWidth).round();
          _heightController.text = '$h';
        }
      }
    });
  }

  void _onHeightChanged(String value) {
    setState(() {
      if (_lockAspect) {
        final h = int.tryParse(value);
        if (h != null && h > 0) {
          final w = (h * _baseWidth / _baseHeight).round();
          _widthController.text = '$w';
        }
      }
    });
  }

  // ---- 导出 ----

  Future<void> _export() async {
    if (_busy || _blockingError != null) return;

    // 混合模式在部分编辑器里会被忽略，每次导出 SVG 前都提示一次（可取消）。
    if (_format == ExportFormat.svg && _hasNonNormalBlend) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('混合模式提示'),
          content: const Text(
            'SVG 的混合模式依赖 mix-blend-mode，部分编辑器（如旧版 Illustrator）'
            '可能忽略该属性，导致外观与预览不一致。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍要导出'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final result = await _exporter.export(
        projectName: widget.project.name,
        document: widget.project.document,
        layers: widget.layers,
        activeLayerId: widget.activeLayerId,
        destination: _destination,
        options: ExportOptions(
          format: _format,
          scope: _scope,
          width: _outputWidth,
          height: _outputHeight,
          transparentBackground: _transparent,
          jpegQuality: _quality,
        ),
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocking = _blockingError;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导出')),
        body: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                _buildPreview(theme),
                const SizedBox(height: 16),
                _buildFormat(theme),
                _buildScope(theme),
                if (_format != ExportFormat.svg) _buildSize(theme),
                _buildOptions(theme),
                _buildLocation(theme),
                if (_hint(theme) != null) _hint(theme)!,
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
            if (_busy)
              ColoredBox(
                color: theme.colorScheme.scrim.withValues(alpha: 0.35),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                Expanded(
                  // 按钮不可用时优先显示原因，否则用户只看到一个灰按钮。
                  child: Text(
                    blocking ??
                        (_format == ExportFormat.svg
                            ? '矢量输出'
                            : '$_outputWidth × $_outputHeight px'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: blocking == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ),
                FilledButton.icon(
                  key: const Key('export-submit'),
                  onPressed:
                      blocking == null && !_busy ? _export : null,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导出'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final document = widget.project.document;
    return AspectRatio(
      aspectRatio: document.aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomPaint(
          painter: _ExportPreviewPainter(
            layers: _selectedLayers,
            paperColor: Color(document.backgroundArgb),
            transparent: _format != ExportFormat.jpg && _transparent,
          ),
        ),
      ),
    );
  }

  Widget _buildFormat(ThemeData theme) {
    return SectionCard(
      title: '格式',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final format in ExportFormat.values)
            _formatChip(theme, format),
        ],
      ),
    );
  }

  Widget _formatChip(ThemeData theme, ExportFormat format) {
    final label = switch (format) {
      ExportFormat.png => 'PNG',
      ExportFormat.jpg => 'JPG',
      ExportFormat.svg => 'SVG',
    };
    final enabled = format != ExportFormat.svg || _canExportSvg;

    return ChoiceChip(
      label: Text(label),
      selected: _format == format,
      onSelected: enabled ? (_) => _onFormatChanged(format) : null,
      avatar: enabled ? null : const Icon(Icons.lock_outline, size: 14),
    );
  }

  Widget _buildScope(ThemeData theme) {
    final visibleLayers = widget.layers
        .where((layer) => layer.visible && layer.strokes.isNotEmpty)
        .length;

    return SectionCard(
      title: '范围',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<ExportScope>(
            segments: const <ButtonSegment<ExportScope>>[
              ButtonSegment(value: ExportScope.document, label: Text('整幅')),
              ButtonSegment(
                value: ExportScope.activeLayer,
                label: Text('当前图层'),
              ),
            ],
            selected: <ExportScope>{_scope},
            showSelectedIcon: false,
            onSelectionChanged: visibleLayers > 1
                ? (selection) => setState(() => _scope = selection.first)
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            '隐藏图层不会导出',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSize(ThemeData theme) {
    return SectionCard(
      title: '尺寸',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _SizePreset.values)
                ChoiceChip(
                  label: Text(_presetLabel(preset)),
                  selected: _preset == preset,
                  onSelected: _presetAllowed(preset)
                      ? (_) => _onPresetChanged(preset)
                      : null,
                ),
            ],
          ),
          if (_preset == _SizePreset.custom) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _numberField(
                    key: const Key('export-width'),
                    controller: _widthController,
                    label: '宽',
                    onChanged: _onWidthChanged,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('×'),
                ),
                Expanded(
                  child: _numberField(
                    key: const Key('export-height'),
                    controller: _heightController,
                    label: '高',
                    onChanged: _onHeightChanged,
                  ),
                ),
              ],
            ),
            _switchRow(
              title: '锁定比例',
              value: _lockAspect,
              onChanged: (value) => setState(() => _lockAspect = value),
            ),
          ],
        ],
      ),
    );
  }

  /// 保存位置：默认走平台目录，也可以交给系统文件管理器挑一个。
  ///
  /// 不再提供手填路径：桌面端与 Android 的目录形态不同（路径 vs SAF 树），
  /// 手填只对前者成立，且拼错的代价是导出失败。选择器返回什么就存什么。
  Widget _buildLocation(ThemeData theme) {
    final custom = _destination.isCustom;

    return SectionCard(
      title: '保存位置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  custom ? Icons.folder_outlined : Icons.download_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  custom ? _destination.description : (_defaultDir ?? '默认位置'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('export-directory-pick'),
                onPressed: _picking || _busy ? null : _pickDirectory,
                icon: _picking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(custom ? '重新选择目录' : '选择目录…'),
              ),
              if (custom)
                TextButton(
                  key: const Key('export-directory-reset'),
                  onPressed: _picking || _busy ? null : _resetDestination,
                  child: const Text('用默认'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _presetLabel(_SizePreset preset) => switch (preset) {
        _SizePreset.x1 => '1x',
        _SizePreset.x2 => '2x',
        _SizePreset.x3 => '3x',
        _SizePreset.custom => '自定义',
      };

  Widget _numberField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: label,
        suffixText: 'px',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    );
  }

  /// 开关行。
  ///
  /// 不用 `SwitchListTile`：它需要最近的 Material 祖先来绘制水波纹，而分组卡片
  /// 是一个带背景的 DecoratedBox，会触发框架的可见性断言。这里用普通 Row。
  Widget _switchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _buildOptions(ThemeData theme) {
    return SectionCard(
      title: '选项',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_format == ExportFormat.png)
            _switchRow(
              title: '透明背景',
              subtitle: '关闭后以文档底色填充',
              value: _transparent,
              onChanged: (value) => setState(() => _transparent = value),
            ),
          if (_format == ExportFormat.jpg) ...[
            Row(
              children: [
                Text('质量', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  '$_quality',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('export-quality'),
              value: _quality.toDouble(),
              min: 60,
              max: 100,
              divisions: 40,
              label: '$_quality',
              onChanged: (value) => setState(() => _quality = value.round()),
            ),
          ],
          if (_format == ExportFormat.svg)
            Text(
              '矢量输出，与分辨率无关；图层结构会保留为分组。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  /// 提示区：按当前状态给出最相关的一条提示。
  Widget? _hint(ThemeData theme) {
    String? message;
    if (!_canExportSvg) {
      message = '工程包含位图内容，无法导出为纯矢量 SVG。';
    } else if (_format == ExportFormat.jpg) {
      message = 'JPG 不支持透明，将以文档底色填充。';
    } else if (_format == ExportFormat.svg && _hasNonNormalBlend) {
      message = '部分编辑器可能忽略 SVG 的混合模式。';
    }
    if (message == null) return null;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 导出预览：与最终光栅化共用同一套绘制逻辑，因此预览即所得。
class _ExportPreviewPainter extends CustomPainter {
  const _ExportPreviewPainter({
    required this.layers,
    required this.paperColor,
    required this.transparent,
  });

  final List<DrawingLayer> layers;
  final Color paperColor;
  final bool transparent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    paintDocument(
      canvas,
      Offset.zero & size,
      paperColor,
      layers,
      drawPaper: !transparent,
    );
  }

  @override
  bool shouldRepaint(covariant _ExportPreviewPainter oldDelegate) =>
      !identical(oldDelegate.layers, layers) ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.transparent != transparent;
}
