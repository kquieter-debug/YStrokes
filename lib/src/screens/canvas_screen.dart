import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../rust/api.dart' as rust;
import '../services/canvas_geometry.dart';
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/project_store.dart';
import '../services/stroke_smoother.dart';

/// 工程画板。
///
/// 布局自下而上分为三层，这是本文件的核心结构：
///
/// 1. **工作台**（pasteboard）：铺满可用区域的底色，表示「文档之外」。
/// 2. **文档**（document）：按工程固有比例居中的纸面，笔画只绘制在这里。
///    其矩形只由「文档比例」与「可用区域」决定，与工具栏无关。
/// 3. **工具面板**：悬浮在屏幕右侧的覆盖层，**不参与布局**，因此无论它多宽、
///    怎样随屏幕自适应，都不会挤压或缩放文档。
///
/// 屏幕尺寸变化（旋转、分屏、折叠）只会改变工作台大小与文档的显示比例，
/// 不会改变文档自身的形状，因此笔画不会因设备变化而拉伸。
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.project, this.documentStore});

  final DrawingProject project;

  /// 笔画存储实现。
  ///
  /// 生产环境留空，走默认的「应用文档目录」；测试可注入以临时目录为根的实例，
  /// 从而无需 path_provider 插件即可验证界面行为。
  final DocumentStore? documentStore;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> with WidgetsBindingObserver {
  final DrawingEngine _engine = DrawingEngine();
  late final DocumentStore _documentStore =
      widget.documentStore ?? DocumentStore();
  final ProjectStore _projectStore = ProjectStore();

  /// 当前画笔颜色（ARGB）。
  Color _color = const Color(0xFF000000);

  /// 当前笔宽在 [_widthRatios] 中的下标。
  int _widthIndex = 1;

  /// 当前笔画的增量平滑器；为空表示没有正在绘制的笔画。
  StrokeSmoother? _smoother;

  /// 活动笔画的版本号：点列是原地修改的，painter 只能靠它判断变化。
  int _activeRevision = 0;

  /// 正在绘制中的点（已平滑，归一化坐标）。
  List<rust.StrokePoint> get _activePoints =>
      _smoother?.points ?? const <rust.StrokePoint>[];

  /// 当前被跟踪的指针 id（忽略第二根手指）。
  int? _activePointer;

  /// 当前笔画起点时间（用于计算点间时间戳）。
  int _strokeStartMs = 0;

  /// 文档在屏幕上的实际矩形（逻辑像素），所有坐标换算都以它为准。
  Rect _documentRect = Rect.zero;

  /// 已完成笔画的渲染缓存。
  ui.Picture? _committedPicture;
  int _pictureRevision = -1;
  Rect _pictureRect = Rect.zero;

  bool _loading = true;
  String? _loadWarning;
  String? _saveError;

  bool _dirty = false;
  bool _saving = false;
  Timer? _saveTimer;

  /// 自动保存节流窗口：抬笔后静置该时长才落盘，避免每笔都写文件。
  static const Duration _saveDebounce = Duration(milliseconds: 800);

  static const List<Color> _palette = [
    Color(0xFF000000), // 黑
    Color(0xFFEF4444), // 红
    Color(0xFF3B82F6), // 蓝
    Color(0xFF22C55E), // 绿
    Color(0xFFF97316), // 橙
    Color(0xFFFFFFFF), // 白
  ];

  /// 笔宽档位：归一化比例（相对文档短边），对应 400dp 文档上的 2/4/8/16dp。
  static const List<double> _widthRatios = [0.005, 0.01, 0.02, 0.04];

  double get _widthRatio => _widthRatios[_widthIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDocument();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    // dispose 无法 await：保存只依赖文件系统，不需要 Widget 存活。
    unawaited(_flushSave());
    _committedPicture?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android 可能在后台静默回收进程，退到后台是最后的落盘机会。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_flushSave());
    }
  }

  // ---- 文档生命周期 ----

  Future<void> _loadDocument() async {
    try {
      final stored = await _documentStore.loadStrokes(widget.project.id);
      if (!mounted) return;
      _engine.load(stored.strokes);
      setState(() {
        _loading = false;
        _loadWarning = stored.error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadWarning = '读取工程失败：$error';
      });
    }
  }

  void _scheduleSave() {
    if (!mounted) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_flushSave()));
  }

  Future<void> _flushSave() async {
    if (!_dirty || _saving) return;
    _saving = true;
    _dirty = false;
    final revisionAtStart = _engine.revision;

    try {
      await _documentStore.saveStrokes(widget.project.id, _engine.strokes);
      await _projectStore.touchProject(widget.project.id);
      if (mounted && _saveError != null) {
        setState(() => _saveError = null);
      }
    } catch (error) {
      _dirty = true;
      if (mounted) {
        setState(() => _saveError = '保存失败：$error');
      }
    } finally {
      _saving = false;
    }

    // 落盘期间又有新改动：这一版还没写下去，补一次。
    if (_engine.revision != revisionAtStart) {
      _scheduleSave();
    }
  }

  /// 内容变化后的统一收尾：刷新界面 + 触发保存。
  void _onDocumentChanged() {
    setState(() {});
    _scheduleSave();
  }

  // ---- 指针采集 ----

  void _onPointerDown(PointerDownEvent e) {
    if (_loading || _activePointer != null) return; // 已有一根手指在绘制
    if (_documentRect.isEmpty) return;

    _activePointer = e.pointer;
    _strokeStartMs = DateTime.now().millisecondsSinceEpoch;

    final smoother = StrokeSmoother(shortestSide: _documentRect.shortestSide);
    smoother.add(_toNormalized(e.localPosition, e.pressure));
    setState(() {
      _smoother = smoother;
      _activeRevision++;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    final smoother = _smoother;
    if (e.pointer != _activePointer || smoother == null) return;
    smoother.add(_toNormalized(e.localPosition, e.pressure));
    setState(() => _activeRevision++);
  }

  /// 抬手即提交。
  ///
  /// 平滑已在采集阶段随点完成，此处不等待任何异步操作：清空活动层与写入新笔画
  /// 发生在同一次 setState 里，因此不会出现「笔画先消失一帧、再带着新形状出现」。
  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    final smoother = _smoother;
    if (smoother == null) {
      setState(() => _smoother = null);
      return;
    }

    final points = smoother.finish();
    if (points.isEmpty) {
      setState(() {
        _smoother = null;
        _activeRevision++;
      });
      return;
    }

    setState(() {
      _smoother = null;
      _activeRevision++;
      _engine.addStroke(
        points,
        color: _color.toARGB32(),
        widthRatio: _widthRatio,
      );
    });
    _scheduleSave();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    // 手势被系统打断（来电、返回手势等）时丢弃这一笔的半成品。
    if (e.pointer != _activePointer) return;
    setState(() {
      _activePointer = null;
      _smoother = null;
      _activeRevision++;
    });
  }

  /// 把指针位置转换为文档内的归一化坐标（0~1）。
  ///
  /// 基准是 [_documentRect] 而非整个画布层：文档之外的空白区域会被夹到边缘，
  /// 否则笔画会跑到纸面之外。
  rust.StrokePoint _toNormalized(Offset local, double pressure) {
    final rect = _documentRect;
    final x = rect.width <= 0
        ? 0.0
        : ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = rect.height <= 0
        ? 0.0
        : ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    final ms = DateTime.now().millisecondsSinceEpoch - _strokeStartMs;
    return rust.StrokePoint(
      x: x,
      y: y,
      pressure: pressure.clamp(0.0, 1.0),
      timestampMs: ms,
    );
  }

  // ---- 工具栏动作 ----

  void _undo() {
    if (_engine.undo()) _onDocumentChanged();
  }

  void _redo() {
    if (_engine.redo()) _onDocumentChanged();
  }

  void _clear() {
    if (!_engine.clear()) return;
    _onDocumentChanged();
    // 清空可撤销，因此不做二次确认弹窗，只给一次可感知的提示。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已清空画布'),
          action: SnackBarAction(label: '撤销', onPressed: _undo),
        ),
      );
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        actions: [
          IconButton(
            onPressed: _engine.canUndo ? _undo : null,
            tooltip: '撤销',
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            onPressed: _engine.canRedo ? _redo : null,
            tooltip: '重做',
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            onPressed: _engine.isEmpty ? null : _clear,
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                // 画布层铺满，工具面板浮在上面且不参与布局。
                Positioned.fill(child: _buildCanvas()),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_loadWarning != null)
                        _buildNotice(_loadWarning!, isError: false),
                      if (_saveError != null)
                        _buildNotice(_saveError!, isError: true),
                    ],
                  ),
                ),
                _buildBrushPanel(),
              ],
            ),
    );
  }

  Widget _buildNotice(String message, {required bool isError}) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return Material(
      color: color.withValues(alpha: 0.16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '关闭提示',
              onPressed: () => setState(() {
                if (isError) {
                  _saveError = null;
                } else {
                  _loadWarning = null;
                }
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具面板：贴右缘、竖向排列、默认两列。
  ///
  /// 尺寸随屏幕短边自适应（见 [_ToolbarMetrics]），但始终是覆盖层——
  /// 面板变宽或变窄都不会改变下方文档的矩形。
  Widget _buildBrushPanel() {
    final metrics = _ToolbarMetrics.fromScreen(MediaQuery.sizeOf(context));
    return Positioned(
      top: 0,
      bottom: 0,
      right: metrics.margin,
      child: Center(
        child: _BrushPanel(
          metrics: metrics,
          palette: _palette,
          widthRatios: _widthRatios,
          selectedColor: _color,
          widthIndex: _widthIndex,
          onSelectColor: (color) => setState(() => _color = color),
          onSelectWidth: (index) => setState(() => _widthIndex = index),
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    final theme = Theme.of(context);
    final document = widget.project.document;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = fitDocumentRect(available, document.aspectRatio);
        _documentRect = rect;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 工作台：文档之外的区域。
              ColoredBox(color: theme.colorScheme.surfaceContainerLowest),
              // 文档：按工程规格居中的纸面，底色来自创建时选择的背景。
              if (!rect.isEmpty)
                Positioned.fromRect(
                  rect: rect,
                  child: ColoredBox(color: Color(document.backgroundArgb)),
                ),
              CustomPaint(painter: _CommittedPainter(_ensurePicture(rect))),
              CustomPaint(
                painter: _ActiveStrokePainter(
                  points: _activePoints,
                  revision: _activeRevision,
                  color: _color.toARGB32(),
                  width: _widthRatio * rect.shortestSide,
                  rect: rect,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 取（或重建）已完成笔画的渲染缓存。
  ///
  /// 缓存键为「笔画版本 + 文档矩形」：旋转或分屏会改变矩形并触发一次重建，
  /// 之后恢复稳定；绘制过程中矩形不变，故不会重复重建。
  ui.Picture _ensurePicture(Rect rect) {
    final cached = _committedPicture;
    if (cached != null &&
        _pictureRevision == _engine.revision &&
        _pictureRect == rect) {
      return cached;
    }
    cached?.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (!rect.isEmpty) {
      for (final stroke in _engine.strokes) {
        _paintStroke(
          canvas,
          rect,
          stroke.points,
          stroke.color,
          stroke.widthInPixels(rect.shortestSide),
        );
      }
    }
    final picture = recorder.endRecording();
    _committedPicture = picture;
    _pictureRevision = _engine.revision;
    _pictureRect = rect;
    return picture;
  }
}

/// 把归一化笔画渲染到文档矩形内，采样点之间以二次贝塞尔平滑连接。
///
/// 直接 `lineTo` 会让快速运笔出现肉眼可见的折角；这里以相邻采样点的中值作为
/// 曲线端点、原始点作为控制点，得到与笔迹走向贴合且切线连续的路径。
void _paintStroke(
  Canvas canvas,
  Rect rect,
  List<rust.StrokePoint> points,
  int color,
  double width,
) {
  if (points.isEmpty || rect.isEmpty) return;

  Offset toOffset(rust.StrokePoint p) =>
      Offset(rect.left + p.x * rect.width, rect.top + p.y * rect.height);

  final strokePaint = Paint()
    ..color = Color(color)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  if (points.length == 1) {
    // 单点：轻点画布应留下一个圆点，而不是什么都没有。
    canvas.drawCircle(
      toOffset(points.first),
      width / 2,
      Paint()
        ..color = Color(color)
        ..isAntiAlias = true,
    );
    return;
  }

  final path = Path();
  final first = toOffset(points.first);
  path.moveTo(first.dx, first.dy);

  for (var i = 1; i < points.length - 1; i++) {
    final current = toOffset(points[i]);
    final next = toOffset(points[i + 1]);
    final mid = Offset(
      (current.dx + next.dx) / 2,
      (current.dy + next.dy) / 2,
    );
    path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
  }

  final last = toOffset(points.last);
  path.lineTo(last.dx, last.dy);
  canvas.drawPath(path, strokePaint);
}

/// 已完成笔画：直接复用烘焙好的 [ui.Picture]。
class _CommittedPainter extends CustomPainter {
  const _CommittedPainter(this.picture);

  final ui.Picture picture;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(picture);

  @override
  bool shouldRepaint(covariant _CommittedPainter oldDelegate) =>
      oldDelegate.picture != picture;
}

/// 正在绘制的一笔：每帧只重绘这一条路径。
class _ActiveStrokePainter extends CustomPainter {
  const _ActiveStrokePainter({
    required this.points,
    required this.revision,
    required this.color,
    required this.width,
    required this.rect,
  });

  final List<rust.StrokePoint> points;
  final int revision;
  final int color;
  final double width;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintStroke(canvas, rect, points, color, width);

  @override
  bool shouldRepaint(covariant _ActiveStrokePainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.rect != rect ||
      !identical(oldDelegate.points, points);
}

/// 工具面板的尺寸方案：随屏幕短边自适应。
///
/// 取短边而非宽度，是为了让竖屏与横屏得到一致的触控密度。上下限的作用：
/// 下限保证热区不低于 34dp（再小难以点中），上限避免在平板上出现巨型色块。
class _ToolbarMetrics {
  const _ToolbarMetrics({
    required this.cell,
    required this.gap,
    required this.padding,
    required this.margin,
    required this.radius,
  });

  factory _ToolbarMetrics.fromScreen(Size screen) {
    final shortest = screen.shortestSide;
    final cell = (shortest * 0.095).clamp(34.0, 48.0);
    final gap = (cell * 0.18).clamp(6.0, 10.0);
    final padding = (cell * 0.26).clamp(8.0, 14.0);
    final margin = (shortest * 0.022).clamp(8.0, 20.0);
    return _ToolbarMetrics(
      cell: cell,
      gap: gap,
      padding: padding,
      margin: margin,
      radius: (cell * 0.36).clamp(12.0, 18.0),
    );
  }

  /// 单个触控格边长。
  final double cell;

  /// 格间距。
  final double gap;

  /// 面板内边距。
  final double padding;

  /// 面板与屏幕边缘的距离。
  final double margin;

  /// 面板圆角。
  final double radius;
}

/// 悬浮笔刷面板：右侧竖向停靠，固定两列。
class _BrushPanel extends StatelessWidget {
  const _BrushPanel({
    required this.metrics,
    required this.palette,
    required this.widthRatios,
    required this.selectedColor,
    required this.widthIndex,
    required this.onSelectColor,
    required this.onSelectWidth,
  });

  final _ToolbarMetrics metrics;
  final List<Color> palette;
  final List<double> widthRatios;
  final Color selectedColor;
  final int widthIndex;
  final ValueChanged<Color> onSelectColor;
  final ValueChanged<int> onSelectWidth;

  static const int _columns = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(metrics.radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(metrics.padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildGrid(<Widget>[
              for (final color in palette)
                _ColorCell(
                  color: color,
                  selected: color.toARGB32() == selectedColor.toARGB32(),
                  metrics: metrics,
                  onTap: () => onSelectColor(color),
                ),
            ]),
            Padding(
              padding: EdgeInsets.symmetric(vertical: metrics.gap),
              child: SizedBox(
                width: metrics.cell * _columns + metrics.gap,
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
            ),
            _buildGrid(<Widget>[
              for (var i = 0; i < widthRatios.length; i++)
                _WidthCell(
                  ratio: widthRatios[i],
                  selected: i == widthIndex,
                  metrics: metrics,
                  onTap: () => onSelectWidth(i),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 把若干格子排成固定列数的网格；末行不足时用占位补齐，保证左列对齐。
  Widget _buildGrid(List<Widget> cells) {
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += _columns) {
      final children = <Widget>[];
      for (var c = 0; c < _columns; c++) {
        if (c > 0) children.add(SizedBox(width: metrics.gap));
        final index = i + c;
        children.add(
          index < cells.length
              ? cells[index]
              : SizedBox(width: metrics.cell, height: metrics.cell),
        );
      }
      if (rows.isNotEmpty) rows.add(SizedBox(height: metrics.gap));
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: children));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// 颜色格。
class _ColorCell extends StatelessWidget {
  const _ColorCell({
    required this.color,
    required this.selected,
    required this.metrics,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final _ToolbarMetrics metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = metrics.cell * 0.66;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: metrics.cell,
        height: metrics.cell,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 笔宽格：圆点直径按真实笔宽等比缩放，选中时以主色区分。
class _WidthCell extends StatelessWidget {
  const _WidthCell({
    required this.ratio,
    required this.selected,
    required this.metrics,
    required this.onTap,
  });

  final double ratio;
  final bool selected;
  final _ToolbarMetrics metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 520 是把归一化比例放大到格内可感知尺寸的经验系数。
    final dot = (ratio * 520).clamp(4.0, metrics.cell * 0.62);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: metrics.cell,
        height: metrics.cell,
        child: Center(
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
