import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../models/tool_settings.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';
import '../services/canvas_geometry.dart';
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/project_store.dart';
import '../services/stroke_smoother.dart';
import '../widgets/app_icon.dart';
import '../widgets/tool_settings_sheet.dart';

/// 工程画板。
///
/// 布局自下而上分为三层，这是本文件的核心结构：
///
/// 1. **工作台**（pasteboard）：铺满可用区域的底色，表示「文档之外」。
/// 2. **文档**（document）：按工程固有比例居中的纸面，笔画只绘制在这里。
///    其矩形只由「文档比例」与「可用区域」决定，与工具栏无关。
/// 3. **工具面板**：悬浮在屏幕左侧的覆盖层，**不参与布局**，因此无论它多宽、
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

class _CanvasScreenState extends State<CanvasScreen>
    with WidgetsBindingObserver {
  final DrawingEngine _engine = DrawingEngine();
  late final DocumentStore _documentStore =
      widget.documentStore ?? DocumentStore();
  final ProjectStore _projectStore = ProjectStore();

  /// 当前工具。
  ToolKind _tool = ToolKind.brush;

  /// 各工具各自的参数。切回某工具时，它上次用的颜色与笔宽仍在。
  final Map<ToolKind, ToolSettings> _settings = <ToolKind, ToolSettings>{
    ToolKind.brush: const ToolSettings(
      color: Color(0xFF000000),
      widthRatio: 0.01,
    ),
    // 橡皮默认比画笔粗一些：擦除时更省力，也需要更明显的视觉反馈。
    ToolKind.eraser: const ToolSettings(
      color: Color(0xFF000000),
      widthRatio: 0.03,
    ),
  };

  ToolSettings get _activeSettings => _settings[_tool]!;

  /// 各工具的行为参数，进入画板时从 Rust 读取一次并缓存。
  ///
  /// Rust 是工具参数的单一事实来源；读取失败（例如单元测试环境未初始化 FFI）
  /// 时回落到 [_fallbackProfiles]，保证画板仍可用。
  Map<ToolKind, ToolProfile> _profiles = _fallbackProfiles;

  static const Map<ToolKind, ToolProfile> _fallbackProfiles =
      <ToolKind, ToolProfile>{
    ToolKind.brush: ToolProfile(
      smoothWindow: 5,
      simplifyTolerance: 0.002,
      erases: false,
    ),
    ToolKind.eraser: ToolProfile(
      smoothWindow: 3,
      simplifyTolerance: 0.001,
      erases: true,
    ),
  };

  ToolProfile get _profile => _profiles[_tool] ?? _fallbackProfiles[_tool]!;

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

  /// 画板私有的 SnackBar 宿主。
  ///
  /// 默认的 `ScaffoldMessenger` 挂在 MaterialApp 上，提示会跨路由存活——
  /// 在画布里弹出的「已清空画布」退回主界面后仍留在底部。这里为画板建一个局部
  /// messenger，随路由一起销毁，从结构上保证提示不外溢。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool _loading = true;
  String? _loadWarning;
  String? _saveError;

  bool _dirty = false;
  bool _saving = false;
  Timer? _saveTimer;

  /// 缩略图生成中的标记：避免上一次还没画完就又排一次。
  bool _thumbnailBusy = false;

  /// 缩略图长边上限（像素）。列表卡片不大，320 足够清晰且体积可控。
  static const double _thumbnailMaxSide = 320;

  /// 自动保存节流窗口：抬笔后静置该时长才落盘，避免每笔都写文件。
  static const Duration _saveDebounce = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDocument();
    _loadToolProfiles();
  }

  /// 从 Rust 读取工具参数；失败时保留 [_fallbackProfiles]。
  Future<void> _loadToolProfiles() async {
    try {
      final loaded = <ToolKind, ToolProfile>{};
      for (final tool in ToolKind.values) {
        loaded[tool] = await toolProfile(tool: tool);
      }
      if (!mounted) return;
      setState(() => _profiles = loaded);
    } catch (_) {
      // Rust 未初始化或调用失败：沿用内置默认值，画板照常可用。
    }
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
      // 缩略图与保存解耦：算完再写，不阻塞落盘主流程。
      unawaited(_refreshThumbnail());
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

  // ---- 缩略图 ----

  /// 重新生成工程缩略图。
  ///
  /// 只服务于列表预览，任何失败都不应影响作品本身，因此整体吞掉异常；
  /// 同一时刻只允许一个任务，避免快速连笔时堆积。
  Future<void> _refreshThumbnail() async {
    if (_thumbnailBusy) return;
    _thumbnailBusy = true;
    try {
      final bytes = await _renderThumbnailPng();
      if (bytes != null) {
        await _documentStore.saveThumbnail(widget.project.id, bytes);
      }
    } catch (_) {
      // 忽略：缩略图不是关键路径。
    } finally {
      _thumbnailBusy = false;
    }
  }

  /// 把当前文档渲染成 PNG 字节。
  ///
  /// 按文档长边缩放到 [_thumbnailMaxSide]，重绘全部笔画（含擦除），
  /// 因此缩略图与画板所见一致。
  Future<Uint8List?> _renderThumbnailPng() async {
    final document = widget.project.document;
    final longSide = math.max(document.widthPx, document.heightPx);
    if (longSide <= 0) return null;

    final scale = _thumbnailMaxSide / longSide;
    final width = math.max(1, (document.widthPx * scale).round());
    final height = math.max(1, (document.heightPx * scale).round());
    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(rect, Paint()..color = Color(document.backgroundArgb));

    final strokes = _engine.strokes;
    final layered = strokes.any((stroke) => stroke.isEraser);
    if (layered) canvas.saveLayer(rect, Paint());
    for (final stroke in strokes) {
      _paintStroke(
        canvas,
        rect,
        stroke.points,
        stroke.color,
        stroke.widthInPixels(rect.shortestSide),
        erase: stroke.isEraser,
      );
    }
    if (layered) canvas.restore();

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  // ---- 指针采集 ----

  void _onPointerDown(PointerDownEvent e) {
    if (_loading || _activePointer != null) return; // 已有一根手指在绘制
    if (_documentRect.isEmpty) return;

    _activePointer = e.pointer;
    _strokeStartMs = DateTime.now().millisecondsSinceEpoch;

    final smoother = StrokeSmoother(
      shortestSide: _documentRect.shortestSide,
      window: _profile.smoothWindow,
    );
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
        tool: _tool,
        color: _activeSettings.color.toARGB32(),
        widthRatio: _activeSettings.widthRatio,
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
    // 提示交给画板私有 messenger，退出画布时随之销毁。
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
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
    // 画板自带 messenger：其中的提示随路由一起销毁，不会溢出到主界面。
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
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
      ),
    );
  }

  Widget _buildNotice(String message, {required bool isError}) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;
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

  /// 工具面板：贴左缘、竖向排列、全部区块均为两列。
  ///
  /// 尺寸随屏幕短边自适应（见 [_ToolbarMetrics]），但始终是覆盖层——
  /// 面板变宽或变窄都不会改变下方文档的矩形。
  Widget _buildBrushPanel() {
    final metrics = _ToolbarMetrics.fromScreen(MediaQuery.sizeOf(context));
    return Positioned(
      top: 0,
      bottom: 0,
      left: metrics.margin,
      child: Center(
        child: _BrushPanel(
          metrics: metrics,
          selectedTool: _tool,
          onSelectTool: _selectTool,
          onLongPressTool: _openToolSettings,
        ),
      ),
    );
  }

  /// 选中工具。再次点按当前工具时打开它的设置——长按是显式入口，
  /// 点按已激活工具是符合直觉的隐含入口，两者都指向同一个面板。
  void _selectTool(ToolKind tool) {
    if (tool == _tool) {
      unawaited(_openToolSettings(tool));
      return;
    }
    setState(() => _tool = tool);
  }

  /// 长按工具：打开该工具的参数面板（颜色、粗细）。
  Future<void> _openToolSettings(ToolKind tool) async {
    final result = await showModalBottomSheet<ToolSettings>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ToolSettingsSheet(
        tool: tool,
        initial: _settings[tool]!,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _settings[tool] = result);
    // 保底刷新：即便设置没变，也让界面重新读取一次当前参数。
    _activeRevision++;
  }

  Widget _buildCanvas() {
    final theme = Theme.of(context);
    final document = widget.project.document;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = fitDocumentRect(available, document.aspectRatio);
        _documentRect = rect;

        final picture = _ensurePicture(rect);
        // 橡皮进行中：已完成的笔画必须并入同一个图层，实时擦除才看得见。
        final erasing = _tool == ToolKind.eraser && _smoother != null;

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
              CustomPaint(
                painter: _CommittedPainter(picture, visible: !erasing),
              ),
              CustomPaint(
                painter: _ActiveStrokePainter(
                  points: _activePoints,
                  revision: _activeRevision,
                  color: _activeSettings.color.toARGB32(),
                  width: _activeSettings.widthRatio * rect.shortestSide,
                  rect: rect,
                  erase: erasing,
                  basePicture: picture,
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
      final strokes = _engine.strokes;
      // 存在擦除笔画时必须成层：clear 混合只能作用于当前图层，
      // 直接画在画布上会把下方的纸面一起擦穿。
      final layered = strokes.any((stroke) => stroke.isEraser);
      if (layered) canvas.saveLayer(rect, Paint());
      for (final stroke in strokes) {
        _paintStroke(
          canvas,
          rect,
          stroke.points,
          stroke.color,
          stroke.widthInPixels(rect.shortestSide),
          erase: stroke.isEraser,
        );
      }
      if (layered) canvas.restore();
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
  double width, {
  bool erase = false,
}) {
  if (points.isEmpty || rect.isEmpty) return;

  Offset toOffset(rust.StrokePoint p) =>
      Offset(rect.left + p.x * rect.width, rect.top + p.y * rect.height);

  // 橡皮以「清空」方式合成：颜色无关紧要，混合模式才是关键。
  // 调用方必须先把笔画放进独立图层，否则 clear 会连纸面一起擦掉。
  final strokePaint = Paint()
    ..color = Color(color)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  if (erase) strokePaint.blendMode = BlendMode.clear;

  if (points.length == 1) {
    // 单点：轻点画布应留下一个圆点，而不是什么都没有。
    final dotPaint = Paint()
      ..color = Color(color)
      ..isAntiAlias = true;
    if (erase) dotPaint.blendMode = BlendMode.clear;
    canvas.drawCircle(toOffset(points.first), width / 2, dotPaint);
    return;
  }

  final path = Path();
  final first = toOffset(points.first);
  path.moveTo(first.dx, first.dy);

  for (var i = 1; i < points.length - 1; i++) {
    final current = toOffset(points[i]);
    final next = toOffset(points[i + 1]);
    final mid = Offset((current.dx + next.dx) / 2, (current.dy + next.dy) / 2);
    path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
  }

  final last = toOffset(points.last);
  path.lineTo(last.dx, last.dy);
  canvas.drawPath(path, strokePaint);
}

/// 已完成笔画：直接复用烘焙好的 [ui.Picture]。
///
/// 橡皮进行时会被隐藏——此时由活动层把整幅画合并成一层再擦除，
/// 否则「擦」的效果看不见（详见 [_ActiveStrokePainter]）。
class _CommittedPainter extends CustomPainter {
  const _CommittedPainter(this.picture, {required this.visible});

  final ui.Picture picture;
  final bool visible;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    canvas.drawPicture(picture);
  }

  @override
  bool shouldRepaint(covariant _CommittedPainter oldDelegate) =>
      oldDelegate.picture != picture || oldDelegate.visible != visible;
}

/// 正在绘制的一笔：每帧只重绘这一条路径。
///
/// 橡皮需要特殊处理：`BlendMode.clear` 只能擦掉**同一图层内**的像素。已完成的
/// 笔画在另一张 picture 里，直接叠加 clear 只会把画布擦穿到背景色。因此擦除时
/// 把「已完成的画 + 当前擦除路径」放进同一个图层，视觉上才是真的在擦纸上的墨。
class _ActiveStrokePainter extends CustomPainter {
  const _ActiveStrokePainter({
    required this.points,
    required this.revision,
    required this.color,
    required this.width,
    required this.rect,
    required this.erase,
    required this.basePicture,
  });

  final List<rust.StrokePoint> points;
  final int revision;
  final int color;
  final double width;
  final Rect rect;
  final bool erase;
  final ui.Picture basePicture;

  @override
  void paint(Canvas canvas, Size size) {
    if (!erase) {
      _paintStroke(canvas, rect, points, color, width);
      return;
    }
    if (points.isEmpty || rect.isEmpty) return;

    canvas.saveLayer(rect, Paint());
    canvas.drawPicture(basePicture);
    _paintStroke(canvas, rect, points, color, width, erase: true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ActiveStrokePainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.rect != rect ||
      oldDelegate.erase != erase ||
      oldDelegate.basePicture != basePicture ||
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

/// 悬浮工具面板：左侧竖向停靠，只承载「工具」这一层。
///
/// 颜色与粗细不再常驻——它们属于工具参数，长按工具图标后在该工具的设置面板里
/// 调整。这样工具栏的长度只与工具数量相关，新增工具时不会越堆越长。
class _BrushPanel extends StatelessWidget {
  const _BrushPanel({
    required this.metrics,
    required this.selectedTool,
    required this.onSelectTool,
    required this.onLongPressTool,
  });

  final _ToolbarMetrics metrics;
  final ToolKind selectedTool;
  final ValueChanged<ToolKind> onSelectTool;
  final ValueChanged<ToolKind> onLongPressTool;

  static const int _columns = 2;

  /// 当前可用的绘画工具。后续扩容直接在这里追加。
  static const List<({ToolKind kind, String icon, String label})> _tools = [
    (kind: ToolKind.brush, icon: AppIcons.brush, label: '画笔'),
    (kind: ToolKind.eraser, icon: AppIcons.eraser, label: '橡皮'),
  ];

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
              for (final tool in _tools)
                _ToolCell(
                  icon: tool.icon,
                  label: tool.label,
                  selected: tool.kind == selectedTool,
                  metrics: metrics,
                  onTap: () => onSelectTool(tool.kind),
                  onLongPress: () => onLongPressTool(tool.kind),
                ),
            ]),
            SizedBox(height: metrics.gap * 0.6),
            Text(
              '长按设置',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 9,
              ),
            ),
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

/// 工具格：选中时以主色圆形底色高亮，与导航栏的选中语言保持一致。
class _ToolCell extends StatelessWidget {
  const _ToolCell({
    required this.icon,
    required this.label,
    required this.selected,
    required this.metrics,
    required this.onTap,
    required this.onLongPress,
  });

  final String icon;
  final String label;
  final bool selected;
  final _ToolbarMetrics metrics;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = metrics.cell * 0.74;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: metrics.cell,
          height: metrics.cell,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.primaryContainer.withValues(alpha: 0.85)
                    : Colors.transparent,
              ),
              child: Center(
                child: AppIcon(
                  icon,
                  size: metrics.cell * 0.48,
                  color: foreground,
                  semanticLabel: label,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
