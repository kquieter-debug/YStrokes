import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../rust/api.dart' as rust;
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/project_store.dart';
import '../services/stroke_smoother.dart';

/// 工程画板：采集指针事件 → 交给 Rust 平滑/简化 → 渲染为笔触。
///
/// 职责：
/// - 绘制会话（交互 → 引擎 → 渲染）
/// - 文档生命周期（进入载入、改动后节流保存、退到后台立即落盘）
///
/// 渲染策略：已完成的笔画烘焙为 [ui.Picture] 缓存，绘制过程中只重绘「正在画的
/// 那一笔」。这样每帧成本与总笔画数解耦，长时间创作也不会线性掉帧。
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.project});

  final DrawingProject project;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> with WidgetsBindingObserver {
  final DrawingEngine _engine = DrawingEngine();
  final DocumentStore _documentStore = DocumentStore();
  final ProjectStore _projectStore = ProjectStore();

  /// 当前画笔颜色（ARGB）。
  Color _color = const Color(0xFF000000);

  /// 当前笔宽在 [_widthRatios] 中的下标。
  int _widthIndex = 1;

  /// 当前笔画的增量平滑器；为空表示没有正在绘制的笔画。
  StrokeSmoother? _smoother;

  /// 活动笔画的版本号：点列是原地修改的，painter 只能靠它判断变化。
  int _activeRevision = 0;

  /// 正在绘制中的点（已平滑，归一化坐标），直接用于渲染。
  List<rust.StrokePoint> get _activePoints =>
      _smoother?.points ?? const <rust.StrokePoint>[];

  /// 当前被跟踪的指针 id（忽略第二根手指）。
  int? _activePointer;

  /// 当前笔画起点时间（用于计算点间时间戳）。
  int _strokeStartMs = 0;

  /// 画布逻辑尺寸，用于坐标归一化/还原。
  Size _canvasSize = Size.zero;

  /// 已完成笔画的渲染缓存。
  ui.Picture? _committedPicture;
  int _pictureRevision = -1;
  Size _pictureSize = Size.zero;

  bool _loading = true;
  String? _loadWarning;
  String? _saveError;

  bool _dirty = false;
  bool _saving = false;
  Timer? _saveTimer;

  /// 自动保存节流窗口：抬笔后静置该时长才落盘，避免每笔都写文件。
  static const Duration _saveDebounce = Duration(milliseconds: 800);

  static const Color _paperColor = Color(0xFFFFFFFF);

  static const List<Color> _palette = [
    Color(0xFF000000), // 黑
    Color(0xFFEF4444), // 红
    Color(0xFF3B82F6), // 蓝
    Color(0xFF22C55E), // 绿
    Color(0xFFF97316), // 橙
    Color(0xFFFFFFFF), // 白
  ];

  /// 笔宽档位：归一化比例（相对画布短边），对应 400dp 画布上的 2/4/8/16dp。
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
    _activePointer = e.pointer;
    _strokeStartMs = DateTime.now().millisecondsSinceEpoch;

    final smoother = StrokeSmoother(shortestSide: _canvasSize.shortestSide);
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

  /// 把指针位置转换为归一化采样点（坐标 0~1，压力 0~1）。
  rust.StrokePoint _toNormalized(Offset local, double pressure) {
    final w = _canvasSize.width;
    final h = _canvasSize.height;
    final x = w <= 0 ? 0.0 : (local.dx / w).clamp(0.0, 1.0);
    final y = h <= 0 ? 0.0 : (local.dy / h).clamp(0.0, 1.0);
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
          : Column(
              children: [
                _buildToolbar(),
                if (_loadWarning != null)
                  _buildNotice(_loadWarning!, isError: false),
                if (_saveError != null) _buildNotice(_saveError!, isError: true),
                Expanded(child: _buildCanvas()),
              ],
            ),
    );
  }

  Widget _buildNotice(String message, {required bool isError}) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return Material(
      color: color.withValues(alpha: 0.12),
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

  Widget _buildToolbar() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ..._palette.map(_buildColorSwatch),
            const SizedBox(width: 12),
            Container(
              width: 1,
              height: 24,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(width: 12),
            ...List.generate(_widthRatios.length, _buildWidthDot),
          ],
        ),
      ),
    );
  }

  Widget _buildColorSwatch(Color color) {
    final selected = color.toARGB32() == _color.toARGB32();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => setState(() => _color = color),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWidthDot(int index) {
    final selected = index == _widthIndex;
    // 视觉预览：把归一化比例放大到 30px 区域内可感知的尺寸。
    final dotSize = (_widthRatios[index] * 600).clamp(3.0, 24.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: InkWell(
        onTap: () => setState(() => _widthIndex = index),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _canvasSize = size;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: ColoredBox(
            color: _paperColor,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CommittedPainter(_ensurePicture(size))),
                CustomPaint(
                  painter: _ActiveStrokePainter(
                    points: _activePoints,
                    revision: _activeRevision,
                    color: _color.toARGB32(),
                    width: _widthRatio * size.shortestSide,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 取（或重建）已完成笔画的渲染缓存。
  ///
  /// 仅在笔画版本或画布尺寸变化时重建，避免每帧为全部笔画重建路径。
  ui.Picture _ensurePicture(Size size) {
    final cached = _committedPicture;
    if (cached != null &&
        _pictureRevision == _engine.revision &&
        _pictureSize == size) {
      return cached;
    }
    cached?.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final stroke in _engine.strokes) {
      _paintStroke(
        canvas,
        size,
        stroke.points,
        stroke.color,
        stroke.widthInPixels(size.shortestSide),
      );
    }
    final picture = recorder.endRecording();
    _committedPicture = picture;
    _pictureRevision = _engine.revision;
    _pictureSize = size;
    return picture;
  }
}

/// 把归一化笔画渲染到画布，采样点之间以二次贝塞尔平滑连接。
///
/// 直接 `lineTo` 会让快速运笔出现肉眼可见的折角；这里以相邻采样点的中值作为
/// 曲线端点、原始点作为控制点，得到与笔迹走向贴合且切线连续的路径。
void _paintStroke(
  Canvas canvas,
  Size size,
  List<rust.StrokePoint> points,
  int color,
  double width,
) {
  if (points.isEmpty) return;

  Offset toOffset(rust.StrokePoint p) =>
      Offset(p.x * size.width, p.y * size.height);

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
  });

  final List<rust.StrokePoint> points;
  final int revision;
  final int color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintStroke(canvas, size, points, color, width);

  @override
  bool shouldRepaint(covariant _ActiveStrokePainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      !identical(oldDelegate.points, points);
}
