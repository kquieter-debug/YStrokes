import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/canvas_preset.dart';
import '../models/document_spec.dart';
import '../widgets/section_card.dart';

/// 新建文档的结果。
class NewDocumentResult {
  const NewDocumentResult({required this.name, required this.document});

  final String name;
  final DocumentSpec document;
}

/// 新建文档页：先定模板与规格，再进入画布。
///
/// 参照 Photoshop 的新建流程——用户必须先明确画布尺寸、分辨率与底色，
/// 而不是先建一个空工程再补参数。参数一旦确定，画布的固有形状随工程保存，
/// 之后不受屏幕尺寸影响。
class NewDocumentScreen extends StatefulWidget {
  const NewDocumentScreen({super.key});

  @override
  State<NewDocumentScreen> createState() => _NewDocumentScreenState();
}

class _NewDocumentScreenState extends State<NewDocumentScreen> {
  static const int _minPx = 16;
  static const int _maxPx = 12000;
  static const double _maxDpi = 1200;

  static const List<_PaperOption> _papers = <_PaperOption>[
    _PaperOption('白', 0xFFFFFFFF),
    _PaperOption('米白', 0xFFF7F3E9),
    _PaperOption('浅灰', 0xFFE8E8EA),
    _PaperOption('深灰', 0xFF2B2B2E),
  ];

  late final TextEditingController _nameController;
  late final TextEditingController _widthController;
  late final TextEditingController _heightController;
  late final TextEditingController _dpiController;

  /// 权威值：像素尺寸与像素密度。
  int _widthPx = 1080;
  int _heightPx = 1920;
  double _dpi = 72;

  /// 输入框的显示单位。
  DocumentUnit _unit = DocumentUnit.pixel;

  int _backgroundArgb = 0xFFFFFFFF;

  /// 当前选中的预设；手动修改参数后置空。
  int? _presetIndex = 0;

  @override
  void initState() {
    super.initState();
    final preset = CanvasPreset.all.first.spec;
    _widthPx = preset.widthPx;
    _heightPx = preset.heightPx;
    _dpi = preset.dpi;

    _nameController = TextEditingController(text: '未命名-1');
    _widthController = TextEditingController();
    _heightController = TextEditingController();
    _dpiController = TextEditingController(text: _dpi.toStringAsFixed(0));
    _syncDimensionFields();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _dpiController.dispose();
    super.dispose();
  }

  // ---- 输入同步 ----

  String _format(num value) => _unit == DocumentUnit.pixel
      ? value.round().toString()
      : value.toStringAsFixed(1);

  /// 把权威值写回输入框（像素值本身不随单位变化，只改变显示）。
  void _syncDimensionFields() {
    _widthController.text =
        _format(DocumentSpec.fromPixels(_widthPx, _unit, _dpi));
    _heightController.text =
        _format(DocumentSpec.fromPixels(_heightPx, _unit, _dpi));
  }

  void _applyPreset(int index) {
    final preset = CanvasPreset.all[index];
    setState(() {
      _presetIndex = index;
      _widthPx = preset.spec.widthPx;
      _heightPx = preset.spec.heightPx;
      _dpi = preset.spec.dpi;
      _backgroundArgb = preset.spec.backgroundArgb;
      _dpiController.text = _dpi.toStringAsFixed(0);
      _syncDimensionFields();
    });
  }

  void _onDimensionChanged() {
    final width = double.tryParse(_widthController.text);
    final height = double.tryParse(_heightController.text);
    setState(() {
      if (width != null && width > 0) {
        _widthPx = DocumentSpec.toPixels(width, _unit, _dpi).round();
      }
      if (height != null && height > 0) {
        _heightPx = DocumentSpec.toPixels(height, _unit, _dpi).round();
      }
      _presetIndex = null;
    });
  }

  void _onDpiChanged() {
    final dpi = double.tryParse(_dpiController.text);
    if (dpi == null || dpi <= 0) {
      setState(() {});
      return;
    }
    setState(() {
      final width = double.tryParse(_widthController.text);
      final height = double.tryParse(_heightController.text);
      _dpi = dpi;
      // 物理单位下，用户输入的是物理尺寸：改 dpi 应保持尺寸、换算像素，
      // 而不是反过来改写用户已输入的数值（这与 Photoshop 的行为一致）。
      if (_unit != DocumentUnit.pixel) {
        if (width != null && width > 0) {
          _widthPx = DocumentSpec.toPixels(width, _unit, _dpi).round();
        }
        if (height != null && height > 0) {
          _heightPx = DocumentSpec.toPixels(height, _unit, _dpi).round();
        }
      }
      _presetIndex = null;
    });
  }

  void _onUnitChanged(DocumentUnit unit) {
    setState(() {
      _unit = unit;
      _syncDimensionFields();
    });
  }

  // ---- 校验与提交 ----

  String? get _error {
    if (_nameController.text.trim().isEmpty) {
      return '请填写工程名称';
    }
    final width = double.tryParse(_widthController.text);
    final height = double.tryParse(_heightController.text);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return '请填写有效的画布宽度与高度';
    }
    if (_widthPx < _minPx ||
        _widthPx > _maxPx ||
        _heightPx < _minPx ||
        _heightPx > _maxPx) {
      return '画布宽度与高度需在 $_minPx ~ $_maxPx 像素之间';
    }
    final dpi = double.tryParse(_dpiController.text);
    if (dpi == null || dpi < 1 || dpi > _maxDpi) {
      return '分辨率需在 1 ~ ${_maxDpi.toStringAsFixed(0)} ppi 之间';
    }
    return null;
  }

  void _submit() {
    if (_error != null) return;
    Navigator.of(context).pop(
      NewDocumentResult(
        name: _nameController.text.trim(),
        document: DocumentSpec(
          widthPx: _widthPx,
          heightPx: _heightPx,
          dpi: _dpi,
          backgroundArgb: _backgroundArgb,
        ),
      ),
    );
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text('新建文档')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  TextField(
                    key: const Key('doc-name'),
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      hintText: '例如：速写练习',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 20),
                  Text('模板', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < CanvasPreset.all.length; i++)
                        ChoiceChip(
                          label: Text(CanvasPreset.all[i].name),
                          selected: _presetIndex == i,
                          onSelected: (_) => _applyPreset(i),
                        ),
                    ],
                  ),
                  if (_presetIndex != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      CanvasPreset.all[_presetIndex!].summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SectionCard(
                    title: '画布尺寸',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _NumberField(
                                fieldKey: const Key('doc-width'),
                                controller: _widthController,
                                label: '宽度',
                                suffix: _unit.suffix,
                                onChanged: _onDimensionChanged,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Text('×'),
                            ),
                            Expanded(
                              child: _NumberField(
                                fieldKey: const Key('doc-height'),
                                controller: _heightController,
                                label: '高度',
                                suffix: _unit.suffix,
                                onChanged: _onDimensionChanged,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<DocumentUnit>(
                          segments: [
                            for (final unit in DocumentUnit.values)
                              ButtonSegment<DocumentUnit>(
                                value: unit,
                                label: Text(unit.label),
                              ),
                          ],
                          selected: <DocumentUnit>{_unit},
                          showSelectedIcon: false,
                          onSelectionChanged: (selection) =>
                              _onUnitChanged(selection.first),
                        ),
                        const SizedBox(height: 14),
                        _NumberField(
                          fieldKey: const Key('doc-dpi'),
                          controller: _dpiController,
                          label: '分辨率',
                          suffix: 'ppi',
                          integerOnly: true,
                          onChanged: _onDpiChanged,
                        ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: '背景',
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final paper in _papers)
                          _PaperSwatch(
                            paper: paper,
                            selected: paper.argb == _backgroundArgb,
                            onTap: () =>
                                setState(() => _backgroundArgb = paper.argb),
                          ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: '摘要',
                    child: Text(
                      '$_widthPx × $_heightPx px · ${_dpi.toStringAsFixed(0)} ppi\n'
                      '物理尺寸约 ${DocumentSpec.fromPixels(_widthPx, DocumentUnit.millimeter, _dpi).toStringAsFixed(1)} × '
                      '${DocumentSpec.fromPixels(_heightPx, DocumentUnit.millimeter, _dpi).toStringAsFixed(1)} mm',
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 16,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              error,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('取消'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: const Key('doc-create'),
                      onPressed: error == null ? _submit : null,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('创建画布'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数字输入框：只接受数字与小数点。
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.suffix,
    required this.onChanged,
    this.integerOnly = false,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String suffix;
  final VoidCallback onChanged;
  final bool integerOnly;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(
          integerOnly ? RegExp(r'[0-9]') : RegExp(r'[0-9.]'),
        ),
      ],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

class _PaperOption {
  const _PaperOption(this.label, this.argb);

  final String label;
  final int argb;
}

class _PaperSwatch extends StatelessWidget {
  const _PaperSwatch({
    required this.paper,
    required this.selected,
    required this.onTap,
  });

  final _PaperOption paper;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Color(paper.argb),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(paper.label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
