import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../models/project.dart';
import '../models/tool_settings.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';
import '../services/canvas_geometry.dart';
import '../services/canvas_viewport.dart';
import '../services/document_painter.dart';
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/exporter.dart';
import '../services/project_store.dart';
import '../services/stroke_smoother.dart';
import '../widgets/app_icon.dart';
import '../widgets/layers_sheet.dart';
import '../widgets/tool_settings_sheet.dart';
import 'export_screen.dart';

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

  /// 视口：缩放 / 旋转 / 平移。默认「适配画布」。
  CanvasViewport _viewport = const CanvasViewport();

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
      final stored = await _documentStore.loadDocument(widget.project.id);
      if (!mounted) return;
      _engine.load(stored.layers);
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
      await _documentStore.saveDocument(widget.project.id, _engine.layers);
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
    paintDocument(
      canvas,
      rect,
      Color(document.backgroundArgb),
      _engine.layers,
    );

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

  // ---- 指针采集与双指变换 ----

  /// 当前按下的所有指针（屏幕坐标）。
  ///
  /// 单指用于绘制，双指用于缩放/旋转/平移。用原始指针而不是 `GestureDetector`，
  /// 是因为绘制必须逐点同步处理，不能等手势竞技场判定结束。
  final Map<int, Offset> _pointers = <int, Offset>{};

  bool _transforming = false;
  CanvasViewport _gestureStartViewport = const CanvasViewport();
  Offset _gestureStartCentroid = Offset.zero;
  Offset _gestureStartPointA = Offset.zero;
  Offset _gestureStartPointB = Offset.zero;

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;

    // 第二根手指落下：放弃当前笔画，转入双指变换。
    if (_pointers.length >= 2) {
      _beginTransform();
      return;
    }

    if (_loading || _activePointer != null) return;
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
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_transforming && _pointers.length >= 2) {
      _updateTransform();
      return;
    }

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
    _pointers.remove(e.pointer);

    if (_transforming) {
      if (_pointers.length < 2) _endTransform();
      return; // 变换结束时残余的指针不再落笔，避免误画
    }

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
    _pointers.remove(e.pointer);
    if (_transforming && _pointers.length < 2) _endTransform();

    // 手势被系统打断（来电、返回手势等）时丢弃这一笔的半成品。
    if (e.pointer != _activePointer) return;
    setState(() {
      _activePointer = null;
      _smoother = null;
      _activeRevision++;
    });
  }

  /// 开始双指变换：记录基线，丢弃当前未完成的笔画。
  void _beginTransform() {
    final points = _pointers.values.take(2).toList();
    _transforming = true;
    _gestureStartViewport = _viewport;
    _gestureStartPointA = points[0];
    _gestureStartPointB = points[1];
    _gestureStartCentroid = (points[0] + points[1]) / 2;

    if (_activePointer != null || _smoother != null) {
      _activePointer = null;
      _smoother = null;
      _activeRevision++;
    }
    setState(() {});
  }

  void _updateTransform() {
    final points = _pointers.values.take(2).toList();
    final a = points[0];
    final b = points[1];
    final startVector = _gestureStartPointB - _gestureStartPointA;
    final currentVector = b - a;
    if (startVector.distance < 1 || currentVector.distance < 1) return;

    final scaleFactor = currentVector.distance / startVector.distance;
    final rotationDelta =
        math.atan2(currentVector.dy, currentVector.dx) -
            math.atan2(startVector.dy, startVector.dx);

    setState(() {
      _viewport = _gestureStartViewport.applyGesture(
        startCentroid: _gestureStartCentroid,
        currentCentroid: (a + b) / 2,
        scaleFactor: scaleFactor,
        rotationDelta: rotationDelta,
        docRect: _documentRect,
      );
    });
  }

  void _endTransform() {
    _transforming = false;
    setState(() {});
  }

  /// 恢复「适配画布」。
  void _resetViewport() {
    if (_viewport.isIdentity) return;
    setState(() => _viewport = const CanvasViewport());
  }

  /// 把指针位置转换为文档内的归一化坐标（0~1）。
  ///
  /// 先经视口反算回文档坐标，再归一化：缩放或旋转后落笔位置才不会偏移。
  /// 文档之外的区域会被夹到边缘，否则笔画会跑到纸面之外。
  rust.StrokePoint _toNormalized(Offset local, double pressure) {
    final rect = _documentRect;
    final doc = _viewport.toDocument(local, rect);
    final x = rect.width <= 0
        ? 0.0
        : ((doc.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = rect.height <= 0
        ? 0.0
        : ((doc.dy - rect.top) / rect.height).clamp(0.0, 1.0);
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

  /// 打开导出页面。
  ///
  /// 导出使用图层快照：导出过程中即使后台有状态变化也不会影响结果。
  Future<void> _openExport() async {
    final result = await Navigator.of(context).push<ExportResult>(
      MaterialPageRoute<ExportResult>(
        builder: (_) => ExportScreen(
          project: widget.project,
          layers: _engine.layers,
          activeLayerId: _engine.activeLayerId,
        ),
      ),
    );
    if (result == null || !mounted) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('已导出 ${result.file.uri.pathSegments.last}')),
      );
  }

  /// 打开图层面板。
  ///
  /// 面板直接改引擎状态，因此这里在每次变更后重绘并触发保存；
  /// 面板关闭后再刷一次，确保缩略图与列表状态一致。
  Future<void> _openLayers() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => LayersSheet(
        engine: _engine,
        onChanged: () {
          setState(() {});
          _scheduleSave();
        },
      ),
    );
    if (!mounted) return;
    setState(() {});
    _scheduleSave();
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
          content: const Text('已清空当前图层'),
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
              onPressed: _viewport.isIdentity ? null : _resetViewport,
              tooltip: '适配画布',
              icon: const Icon(Icons.fit_screen_outlined),
            ),
            IconButton(
              onPressed: _openLayers,
              tooltip: '图层',
              icon: const Icon(Icons.layers_outlined),
            ),
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
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                switch (action) {
                  case 'export':
                    unawaited(_openExport());
                  case 'clear':
                    _clear();
                }
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'export',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.ios_share, size: 20),
                    title: Text('导出'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'clear',
                  enabled: _engine.activeLayer.strokes.isNotEmpty,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline, size: 20),
                    title: Text('清空当前图层'),
                  ),
                ),
              ],
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
        // 橡皮进行中必须重绘整个文档，实时擦除才看得见（见 _CanvasPainter）。
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
              // 工作台：文档之外的区域（不参与缩放，始终铺满）。
              ColoredBox(color: theme.colorScheme.surfaceContainerLowest),
              CustomPaint(
                painter: _CanvasPainter(
                  picture: picture,
                  rect: rect,
                  paperColor: Color(document.backgroundArgb),
                  layers: _engine.layers,
                  activeLayerId: _engine.activeLayerId,
                  activeLayerOpacity: _engine.activeLayer.opacity,
                  activePoints: _activePoints,
                  activeColor: _activeSettings.color.toARGB32(),
                  activeWidth: _activeSettings.widthRatio * rect.shortestSide,
                  activeErase: erasing,
                  activeRevision: _activeRevision,
                  viewport: _viewport,
                  activeBlend: _engine.activeLayer.blendMode,
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
      paintDocument(
        canvas,
        rect,
        Color(widget.project.document.backgroundArgb),
        _engine.layers,
      );
    }
    final picture = recorder.endRecording();
    _committedPicture = picture;
    _pictureRevision = _engine.revision;
    _pictureRect = rect;
    return picture;
  }
}

/// 画布内容的唯一绘制入口。
///
/// 两条路径：
/// - **常规**：直接重放已烘焙的 [picture]（纸面 + 所有图层），再把活动笔画叠上去。
///   活动笔画单独成层，是为了让它跟随所属图层的不透明度。
/// - **擦除中**：必须整篇重绘。`BlendMode.clear` 只能擦掉同一图层内的像素，
///   而活动笔画属于某个图层，只有把该层连同它一起重画，擦除才看得见。
class _CanvasPainter extends CustomPainter {
  const _CanvasPainter({
    required this.picture,
    required this.rect,
    required this.paperColor,
    required this.layers,
    required this.activeLayerId,
    required this.activeLayerOpacity,
    required this.activePoints,
    required this.activeColor,
    required this.activeWidth,
    required this.activeErase,
    required this.activeRevision,
    required this.viewport,
    required this.activeBlend,
  });

  final ui.Picture picture;
  final Rect rect;
  final Color paperColor;
  final List<DrawingLayer> layers;
  final String activeLayerId;
  final double activeLayerOpacity;
  final List<rust.StrokePoint> activePoints;
  final int activeColor;
  final double activeWidth;
  final bool activeErase;
  final int activeRevision;
  final CanvasViewport viewport;
  final LayerBlendMode activeBlend;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect.isEmpty) return;

    // 视口变换统一在这里施加：已完成内容仍以「文档坐标」缓存，
    // 缩放与旋转不需要重建 picture，只是换一次变换矩阵。
    canvas.save();
    viewport.applyTo(canvas, rect);
    try {
      _paintContent(canvas);
    } finally {
      canvas.restore();
    }
  }

  void _paintContent(Canvas canvas) {
    if (activeErase) {
      paintDocument(
        canvas,
        rect,
        paperColor,
        layers,
        activeLayerId: activeLayerId,
        activePoints: activePoints,
        activeColor: activeColor,
        activeWidth: activeWidth,
        activeErase: true,
      );
      return;
    }

    canvas.drawPicture(picture);
    if (activePoints.isEmpty) return;

    // 活动笔画要在视觉上「属于」当前图层：乘上该层的不透明度与混合模式。
    // 注意这与提交后的结果并非严格等价——提交后是整层参与混合，而预览时
    // 只有这一笔参与。笔画数量多时两者差异极小，绘制过程中可接受。
    final needsLayer = activeLayerOpacity < 0.999 || !activeBlend.isNormal;
    if (needsLayer) {
      canvas.saveLayer(
        rect,
        Paint()
          ..color = Colors.black.withValues(alpha: activeLayerOpacity)
          ..blendMode = activeBlend.blendMode,
      );
    }
    paintStrokePath(canvas, rect, activePoints, activeColor, activeWidth);
    if (needsLayer) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) =>
      oldDelegate.picture != picture ||
      oldDelegate.rect != rect ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.activeLayerId != activeLayerId ||
      oldDelegate.activeLayerOpacity != activeLayerOpacity ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.activeWidth != activeWidth ||
      oldDelegate.activeErase != activeErase ||
      oldDelegate.activeRevision != activeRevision ||
      oldDelegate.viewport != viewport ||
      oldDelegate.activeBlend != activeBlend;
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
