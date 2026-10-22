import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/canvas_tool.dart';
import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../models/project.dart';
import '../models/stroke.dart';
import '../models/tool_settings.dart';
import '../rust/api/stroke.dart' as rust;
import '../rust/api/tools.dart';
import '../services/app_settings.dart';
import '../services/canvas_geometry.dart';
import '../services/canvas_viewport.dart';
import '../services/color_picker.dart';
import '../services/document_painter.dart';
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/edit_journal.dart';
import '../services/exporter.dart';
import '../services/project_store.dart';
import '../services/raster_brush.dart';
import '../services/raster_mask.dart';
import '../services/raster_patch.dart';
import '../services/raster_renderer.dart';
import '../services/raster_selection_session.dart';
import '../services/raster_surface.dart';
import '../services/raster_rasterizer.dart';
import '../services/stroke_smoother.dart';
import '../services/stroke_outline.dart';
import '../services/transform_geometry.dart';
import '../services/transform_session.dart';
import '../widgets/app_icon.dart';
import '../widgets/layers_bubble.dart';
import '../widgets/selection_bubble.dart';
import '../widgets/selection_overlay.dart';
import '../widgets/tool_settings_bubble.dart';
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
  const CanvasScreen({
    super.key,
    required this.project,
    this.documentStore,
    this.journal,
  });

  final DrawingProject project;

  /// 笔画存储实现。
  ///
  /// 生产环境留空，走默认的「应用文档目录」；测试可注入以临时目录为根的实例，
  /// 从而无需 path_provider 插件即可验证界面行为。
  final DocumentStore? documentStore;

  /// 崩溃恢复日志。生产环境留空（与 [documentStore] 同根），测试可注入。
  final EditJournal? journal;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    with WidgetsBindingObserver {
  final DrawingEngine _engine = DrawingEngine();
  late final DocumentStore _documentStore =
      widget.documentStore ?? DocumentStore();
  final ProjectStore _projectStore = ProjectStore();

  /// 当前工具。吸管与套索不产生笔画，因此这里用 [CanvasTool] 而不是 `ToolKind`。
  CanvasTool _tool = CanvasTool.brush;

  /// 最近一次「会画画」的工具。吸管取完色要回到它——回到画笔是错的，
  /// 用户可能正在用橡皮。
  CanvasTool _lastPaintTool = CanvasTool.brush;

  /// 各绘画工具各自的参数。切回某工具时，它上次用的颜色与笔宽仍在。
  final Map<CanvasTool, ToolSettings> _settings =
      <CanvasTool, ToolSettings>{
    // 画笔默认开启压感：这是产品主张「笔触手感」的主要载体。
    CanvasTool.brush: const ToolSettings(
      color: Color(0xFF000000),
      widthRatio: 0.01,
      pressureEnabled: true,
    ),
    // 橡皮默认粗一些、且不跟随压力：擦除需要的是稳定的覆盖范围，
    // 而不是笔锋——压力一变细，擦除会变得难以控制。
    CanvasTool.eraser: const ToolSettings(
      color: Color(0xFF000000),
      widthRatio: 0.03,
    ),
  };

  /// 当前绘画工具的参数字。吸管与套索回落到画笔的参数，仅用于显示颜色。
  ToolSettings get _paintSettings =>
      _settings[_tool] ?? _settings[CanvasTool.brush]!;

  ToolSettings settingsFor(CanvasTool tool) =>
      _settings[tool] ?? _settings[CanvasTool.brush]!;

  /// 各工具的行为参数，进入画板时从 Rust 读取一次并缓存。
  ///
  /// Rust 是工具参数的单一事实来源；读取失败（例如单元测试环境未初始化 FFI）
  /// 时回落到 [_fallbackProfiles]，保证画板仍可用。
  Map<ToolKind, ToolProfile> _profiles = _fallbackProfiles;

  static const Map<ToolKind, ToolProfile> _fallbackProfiles =
      <ToolKind, ToolProfile>{
    ToolKind.brush: ToolProfile(
      smoothWindow: 5,
      erases: false,
    ),
    ToolKind.eraser: ToolProfile(
      smoothWindow: 3,
      erases: true,
    ),
  };

  /// 当前工具的行为参数；非绘画工具没有对应项，回落到画笔。
  ToolProfile get _profile {
    final kind = _tool.strokeKind ?? ToolKind.brush;
    return _profiles[kind] ?? _fallbackProfiles[kind]!;
  }

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

  // ---- 位图图层 ----

  /// 位图瓦片的图像缓存与绘制。
  ///
  /// 画布、缩略图共用这一份：像素 → `ui.Image` 是异步的，缓存放在界面上，
  /// 服务层只提供「怎么画」。
  final RasterRenderer _rasterRenderer = RasterRenderer();

  /// 当前像素笔「这一笔之前」的快照；非空表示正在进行像素笔画。
  RasterSurface? _rasterBefore;

  /// 像素笔上一个落点（surface 像素坐标）。
  Offset? _rasterLastPoint;

  /// 这一笔是否真的落过 dab（点一下就抬手也算）。
  bool _rasterPainted = false;

  /// 是否有一次像素刷新正在飞（避免同一帧堆叠多次解码）。
  bool _rasterFlushing = false;

  /// 解码进行中又收到了新请求：本次结束后必须再跑一轮，
  /// 否则这一批待办会滞留到下一次输入为止。
  bool _rasterFlushQueued = false;

  /// 位图图层上圈出的像素选区（套索抬手时生成）。
  ///
  /// 与矢量的 `_session` 是**两套东西**：矢量选区的原子是笔画，位图选区的原子
  /// 是像素，两者的命中、变换与提交方式完全不同，硬合并只会让各自都变难。
  RasterMask? _rasterMask;

  /// 正在拖动的像素选区。只在拖动期间存在，抬手立即提交或还原。
  RasterSelectionSession? _rasterSelection;

  /// 浮动内容的预览贴图（patch 解码后的结果）。
  ui.Image? _rasterFloatImage;

  /// 拖动起点（图层像素坐标）。
  Offset? _rasterDragOrigin;

  /// 本次拖动开始时的摆放参数（累加的基准，避免逐帧累乘漂移）。
  PatchTransform _rasterDragBase = PatchTransform.identity;

  /// 浮动内容的版本号：每次拖动都会变，用于让渲染缓存知道要重建。
  int _floatingRevision = 0;

  /// 脏瓦片的即时落盘定时器。
  ///
  /// 文档自动保存要等 800ms 且会重新编码全部笔画，而像素内容不进崩溃日志——
  /// 崩溃一次就丢掉整段。瓦片走独立通道：只写这一笔改过的几块，
  /// 且不重编码文档。
  Timer? _tileFlushTimer;
  bool _tileFlushing = false;

  /// 栅格化进行中：期间禁止再点一次（重复点击会烘焙两次）。
  bool _rasterizing = false;

  /// 视口：缩放 / 旋转 / 平移。默认「适配画布」。
  CanvasViewport _viewport = const CanvasViewport();

  /// 工具栏锚点（归一化 0~1，相对去掉外边距后的可用区域）。
  ///
  /// 用 `Align` + `FractionalOffset` 定位而不是 `Positioned(left, top)`：
  /// 前者的落点天然被限制在父级范围内，不需要在拖动时反复测量面板尺寸再夹取。
  Offset _toolbarAnchor = _defaultToolbarAnchor;

  static const Offset _defaultToolbarAnchor = Offset(0, 0.5);

  /// 工具栏可拖动的范围（已扣除外边距），用于把手指位移换算成归一化增量。
  Size _toolbarDragArea = Size.zero;

  /// 面板本体，用来测量气泡的锚点位置。
  final GlobalKey _panelKey = GlobalKey();

  /// 顶栏「图层」按钮，用作图层气泡的锚点。
  final GlobalKey _layersButtonKey = GlobalKey();

  /// 气泡出入场时长。这个版本的 `showGeneralDialog` 只有一个时长参数，
  /// 退场会沿用同一个值；130ms 对两者都够短，不必为此自己写 Route。
  static const Duration _bubbleDuration = Duration(milliseconds: 130);

  /// 已完成笔画的渲染缓存。
  ui.Picture? _committedPicture;
  int _pictureRevision = -1;

  /// 缓存里的位图版本。
  ///
  /// 位图瓦片是异步解码的，重建时 `_engine.revision` 通常没有变化（像素不是
  /// 笔画对象），因此必须把「图像更新到第几版」也算进缓存键，否则新瓦片永远
  /// 画不出来。
  int _pictureRasterRevision = -1;
  Rect _pictureRect = Rect.zero;

  /// 浮动内容（像素选区拖动）的版本号，进缓存键。
  ///
  /// 拖动期间 `engine.revision` 不变（还没提交），但画面每帧都要变，
  /// 因此需要单独一个版本号让 picture 重建。
  int _pictureFloatingRevision = -1;

  /// 位图图像的版本号；每次解码完成递增。
  int _rasterRevision = 0;

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

  /// 崩溃恢复日志：抬笔即追加一笔，完整保存成功后清空。
  late final EditJournal _journal =
      widget.journal ?? EditJournal();

  // ---- 选区与变换 ----

  /// 正在画的套索（归一化坐标）；为空表示没在画。
  List<Offset>? _lassoPoints;

  /// 本次套索开始前的选区（加选/减选的合并基数），按下时快照，抬手时消费。
  Set<int> _lassoBaseIds = const <int>{};

  /// 已闭合的选区（归一化坐标），仅用于显示；命中集合在 [_session] 里。
  List<Offset>? _selectionPath;

  /// 变换会话；为空表示当前没有待提交的变换。
  TransformSession? _session;

  /// 再次套索时如何与已有选区合并（新建 / 追加 / 减选）。
  SelectionMode _selectionMode = SelectionMode.replace;

  /// 当前单指拖动的作用。
  TransformDragMode _dragMode = TransformDragMode.none;

  /// 拖动基线。全部取「手势开始那一刻」的快照，避免逐帧累乘。
  Offset _dragStartLocal = Offset.zero;
  StrokeTransform _dragStartTransform = StrokeTransform.identity;
  double _dragStartScale = 1;
  double _dragStartRotation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _toolbarAnchor = AppSettings.toolbarAnchor.value ?? _defaultToolbarAnchor;
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
    _tileFlushTimer?.cancel();
    _committedPicture?.dispose();
    _disposeRasterFloatImage();
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
      // 位图图层的像素刚被读进内存，图像缓存还是空的：必须显式预热一次，
      // 否则第一帧画出来是一张白纸。
      _invalidateAllRaster();
      final recovered = await _replayJournal();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadWarning = stored.error ??
            (recovered > 0 ? '已恢复 $recovered 笔未保存的内容' : null);
      });
      // 恢复出来的内容只在内存里，立刻安排一次完整落盘，把它写进正式文档。
      if (recovered > 0) _scheduleSave();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadWarning = '读取工程失败：$error';
      });
    }
  }

  /// 回放崩溃日志：按图层下标与笔画 id 去重后补进内存。
  ///
  /// 返回补回的笔数。去重是必要的——日志只覆盖「最后一次完整保存之后」的增量，
  /// 但若清空失败（例如清空时进程又被杀），重放可能遇到已落盘的笔画。
  Future<int> _replayJournal() async {
    try {
      final entries = await _journal.read(widget.project.id);
      if (entries.isEmpty) return 0;
      return _engine.restoreStrokes(groupByLayer(entries));
    } catch (_) {
      // 日志损坏不该影响正常打开工程：直接忽略，下次保存会覆盖它。
      return 0;
    }
  }

  /// 记录一笔到崩溃日志（抬笔即写，不等 800ms 的保存节流）。
  void _recordJournal(Stroke stroke) {
    final index = _engine.layers.indexWhere(
      (layer) => layer.id == _engine.activeLayerId,
    );
    if (index < 0) return;
    unawaited(
      _journal.appendStroke(
        projectId: widget.project.id,
        layerIndex: index,
        stroke: stroke,
      ),
    );
  }

  void _scheduleSave() {
    if (!mounted) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_flushSave()));
  }

  /// 落盘。
  ///
  /// 用「循环到不脏」而不是「写一次 + 事后比对 revision」：后者在 [dispose]
  /// 与在途保存重叠时会漏掉最后一版——`dispose` 里那次调用看到 `_saving` 为真
  /// 直接返回，而被它取消的定时器也不会再来一次。循环把「期间又变脏」收敛进
  /// 同一个 await 链，最坏情况只是多写一次。
  Future<void> _flushSave() async {
    if (_saving) return;
    _saving = true;
    try {
      while (_dirty) {
        _dirty = false;
        try {
          await _documentStore.saveDocument(widget.project.id, _engine.layers);
          // 完整快照已落盘，日志里的增量被覆盖，可以整份删除。
          unawaited(_journal.clear(widget.project.id));
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
          break; // 失败后不再重试，避免瞬时故障变成忙循环
        }
      }
    } finally {
      _saving = false;
    }
  }

  /// 内容变化后的统一收尾：刷新界面 + 触发保存。
  /// 结构性变更（撤销、图层增删改序）之后：
  ///
  /// - 清空崩溃日志——日志里的「第几层」一旦与当前图层顺序不符，回放就会落错层；
  /// - 丢弃未提交的选区变换，否则手柄会指着一批已经被撤销掉的笔画。
  void _onDocumentChanged() {
    // 结构变更（撤销 / 图层增删改序）之后，浮动内容指向的瓦片可能已经不属于
    // 任何图层——放弃它，由下面的整层失效负责把画面拉回真实状态。
    _cancelRasterSelection();
    _rasterMask = null;

    if (_session != null || _selectionPath != null) {
      setState(() {
        _session = null;
        _selectionPath = null;
        _lassoPoints = null;
        _dragMode = TransformDragMode.none;
      });
    } else {
      setState(() {});
    }
    // 撤销 / 重做会整份换掉位图图层的像素：缓存必须整体失效。
    _invalidateAllRaster();
    unawaited(_journal.clear(widget.project.id));
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
      // 先确保位图瓦片都已转成图像：缩略图是同步绘制的，缓存没热好的话
      // 位图内容会整块缺失，生成一张「只有矢量」的缩略图。
      await _flushRaster();
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
      rasterSource: _rasterRenderer,
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

  /// 多指手势开始时刻（毫秒）；0 表示当前没有多指手势在进行。
  int _multiTouchStartMs = 0;

  /// 本次多指手势是否真的改变了视口（缩放 / 旋转 / 平移）。
  ///
  /// 双指双击撤销必须与双指缩放区分开：只要视口被动过，这次多指操作就
  /// 属于「变换」而不是「轻点」。
  bool _multiTouchTransformed = false;

  /// 上一次「双指轻点」完成的时刻，用于判定双击。
  int _lastTwoFingerTapMs = 0;

  /// 一次「双指轻点」允许的最长按住时间。
  static const Duration _twoFingerTapMaxHold = Duration(milliseconds: 300);

  /// 两次「双指轻点」之间的最长间隔，超过则重新计数。
  static const Duration _twoFingerDoubleTapWindow = Duration(milliseconds: 320);

  /// 判定「没有真正移动视口」的容差（逻辑像素 / 缩放倍率 / 弧度）。
  static const double _twoFingerTapTolerance = 12;
  static const double _twoFingerTapScaleTolerance = 0.02;
  static const double _twoFingerTapRotationTolerance = 0.02;

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;

    // 第二根手指落下：放弃当前笔画，转入双指变换。
    if (_pointers.length >= 2) {
      if (_pointers.length == 2) {
        _multiTouchStartMs = DateTime.now().millisecondsSinceEpoch;
        _multiTouchTransformed = false;
      }
      _beginTransform();
      return;
    }

    if (_loading || _activePointer != null) return;
    if (_documentRect.isEmpty) return;

    _activePointer = e.pointer;

    // 套索与吸管不产生笔画：它们走自己的分支，不创建平滑器。
    if (_tool == CanvasTool.lasso) {
      _beginSelectionPointer(e.localPosition);
      return;
    }
    if (_tool == CanvasTool.eyedropper) {
      unawaited(_pickColorAt(e.localPosition));
      return;
    }

    _strokeStartMs = DateTime.now().millisecondsSinceEpoch;

    // 位图图层走像素路径：没有点列、没有平滑器，直接往瓦片上落 dab。
    if (_engine.activeLayer.isRaster) {
      _beginRasterStroke(e.localPosition, e.pressure);
      return;
    }

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

  /// 屏幕坐标 → 位图像素坐标。
  ///
  /// 与笔画共用 `_localToNormalizedRaw`，因此视口缩放/旋转对像素笔的影响与
  /// 矢量笔完全一致——两条路径不该有第二套坐标换算。
  Offset _toRasterPixel(Offset local, RasterSurface surface) {
    final normalized = _localToNormalizedRaw(local);
    // 超出画布的部分夹到边缘外一点点即可：dab 本来就会被瓦片边界裁掉，
    // 但放任一个巨大的坐标会让包围盒循环空转。
    return Offset(
      normalized.dx.clamp(-0.25, 1.25) * surface.width,
      normalized.dy.clamp(-0.25, 1.25) * surface.height,
    );
  }

  /// 当前像素笔的半径（surface 像素）。
  ///
  /// 笔宽在文档空间按**短边**归一化（与矢量一致），压感开关打开时乘上同一个
  /// `pressureWidthFactor`——两条路径的粗细手感必须一样，否则切图层会突变。
  double _rasterRadius(RasterSurface surface, double pressure) {
    final shortestSide =
        math.min(surface.width, surface.height).toDouble();
    var width = strokeWidthPx(_paintSettings.widthRatio, shortestSide);
    if (_paintSettings.pressureEnabled) {
      width *= pressureWidthFactor(pressure);
    }
    return math.max(0.5, width / 2);
  }

  void _beginRasterStroke(Offset local, double pressure) {
    final surface = _engine.activeLayer.raster;
    if (surface == null) return;
    final before = _engine.beginRasterStroke();
    if (before == null) return;

    _rasterBefore = before;
    _rasterPainted = false;
    final point = _toRasterPixel(local, surface);
    _rasterLastPoint = point;

    final touched = RasterBrush.dab(
      surface,
      center: point,
      radius: _rasterRadius(surface, pressure),
      colorArgb: _paintSettings.color.toARGB32(),
      erase: _tool.strokeKind == ToolKind.eraser,
    );
    _rasterPainted = true;
    _rasterRenderer.invalidateTiles(surface, touched);
    unawaited(_flushRaster());
  }

  void _extendRasterStroke(Offset local, double pressure) {
    final surface = _engine.activeLayer.raster;
    final last = _rasterLastPoint;
    if (surface == null || last == null) return;

    final point = _toRasterPixel(local, surface);
    if ((point - last).distance < 0.01) return;

    final touched = RasterBrush.strokeSegment(
      surface,
      from: last,
      to: point,
      radius: _rasterRadius(surface, pressure),
      colorArgb: _paintSettings.color.toARGB32(),
      erase: _tool.strokeKind == ToolKind.eraser,
    );
    _rasterLastPoint = point;
    _rasterPainted = true;
    _rasterRenderer.invalidateTiles(surface, touched);
    unawaited(_flushRaster());
  }

  /// 提交像素笔。
  ///
  /// 像素内容在绘制过程中就已经写进 surface 了，这里只补一条撤销记录，
  /// 并触发一次落盘。`_rasterPainted` 为假（例如按下即被系统打断）时不入栈。
  void _commitRasterStroke() {
    final before = _rasterBefore;
    _rasterBefore = null;
    _rasterLastPoint = null;
    final painted = _rasterPainted;
    _rasterPainted = false;
    if (before == null || !painted) return;

    final committed = _engine.commitRasterStroke(before);
    if (!committed) return;
    setState(() {});
    _scheduleSave();
    _scheduleTileFlush();
  }

  /// 像素内容一抬手就把脏瓦片落盘。
  ///
  /// 防抖而不是每帧写：一次连续涂画会反复触发，等到停手再落一次。
  /// 200ms 远短于文档自动保存的 800ms，崩溃最多丢最后一笔。
  void _scheduleTileFlush() {
    _tileFlushTimer?.cancel();
    _tileFlushTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(_flushTiles());
    });
  }

  Future<void> _flushTiles() async {
    if (_tileFlushing) return;
    _tileFlushing = true;
    try {
      await _documentStore.flushTiles(widget.project.id, _engine.layers);
    } catch (_) {
      // 落盘失败不影响创作：下一次完整保存会把这些瓦片再写一遍。
    } finally {
      _tileFlushing = false;
    }
  }

  /// 丢弃这一笔（手势被系统打断）。像素已经写进 surface，必须换回快照。
  void _abortRasterStroke() {
    final before = _rasterBefore;
    _rasterBefore = null;
    _rasterLastPoint = null;
    _rasterPainted = false;
    final surface = _engine.activeLayer.raster;
    if (before == null || surface == null) return;
    _engine.activeLayer.raster = before;
    _rasterRenderer.invalidateAll(before);
    unawaited(_flushRaster());
    setState(() {});
  }

  /// 把待办瓦片解码成图像，完成后重绘一次。
  ///
  /// 解码期间不阻塞输入：新一轮 dab 只会往待办集合里追加。但**不能直接丢弃**
  /// 解码进行中的调用——抬手那一帧的 dab 会因此永远上不了屏（下一次 flush
  /// 要等下一次输入），所以这里记一个「还要再跑一轮」的标记。
  Future<void> _flushRaster() async {
    if (_rasterFlushing) {
      _rasterFlushQueued = true;
      return;
    }
    _rasterFlushing = true;
    var changed = false;
    try {
      // 一轮只处理进入时的那批待办；期间新来的请求让循环再跑一轮。
      // 上限防止「画得比解码快」时把 UI 线程一直占着。
      for (var round = 0; round < 8; round++) {
        _rasterFlushQueued = false;
        for (final layer in _engine.layers) {
          final surface = layer.raster;
          if (surface == null) continue;
          await _rasterRenderer.build(surface, onReady: () => changed = true);
        }
        if (!_rasterFlushQueued) break;
      }
    } finally {
      _rasterFlushing = false;
    }
    if (changed && mounted) {
      setState(() {
        _rasterRevision++;
        _activeRevision++;
      });
    }
  }

  /// 标记全部位图图层待重建（撤销 / 重做 / 栅格化之后调用）。
  void _invalidateAllRaster() {
    for (final layer in _engine.layers) {
      final surface = layer.raster;
      if (surface != null) _rasterRenderer.invalidateAll(surface);
    }
    unawaited(_flushRaster());
  }

  /// 把矢量图层烘焙成像素。
  ///
  /// 破坏性：原笔画被像素取代，画完之后不能再调笔宽。因此它必须是用户显式
  /// 触发的一次动作（ADR-027 明确不做隐式栅格化），而且进撤销栈，
  /// 会话内仍可反悔。
  Future<void> _rasterizeLayer(String layerId) async {
    if (_rasterizing) return;
    DrawingLayer? target;
    for (final layer in _engine.layers) {
      if (layer.id == layerId) target = layer;
    }
    // 渲染期间会 await，必须先确认对象还在，且内容还是矢量的。
    if (target == null || target.isRaster || target.isEmpty) return;

    final document = widget.project.document;
    setState(() => _rasterizing = true);
    try {
      final pixels = await RasterRasterizer.rasterizeLayer(
        target,
        width: document.widthPx,
        height: document.heightPx,
      );
      if (!mounted) return;
      if (!_engine.replaceWithPixels(layerId, pixels)) return;

      _rasterRenderer.invalidateAll(pixels);
      unawaited(_flushRaster());
      setState(() {});
      // 图层内容类型变了，崩溃日志里的「第几层 + 笔画」不再适用。
      unawaited(_journal.clear(widget.project.id));
      _scheduleSave();
      _showHint('已栅格化「${target.name}」，会话内可撤销');
    } catch (error) {
      if (!mounted) return;
      _showHint('栅格化失败：$error', duration: const Duration(seconds: 3));
    } finally {
      if (mounted) setState(() => _rasterizing = false);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_transforming && _pointers.length >= 2) {
      _updateTransform();
      return;
    }

    if (e.pointer != _activePointer) return;
    if (_tool == CanvasTool.lasso) {
      _updateSelectionDrag(e.localPosition);
      return;
    }
    if (_tool == CanvasTool.eyedropper) return;

    if (_rasterBefore != null) {
      _extendRasterStroke(e.localPosition, e.pressure);
      return;
    }

    final smoother = _smoother;
    if (smoother == null) return;
    smoother.add(_toNormalized(e.localPosition, e.pressure));
    setState(() => _activeRevision++);
  }

  /// 抬手即提交。
  ///
  /// 平滑已在采集阶段随点完成，此处不等待任何异步操作：清空活动层与写入新笔画
  /// 发生在同一次 setState 里，因此不会出现「笔画先消失一帧、再带着新形状出现」。
  void _onPointerUp(PointerUpEvent e) {
    _pointers.remove(e.pointer);

    final wasTransforming = _transforming;
    if (wasTransforming && _pointers.length < 2) _endTransform();
    // 只有所有手指都离开时才判定双指双击：中途抬手属于变换收尾，不算轻点。
    if (_pointers.isEmpty) _settleTouchGesture();

    if (wasTransforming) {
      return; // 变换结束时残余的指针不再落笔，避免误画
    }

    if (_tool == CanvasTool.lasso) {
      if (e.pointer == _activePointer) {
        _activePointer = null;
        _finishSelectionDrag();
      }
      return;
    }
    if (_tool == CanvasTool.eyedropper) {
      if (e.pointer == _activePointer) _activePointer = null;
      return;
    }

    if (e.pointer != _activePointer) return;
    _activePointer = null;

    if (_rasterBefore != null) {
      _commitRasterStroke();
      return;
    }
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

    late Stroke committed;
    setState(() {
      _smoother = null;
      _activeRevision++;
      committed = _engine.addStroke(
        points,
        tool: _tool.strokeKind!,
        color: _paintSettings.color.toARGB32(),
        widthRatio: _paintSettings.widthRatio,
        // 画下这一刻的开关状态随笔画一起保存，之后改开关不影响它（ADR-019）。
        usesPressure: _paintSettings.pressureEnabled,
      );
    });
    _recordJournal(committed);
    _scheduleSave();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    if (_transforming && _pointers.length < 2) _endTransform();

    // 手势被系统打断：本次多指操作不算数，也不该成为后续双击的前半程。
    if (_pointers.isEmpty) {
      _multiTouchStartMs = 0;
      _lastTwoFingerTapMs = 0;
    }

    // 手势被系统打断（来电、返回手势等）时丢弃这一笔的半成品。
    if (e.pointer != _activePointer) return;
    if (_tool == CanvasTool.lasso) {
      // 套索被打断：保留已画的部分（还可能是想要的形状），只是停止追加。
      if (_dragMode == TransformDragMode.draw) {
        _lassoPoints = null;
      }
      _dragMode = TransformDragMode.none;
      _activePointer = null;
      setState(() {});
      return;
    }
    setState(() {
      _activePointer = null;
      _smoother = null;
      _activeRevision++;
    });
    _abortRasterStroke();
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
    // 第二根手指落下时，进行中的像素笔画按「取消」处理：
    // 双指手势不是画画的意图，半截像素不该留下。
    _abortRasterStroke();
    // 像素选区的拖动同理：双指是要缩放画布，不是要挪内容。
    _cancelRasterSelection();
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

    final next = _gestureStartViewport.applyGesture(
      startCentroid: _gestureStartCentroid,
      currentCentroid: (a + b) / 2,
      scaleFactor: scaleFactor,
      rotationDelta: rotationDelta,
      docRect: _documentRect,
    );

    // 视口真的变了就算「变换」，本次多指操作不再有资格被判定为轻点。
    if (!_multiTouchTransformed &&
        ((next.scale - _gestureStartViewport.scale).abs() >
                _twoFingerTapScaleTolerance ||
            (next.rotation - _gestureStartViewport.rotation).abs() >
                _twoFingerTapRotationTolerance ||
            (next.offset - _gestureStartViewport.offset).distance >
                _twoFingerTapTolerance)) {
      _multiTouchTransformed = true;
    }

    setState(() => _viewport = next);
  }

  void _endTransform() {
    _transforming = false;
    setState(() {});
  }

  /// 所有手指离开后判定「双指双击」：两次干净的双指轻点 = 撤销。
  ///
  /// 之所以不用 `GestureDetector.onDoubleTap`：画布用原始 `Listener` 维护指针
  /// 状态机（见 ADR-011），把双击交给手势竞技场会和绘制抢事件，反而更容易误判。
  /// 在状态机内部判定，还能顺手排除「缩放结束后误撤销」这种情况。
  void _settleTouchGesture() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final startedAt = _multiTouchStartMs;
    _multiTouchStartMs = 0;

    final isTwoFingerTap = startedAt != 0 &&
        !_multiTouchTransformed &&
        now - startedAt <= _twoFingerTapMaxHold.inMilliseconds;
    if (!isTwoFingerTap) {
      _lastTwoFingerTapMs = 0;
      return;
    }

    final isSecondTap = _lastTwoFingerTapMs != 0 &&
        now - _lastTwoFingerTapMs <= _twoFingerDoubleTapWindow.inMilliseconds;
    _lastTwoFingerTapMs = isSecondTap ? 0 : now;
    if (isSecondTap) _undo();
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
    // 变换未提交时先落地：否则撤销会撤到「变换前」的那一步，
    // 而屏幕上还显示着变换后的预览，两者对不上。
    _commitSession();
    if (_engine.undo()) _onDocumentChanged();
  }

  void _redo() {
    _commitSession();
    if (_engine.redo()) _onDocumentChanged();
  }

  /// 画板内的短暂提示。
  ///
  /// 默认只停留 1 秒：画布上的提示只承担「确认操作已生效」，久留会遮住画面底部，
  /// 而且退出前还得看着它慢慢消失。需要让人读较长内容（例如导出路径）时，
  /// 调用方显式传入更长的时长。
  void _showHint(String message, {Duration duration = const Duration(seconds: 1)}) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: duration));
  }

  /// 打开导出页面。
  ///
  /// 传入的是引擎图层列表的**只读视图而非拷贝**：导出页是独立路由，期间画板
  /// 不可操作，不存在并发改写；不复制是为了避免大文档多一份内存。
  /// 压感开关必须一并带过去，否则导出结果与屏幕不一致。
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
    // 导出后不再分享，因此必须把「文件在哪」讲清楚。
    // Android 的产物是内容 URI（公共下载目录），没有可展示的绝对路径，故用结果里的位置描述。
    _showHint(
      '已导出到 ${result.location}',
      duration: const Duration(seconds: 3),
    );
  }

  /// 打开图层气泡。
  ///
  /// 面板直接改引擎状态，因此这里在每次变更后重绘并触发保存；
  /// 气泡关闭后再刷一次，确保缩略图与列表状态一致。
  /// 清空图层时面板会先回调 [LayersBubble.onCleared] 再请求关闭，
  /// 因此提示由画板弹出、不会随气泡一起消失。
  Future<void> _openLayers() async {
    final anchor = _globalRect(_layersButtonKey);
    if (anchor == null) return;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '关闭图层',
      barrierColor: Colors.transparent,
      transitionDuration: _bubbleDuration,
      pageBuilder: (dialogContext, animation, _) => LayersBubble(
        engine: _engine,
        anchor: anchor,
        animation: animation,
        onChanged: () {
          setState(() {});
          _scheduleSave();
        },
        onCleared: () => _showHint('已清空当前图层'),
        onFlip: (layerId, horizontal) {
          if (!_engine.flipLayer(layerId, horizontal: horizontal)) return;
          setState(() {});
          unawaited(_journal.clear(widget.project.id));
          _scheduleSave();
        },
        onAddRaster: () {
          final document = widget.project.document;
          _engine.addRasterLayer(
            width: document.widthPx,
            height: document.heightPx,
          );
          setState(() {});
          unawaited(_journal.clear(widget.project.id));
          _scheduleSave();
        },
        onRasterize: _rasterizeLayer,
        onTransform: (layerId) {
          Navigator.of(dialogContext).pop();
          // 气泡关闭后下一帧再进入变换态：此时画布已完成布局，
          // 手柄位置才是对的。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _beginLayerTransform(layerId);
          });
        },
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
    if (!mounted) return;
    setState(() {});
    _scheduleSave();
  }

  // ---- 工具栏拖动 ----

  /// 把手指位移换算成归一化锚点增量。
  ///
  /// 位移按「可用区域」而非「面板可移动的剩余空间」归一化，因此面板会以略小的
  /// 幅度跟随手指（约差一个面板宽）。这点偏差换来的是不需要在拖动中测量面板
  /// 尺寸，而面板块数变化时也不用同步维护一份尺寸计算。
  void _onToolbarDrag(DragUpdateDetails details) {
    final area = _toolbarDragArea;
    if (area.width <= 0 || area.height <= 0) return;
    final next = Offset(
      (_toolbarAnchor.dx + details.delta.dx / area.width).clamp(0.0, 1.0),
      (_toolbarAnchor.dy + details.delta.dy / area.height).clamp(0.0, 1.0),
    );
    if (next == _toolbarAnchor) return;
    setState(() => _toolbarAnchor = next);
  }

  /// 松手后记住位置，下次进入画板时沿用。
  void _onToolbarDragEnd() {
    unawaited(AppSettings.setToolbarAnchor(_toolbarAnchor));
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
              key: _layersButtonKey,
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
                if (action == 'export') unawaited(_openExport());
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                // 「清空当前图层」已移入图层面板（那儿能看到当前层是谁，
                // 清空前也有二次确认）。这里只保留导出。
                const PopupMenuItem<String>(
                  value: 'export',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.ios_share, size: 20),
                    title: Text('导出'),
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
                  if (_session != null) _buildTransformBar(),
                ],
              ),
      ),
    );
  }

  /// 变换操作条：明确要求确认才落笔，避免「松手即生效」带来的误改。
  Widget _buildTransformBar() {
    final theme = Theme.of(context);
    final wide = _session?.layerWide ?? false;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 20,
      child: Center(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    wide ? '整层变换' : '选区变换',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const Key('transform-flip-h'),
                        onPressed: () => _flipSelection(horizontal: true),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('水平翻转'),
                      ),
                      TextButton(
                        key: const Key('transform-flip-v'),
                        onPressed: () => _flipSelection(horizontal: false),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('垂直翻转'),
                      ),
                      TextButton(
                        key: const Key('transform-values'),
                        onPressed: _promptTransformValues,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('数值'),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const Key('transform-cancel'),
                        onPressed: _cancelSession,
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const Key('transform-commit'),
                        onPressed: _commitSession,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('完成'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
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

  /// 工具面板：默认贴左缘、垂直居中，可拖动并记住位置。
  ///
  /// 尺寸随屏幕短边自适应（见 [_ToolbarMetrics]），但始终是覆盖层——
  /// 面板变宽、变窄或被拖到别处都不会改变下方文档的矩形。
  ///
  /// 定位用 `Align` + `FractionalOffset` 而不是 `Positioned`：`Align` 只会在
  /// 父级范围内摆放子级，锚点又被夹在 `0~1`，因此面板永远不可能被拖出屏幕，
  /// 也不需要测量面板尺寸。
  Widget _buildBrushPanel() {
    final metrics = _ToolbarMetrics.fromScreen(MediaQuery.sizeOf(context));
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 记下「扣除外边距后的可用区域」，拖动时用它把像素位移换算成归一化增量。
          // 这是构建期派生值，不触发重建。
          _toolbarDragArea = Size(
            math.max(0, constraints.maxWidth - metrics.margin * 2),
            math.max(0, constraints.maxHeight - metrics.margin * 2),
          );
          return Padding(
            padding: EdgeInsets.all(metrics.margin),
            child: Align(
              alignment: FractionalOffset(_toolbarAnchor.dx, _toolbarAnchor.dy),
              child: _BrushPanel(
                key: _panelKey,
                metrics: metrics,
                selectedTool: _tool,
                onSelectTool: _selectTool,
                onLongPressTool: _openToolSettings,
                onDragToolbar: _onToolbarDrag,
                onDragToolbarEnd: _onToolbarDragEnd,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 选中工具。再次点按当前工具时打开它的设置——长按是显式入口，
  /// 点按已激活工具是符合直觉的隐含入口，两者都指向同一个面板。
  void _selectTool(CanvasTool tool) {
    if (tool == _tool) {
      unawaited(_openToolSettings(tool));
      return;
    }
    // 换工具视为结束当前变换：提交而不是丢弃（「所见即所存」）。
    _commitSession();
    setState(() {
      _tool = tool;
      if (tool.paints) _lastPaintTool = tool;
    });
  }

  /// 长按工具（或再次点按已选中的工具）：在工具栏旁边弹出设置气泡。
  ///
  /// 四类工具的入口一致、内容不同：画笔/橡皮是笔触参数，选区是「对选区的动作」，
  /// 吸管没有可调项，因此给一条一次性提示而不是空面板。
  Future<void> _openToolSettings(CanvasTool tool) async {
    final anchor = _toolbarGlobalRect();
    if (anchor == null) return;

    if (tool == CanvasTool.lasso) {
      await _openSelectionBubble(anchor);
      return;
    }
    if (tool == CanvasTool.eyedropper) {
      _showHint('吸管：点按画面取色，取完回到上一个绘画工具');
      return;
    }

    final kind = tool.strokeKind;
    if (kind == null) return;

    await showGeneralDialog<void>(
      context: context,
      // 遮罩由气泡自己画：需要在关闭时同时处理「点外部」和「尝试拖动工具栏」，
      // 而 barrierDismissible 只会无参 pop，拿不到这些事件。
      barrierDismissible: false,
      barrierLabel: '关闭工具设置',
      barrierColor: Colors.transparent,
      transitionDuration: _bubbleDuration,
      // 动画由气泡自己施加：它知道自己在工具栏的哪一侧，因此能把缩放锚点
      // 放在朝向工具栏的那条边上。交给 transitionBuilder 只能绕整页缩放。
      pageBuilder: (dialogContext, animation, _) => ToolSettingsBubble(
        tool: kind,
        initial: _settings[tool]!,
        anchor: anchor,
        animation: animation,
        onChanged: (value) => _applyToolSettings(tool, value),
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  /// 选区工具的气泡：显示命中数量，并给出「删除选中 / 取消选区」两个动作。
  Future<void> _openSelectionBubble(Rect anchor) async {
    final session = _session;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '关闭选区设置',
      barrierColor: Colors.transparent,
      transitionDuration: _bubbleDuration,
      pageBuilder: (dialogContext, animation, _) => SelectionBubble(
        anchor: anchor,
        selectedCount: session?.selectedIds.length ?? 0,
        hasSession: session != null,
        mode: _selectionMode,
        animation: animation,
        // 模式切换不需要关气泡：它是「下次圈选怎么合并」的设置，
        // 与当前选区无关，改完直接圈才顺手。
        onModeChanged: (mode) => setState(() => _selectionMode = mode),
        onInvert: () {
          Navigator.of(dialogContext).pop();
          _invertSelection();
        },
        onSplit: () {
          Navigator.of(dialogContext).pop();
          _splitSelection();
        },
        onDelete: () {
          Navigator.of(dialogContext).pop();
          _deleteSelection();
        },
        onClear: () {
          Navigator.of(dialogContext).pop();
          _cancelSession();
        },
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  /// 应用气泡里的改动。
  ///
  /// 只更新「当前工具参数」：已画笔画的外观由自身标记决定（ADR-019），
  /// 因此不需要让渲染缓存失效——这一点与上一轮全局重绘的做法相反。
  void _applyToolSettings(CanvasTool tool, ToolSettings value) {
    if (!mounted) return;
    setState(() {
      _settings[tool] = value;
      // 活动笔画（若恰好存在）按新参数重绘。
      _activeRevision++;
    });
  }

  // ---- 选区与变换 ----

  /// 归一化坐标 → 本地坐标（含视口变换）。
  Offset _normalizedToLocal(Offset normalized) {
    final rect = _documentRect;
    return _viewport.toScreen(
      Offset(
        rect.left + normalized.dx * rect.width,
        rect.top + normalized.dy * rect.height,
      ),
      rect,
    );
  }

  /// 本地坐标 → 归一化坐标，**不夹到 0~1**。
  ///
  /// 绘制用的 [_toNormalized] 会把点夹在纸面内（笔画不能跑到纸外），
  /// 而套索与变换必须允许越界：用户可能想圈住纸外的空白来平移内容。
  Offset _localToNormalizedRaw(Offset local) {
    final rect = _documentRect;
    if (rect.isEmpty) return Offset.zero;
    final doc = _viewport.toDocument(local, rect);
    return Offset(
      (doc.dx - rect.left) / rect.width,
      (doc.dy - rect.top) / rect.height,
    );
  }

  List<Offset>? _lassoLocal() {
    final points = _lassoPoints;
    if (points == null || points.isEmpty) return null;
    return <Offset>[for (final point in points) _normalizedToLocal(point)];
  }

  /// 变换框四角（本地坐标）。空列表表示没有可画的框。
  List<Offset> _sessionCorners() {
    final session = _session;
    if (session == null) return const <Offset>[];
    final bounds = session.bounds;
    if (bounds.isEmpty) return const <Offset>[];
    return <Offset>[
      _normalizedToLocal(bounds.topLeft),
      _normalizedToLocal(bounds.topRight),
      _normalizedToLocal(bounds.bottomRight),
      _normalizedToLocal(bounds.bottomLeft),
    ];
  }

  static Offset _quadCenter(List<Offset> corners) =>
      (corners[0] + corners[2]) / 2;

  static double _angleAround(Offset center, Offset point) =>
      math.atan2(point.dy - center.dy, point.dx - center.dx);

  // ---- 像素选区（位图图层） ----
  //
  // 与矢量选区的分工：矢量命中的是整条笔画，提交时算一次点列的 before/after；
  // 像素命中的是一块蒙版，提交时重采样写回瓦片。两套语义差异太大，因此各自
  // 独立成一条路径，只在「套索手势」这一层共用。

  /// 位图图层上的套索按下：落在选区内就开始拖动，落在选区外就重新圈。
  void _beginRasterSelectionPointer(Offset local) {
    final surface = _engine.activeLayer.raster;
    if (surface == null) return;

    final pixel = _toRasterPixel(local, surface);
    final mask = _rasterMask;
    if (mask != null && mask.contains(pixel.dx.floor(), pixel.dy.floor())) {
      _startRasterSelectionDrag(pixel);
      return;
    }

    // 圈新选区：旧浮动内容先落地，避免它跨手势挂着不提交。
    _commitRasterSelection();
    _rasterMask = null;
    _startLasso(local);
  }

  /// 首次拖动才把内容「提起」：只是圈一下又放开不该改动任何像素。
  void _startRasterSelectionDrag(Offset pixel) {
    final surface = _engine.activeLayer.raster;
    final mask = _rasterMask;
    if (surface == null || mask == null) return;

    var session = _rasterSelection;
    if (session == null) {
      session = RasterSelectionSession.lift(
        layerId: _engine.activeLayerId,
        surface: surface,
        mask: mask,
      );
      if (session == null) return;
      _rasterSelection = session;
      _rasterDragBase = PatchTransform.identity;
      unawaited(_loadRasterFloatImage(session.patch));
      // 源区域已被清空，整层瓦片都要重传。
      _rasterRenderer.invalidateAll(surface);
      unawaited(_flushRaster());
      _showHint('拖动以移动选区内容');
    } else {
      _rasterDragBase = session.transform;
    }

    _rasterDragOrigin = pixel;
    setState(() => _floatingRevision++);
  }

  void _updateRasterSelectionDrag(Offset local) {
    final session = _rasterSelection;
    final surface = _engine.activeLayer.raster;
    final origin = _rasterDragOrigin;
    if (session == null || surface == null || origin == null) return;

    // 每帧都用「起始参数 + 累计位移」重算，不做逐帧累加：后者在长距离拖动
    // 会因为浮点误差慢慢漂移，松手位置与手指对不上。
    final delta = _toRasterPixel(local, surface) - origin;
    session.transform = _rasterDragBase.copyWith(
      dx: _rasterDragBase.dx + delta.dx,
      dy: _rasterDragBase.dy + delta.dy,
    );
    setState(() => _floatingRevision++);
  }

  /// 提交浮动内容：写回像素并记一条撤销记录。
  ///
  /// 没有移动过就整体还原——`lift` 已经清空了源区域，此时只有换回快照才能
  /// 保证「圈一下又放开」不损伤任何像素，也不留下无意义的撤销步骤。
  void _commitRasterSelection() {
    final session = _rasterSelection;
    _rasterSelection = null;
    _rasterDragOrigin = null;
    _rasterDragBase = PatchTransform.identity;
    _disposeRasterFloatImage();
    if (session == null) return;

    final surface = _engine.activeLayer.raster;
    if (surface == null || !identical(surface, session.surface)) return;

    if (!session.isMoved) {
      _engine.activeLayer.raster = session.restoreTarget;
      _rasterRenderer.invalidateAll(session.restoreTarget);
      unawaited(_flushRaster());
      setState(() {});
      return;
    }

    final touched = session.commit();
    // 选区跟着内容一起走，用户才能接着拖同一块。
    _rasterMask = _rasterMask?.translated(
      session.transform.dx.round(),
      session.transform.dy.round(),
    );
    _rasterRenderer.invalidateTiles(surface, touched);
    unawaited(_flushRaster());
    _engine.commitRasterStroke(session.before);
    setState(() => _floatingRevision++);
    _scheduleSave();
    _scheduleTileFlush();
  }

  /// 放弃正在拖动的像素选区（双指介入、结构变更、页面销毁）。
  void _cancelRasterSelection() {
    final session = _rasterSelection;
    _rasterSelection = null;
    _rasterDragOrigin = null;
    _rasterDragBase = PatchTransform.identity;
    _disposeRasterFloatImage();
    if (session == null) return;

    final layer = _engine.activeLayer;
    if (!identical(layer.raster, session.surface)) return;
    layer.raster = session.restoreTarget;
    _rasterRenderer.invalidateAll(session.restoreTarget);
    unawaited(_flushRaster());
  }

  void _disposeRasterFloatImage() {
    _rasterFloatImage?.dispose();
    _rasterFloatImage = null;
  }

  /// 把 patch 烘焙成一张图，供拖动时由 GPU 直接合成。
  Future<void> _loadRasterFloatImage(RasterPatch patch) async {
    if (patch.width <= 0 || patch.height <= 0) return;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      patch.toImageRgba(),
      patch.width,
      patch.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    // 解码期间可能已经松手或换了选区：此时这张图没人要，直接释放。
    if (!mounted || !identical(_rasterSelection?.patch, patch)) {
      image.dispose();
      return;
    }
    _disposeRasterFloatImage();
    setState(() {
      _rasterFloatImage = image;
      _floatingRevision++;
    });
  }

  /// 套索闭合后栅格化成蒙版。
  void _commitRasterLasso(List<Offset> points) {
    final surface = _engine.activeLayer.raster;
    if (surface == null) return;

    // 点列是归一化坐标（相对文档矩形），乘以位图尺寸即得图层像素坐标。
    final polygon = <Offset>[
      for (final p in points) Offset(p.dx * surface.width, p.dy * surface.height),
    ];
    final mask = RasterMask.fromPolygon(surface.width, surface.height, polygon);
    if (mask.isEmpty) {
      _rasterMask = null;
      _showHint('未选中像素');
      setState(() {});
      return;
    }

    _rasterMask = mask;
    _showHint('已选中 ${mask.selectedPixels.round()} 像素，拖动可移动');
    setState(() {});
  }

  /// 构造给 `paintDocument` 的浮动内容。
  ///
  /// 矩阵链从右往左作用：先平移到 patch 中心为原点，再镜像、缩放、旋转，
  /// 最后落到图层的目标位置，并叠加「图层像素 → 画布逻辑坐标」的缩放与偏移。
  /// 由 `Float64List` 直接给出（列主序），避开 `Matrix4` 各版本的 API 变动。
  FloatingRaster? _buildFloatingRaster(Rect rect) {
    final session = _rasterSelection;
    final image = _rasterFloatImage;
    if (session == null || image == null || rect.isEmpty) return null;

    final surface = session.surface;
    final patch = session.patch;
    final t = session.transform;
    final sx = rect.width / surface.width;
    final sy = rect.height / surface.height;
    final halfW = patch.width / 2;
    final halfH = patch.height / 2;
    final cos = math.cos(t.rotation);
    final sin = math.sin(t.rotation);
    final flipX = t.flipX ? -1.0 : 1.0;
    final flipY = t.flipY ? -1.0 : 1.0;

    // 图层像素坐标下的线性部分。
    final a0 = t.scale * flipX * cos;
    final b0 = -t.scale * flipY * sin;
    final c0 = t.scale * flipX * sin;
    final d0 = t.scale * flipY * cos;

    final cx = patch.left + halfW + t.dx;
    final cy = patch.top + halfH + t.dy;
    final tx0 = cx - (a0 * halfW + b0 * halfH);
    final ty0 = cy - (c0 * halfW + d0 * halfH);

    return FloatingRaster(
      layerId: session.layerId,
      image: image,
      mapping: Float64List.fromList(<double>[
        sx * a0, sy * c0, 0, 0, //
        sx * b0, sy * d0, 0, 0, //
        0, 0, 1, 0, //
        sx * tx0 + rect.left, sy * ty0 + rect.top, 0, 1, //
      ]),
      src: Rect.fromLTWH(
        0,
        0,
        patch.width.toDouble(),
        patch.height.toDouble(),
      ),
    );
  }

  /// 套索工具下的按下：先判手柄，再判移动，最后才是「重新起一个选区」。
  void _beginSelectionPointer(Offset local) {
    _dragStartLocal = local;

    // 位图图层的选区语义是**像素蒙版**，与矢量的「整笔命中」完全不同，
    // 因此分开走各自的状态机（`_beginRasterSelectionPointer`）。
    if (_engine.activeLayer.isRaster) {
      _beginRasterSelectionPointer(local);
      return;
    }

    final session = _session;

    // 加选/减选要合并的「旧选区」必须在**按下这一刻**记下来：下面框外按下会把旧会话
    // 提交并清空，等到抬手再读 `_session` 就已经是 null，合并基数会永远是空集。
    // 只认同图层——换了图层，旧 id 指向的笔画已不在当前层。
    _lassoBaseIds = session != null && session.layerId == _engine.activeLayerId
        ? Set<int>.of(session.selectedIds)
        : const <int>{};

    if (session == null) {
      _startLasso(local);
      return;
    }

    final corners = _sessionCorners();
    if (corners.length == 4) {
      final center = _quadCenter(corners);
      if ((local - rotateHandleFor(corners)).distance <=
          SelectionMetrics.hitRadius) {
        _dragMode = TransformDragMode.rotate;
        _dragStartTransform = session.transform;
        _dragStartRotation = _angleAround(center, local);
        return;
      }
      for (final corner in corners) {
        if ((local - corner).distance <= SelectionMetrics.hitRadius) {
          _dragMode = TransformDragMode.scale;
          _dragStartTransform = session.transform;
          _dragStartScale = math.max(1.0, (local - center).distance);
          return;
        }
      }
      if (quadContains(corners, local)) {
        _dragMode = TransformDragMode.move;
        _dragStartTransform = session.transform;
        return;
      }
    }

    // 框外按下：先把已有变换落地，再开始一个新选区——一次点击只做一件事。
    _commitSession();
    _startLasso(local);
  }

  void _startLasso(Offset local) {
    _selectionPath = null;
    _lassoPoints = <Offset>[_localToNormalizedRaw(local)];
    _dragMode = TransformDragMode.draw;
    setState(() {});
  }

  void _updateSelectionDrag(Offset local) {
    // 位图选区拖动不用 `_dragMode`：那套枚举描述的是矢量的手柄语义，
    // 而像素选区只有平移一种自由度。用「有没有拖动起点」来区分最直接。
    if (_rasterDragOrigin != null) {
      _updateRasterSelectionDrag(local);
      return;
    }

    final session = _session;
    switch (_dragMode) {
      case TransformDragMode.none:
      case TransformDragMode.draw:
        if (_dragMode == TransformDragMode.draw) {
          _lassoPoints?.add(_localToNormalizedRaw(local));
          setState(() {});
        }
      case TransformDragMode.move:
        if (session == null) return;
        final delta =
            _localToNormalizedRaw(local) - _localToNormalizedRaw(_dragStartLocal);
        session.transform = _dragStartTransform.copyWith(
          offset: _dragStartTransform.offset + delta,
        );
        _applyTransformPreview();
      case TransformDragMode.scale:
        if (session == null) return;
        final center = _quadCenter(_sessionCorners());
        final factor = (local - center).distance / _dragStartScale;
        session.transform = _dragStartTransform.copyWith(
          scale: (_dragStartTransform.scale * factor).clamp(0.05, 20.0),
        );
        _applyTransformPreview();
      case TransformDragMode.rotate:
        if (session == null) return;
        final center = _quadCenter(_sessionCorners());
        final angle = _angleAround(center, local);
        session.transform = _dragStartTransform.copyWith(
          rotation:
              _dragStartTransform.rotation + (angle - _dragStartRotation),
        );
        _applyTransformPreview();
    }
  }

  void _finishSelectionDrag() {
    // 像素选区抬手即提交：它没有手柄、也没有二次微调的操作条，
    // 浮动状态跨手势挂着只会让导出 / 保存读到「看得见但还没落地」的内容。
    if (_rasterDragOrigin != null) {
      _commitRasterSelection();
      return;
    }

    final mode = _dragMode;
    _dragMode = TransformDragMode.none;
    if (mode == TransformDragMode.draw) {
      _commitLasso();
      return;
    }
    if (mode == TransformDragMode.none) return;
    // 松开手柄后不提交：用户还要看结果、可能继续微调，确认由底部操作条负责。
    setState(() {});
  }

  /// 闭合套索并按命中笔画建立变换会话。
  void _commitLasso() {
    final points = _lassoPoints;
    _lassoPoints = null;
    if (points == null || points.length < 3) {
      setState(() {});
      return;
    }

    // 位图图层：把点列栅格化成覆盖率蒙版，走像素选区那条路。
    if (_engine.activeLayer.isRaster) {
      _commitRasterLasso(points);
      return;
    }

    final layerId = _engine.activeLayerId;
    final hits = strokesInPolygon(_engine.activeLayer.strokes, points);

    // 合并基数用的是**按下时**记下的旧选区（见 `_beginSelectionPointer`），不是此刻的
    // `_session`——后者在框外按下时已经被提交并清掉了。
    final base = _lassoBaseIds;
    final next = switch (_selectionMode) {
      SelectionMode.replace => hits,
      SelectionMode.add => <int>{...base, ...hits},
      SelectionMode.subtract => base.difference(hits),
    };

    if (next.isEmpty) {
      setState(() {
        _selectionPath = null;
        _session = null;
      });
      _showHint(
        _selectionMode == SelectionMode.subtract ? '选区已减空' : '未选中笔画',
      );
      return;
    }

    setState(() {
      _selectionPath = List<Offset>.of(points);
      _session = TransformSession(
        layerId: layerId,
        before: _engine.snapshotStrokes(layerId),
        selectedIds: next,
        layerWide: false,
      );
    });
  }

  /// 反向选择：取当前图层全部笔画的补集。
  ///
  /// 补集会丢掉原来那条套索的形状（它已经不描述新选区了），因此清除套索路径，
  /// 只保留变换框——框的位置由真实包围盒算出，不会误导。
  void _invertSelection() {
    final session = _session;
    if (session == null) {
      _showHint('先圈出一个选区');
      return;
    }
    if (!session.isPristine) {
      _showHint('先完成或取消当前变换');
      return;
    }

    final layer = _engine.layers.firstWhere((item) => item.id == session.layerId);
    final all = <int>{for (final stroke in layer.strokes) stroke.id};
    final next = all.difference(session.selectedIds);
    if (next.isEmpty) {
      _showHint('反向后没有内容');
      return;
    }

    setState(() {
      _selectionPath = null;
      _session = TransformSession(
        layerId: session.layerId,
        before: _engine.snapshotStrokes(session.layerId),
        selectedIds: next,
        layerWide: false,
      );
    });
  }

  /// 切分到选区边界：把被圈住的笔画在边界处切开。
  ///
  /// 破坏性操作——原笔画被替换为若干碎片，各自的 id 都是新的。因此要求「变换未动过」：
  /// 一旦用户已经拖动过，先落地再加选/切分会让语义变得难以解释。
  void _splitSelection() {
    final session = _session;
    final path = _selectionPath;
    if (session == null || path == null) {
      _showHint('先圈出一个选区');
      return;
    }
    if (!session.isPristine) {
      _showHint('先完成或取消当前变换');
      return;
    }

    final created = _engine.splitStrokes(session.layerId, session.selectedIds, path);
    if (created == 0) {
      _showHint('没有跨边界的笔画');
      return;
    }

    setState(() {
      _session = null;
      _selectionPath = null;
      _dragMode = TransformDragMode.none;
    });
    unawaited(_journal.clear(widget.project.id));
    _scheduleSave();
    _showHint(created == 1 ? '已按选区裁剪' : '已切分为 $created 段');
  }

  /// 翻转当前选区（或整层）。
  void _flipSelection({required bool horizontal}) {
    final session = _session;
    if (session == null) return;
    setState(() {
      session.transform = session.transform.copyWith(
        flipX: horizontal ? !session.transform.flipX : session.transform.flipX,
        flipY: horizontal ? session.transform.flipY : !session.transform.flipY,
      );
    });
    _applyTransformPreview();
  }

  /// 数值输入：角度与缩放按**绝对值**解释，而不是在当前值上叠加。
  ///
  /// 绝对值更可预期：用户输入 -30° 就是想让它斜 -30°，而不是「再转 -30°」。
  Future<void> _promptTransformValues() async {
    final session = _session;
    if (session == null) return;

    final rotation = TextEditingController(
      text: (session.transform.rotation * 180 / math.pi).toStringAsFixed(0),
    );
    final scale = TextEditingController(
      text: (session.transform.scale * 100).toStringAsFixed(0),
    );

    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('变换数值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('transform-rotation-field'),
              controller: rotation,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: '旋转角度（度）',
                helperText: '顺时针为正，-180 ~ 180',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('transform-scale-field'),
              controller: scale,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '缩放（%）',
                helperText: '10 ~ 1000，100 表示不缩放',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('transform-values-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('应用'),
          ),
        ],
      ),
    );

    if (applied != true || !mounted) return;

    final degrees = double.tryParse(rotation.text.trim());
    final percent = double.tryParse(scale.text.trim());
    setState(() {
      session.transform = session.transform.copyWith(
        rotation: degrees == null
            ? session.transform.rotation
            : degrees.clamp(-180.0, 180.0) * math.pi / 180,
        scale: percent == null
            ? session.transform.scale
            : (percent / 100).clamp(0.05, 20.0),
      );
    });
    _applyTransformPreview();
  }

  /// 把当前变换参数写进引擎（不进撤销栈），画面因此实时跟随手指。
  void _applyTransformPreview() {
    final session = _session;
    if (session == null) return;
    setState(() {
      _engine.setStrokes(session.layerId, session.strokes());
    });
  }

  /// 提交变换：一条撤销记录，然后清掉选区。
  void _commitSession() {
    final session = _session;
    if (session == null) {
      if (_selectionPath != null) setState(() => _selectionPath = null);
      return;
    }
    if (session.isPristine) {
      // 没动过就不该在撤销栈里留下一条「没有任何变化」的记录。
      _cancelSession();
      return;
    }

    _engine.commitStrokes(session.layerId, session.before);
    setState(() {
      _session = null;
      _selectionPath = null;
      _dragMode = TransformDragMode.none;
    });
    // 笔画位置变了，日志里的「第几层」不再可信，直接清空，靠随后的完整保存兜底。
    unawaited(_journal.clear(widget.project.id));
    _scheduleSave();
  }

  /// 放弃变换：把笔画恢复成快照，选区一并清掉。
  void _cancelSession() {
    final session = _session;
    if (session != null && !session.isPristine) {
      _engine.setStrokes(session.layerId, session.before);
    }
    setState(() {
      _session = null;
      _selectionPath = null;
      _lassoPoints = null;
      _dragMode = TransformDragMode.none;
    });
  }

  /// 删除选中的笔画（可撤销）。
  void _deleteSelection() {
    final session = _session;
    if (session == null) return;
    final count = session.selectedIds.length;

    setState(() {
      _engine.removeStrokes(session.layerId, session.selectedIds);
      _session = null;
      _selectionPath = null;
      _dragMode = TransformDragMode.none;
    });
    unawaited(_journal.clear(widget.project.id));
    _scheduleSave();
    _showHint('已删除 $count 笔');
  }

  /// 从图层面板进入「整层变换」：选中该层全部笔画，交给同一套手柄。
  void _beginLayerTransform(String layerId) {
    final before = _engine.snapshotStrokes(layerId);
    if (before.isEmpty) {
      _showHint('该图层没有内容');
      return;
    }
    setState(() {
      // 手柄与拖动逻辑属于套索工具，因此切换过去，避免「看得见手柄却拖不动」。
      _tool = CanvasTool.lasso;
      _lassoPoints = null;
      _selectionPath = null;
      _session = TransformSession(
        layerId: layerId,
        before: before,
        selectedIds: <int>{for (final stroke in before) stroke.id},
        layerWide: true,
      );
      _dragMode = TransformDragMode.none;
    });
    _showHint('整层变换：拖动框内移动，拖角缩放，拖顶部圆点旋转');
  }

  // ---- 吸管 ----

  /// 在指定位置取样「所见即所得」的颜色。
  ///
  /// 做法是把整篇内容画到 1×1 的画布上，只取这一个像素：比整幅光栅化便宜得多，
  /// 而且取到的就是合成后的颜色（含图层不透明度与混合模式），
  /// 与「屏幕上看到的那个颜色」一致。
  Future<void> _pickColorAt(Offset local) async {
    final rect = _documentRect;
    if (rect.isEmpty) return;

    final normalized = _localToNormalizedRaw(local);
    final doc = Offset(
      rect.left + normalized.dx * rect.width,
      rect.top + normalized.dy * rect.height,
    );

    final picked = await sampleColorAt(
      picture: _ensurePicture(rect),
      docPoint: doc,
      fallback: Color(widget.project.document.backgroundArgb),
    );

    if (!mounted) return;
    setState(() {
      _settings[CanvasTool.brush] =
          _settings[CanvasTool.brush]!.copyWith(color: picked);
      _tool = _lastPaintTool;
    });

    final hex = picked.toARGB32().toRadixString(16).padLeft(8, '0');
    _showHint('已取色 #${hex.substring(2).toUpperCase()}');
  }

  /// 工具栏面板当前的全局矩形，用作气泡的锚点。
  Rect? _toolbarGlobalRect() => _globalRect(_panelKey);

  /// 取某个组件的全局矩形；尚未布局时返回 null。
  Rect? _globalRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
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
        // 「是不是橡皮」由 Rust 的工具参数决定，不在本地另立一份判断。
        final erasing = _profile.erases && _smoother != null;

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
                  activeColor: _paintSettings.color.toARGB32(),
                  // 与已提交笔画共用同一换算，避免极细笔画在提交前后差 1px。
                  activeWidth: strokeWidthPx(
                    _paintSettings.widthRatio,
                    rect.shortestSide,
                  ),
                  activeErase: erasing,
                  activeRevision: _activeRevision,
                  viewport: _viewport,
                  activeBlend: _engine.activeLayer.blendMode,
                  activePressure: _paintSettings.pressureEnabled,
                  rasterSource: _rasterRenderer,
                ),
              ),
              // 选区与变换框画在内容之上、指针层之下：它们不参与命中，
              // 手势仍由外层 Listener 统一处理。
              SelectionLayer(
                lasso: _lassoLocal(),
                corners: _session == null ? null : _sessionCorners(),
                showHandles: _session != null,
                accent: theme.colorScheme.primary,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 取（或重建）已完成笔画的渲染缓存。
  ///
  /// 缓存键为「笔画版本 + 文档矩形」：
  /// - 旋转或分屏会改变矩形，触发一次重建，之后恢复稳定；
  /// - 绘制过程中矩形不变，不会重复重建；
  /// - 压感开关**不再需要**进键：已提交笔画的外观光看自身标记，改开关不会改变它们。
  ui.Picture _ensurePicture(Rect rect) {
    final cached = _committedPicture;
    if (cached != null &&
        _pictureRevision == _engine.revision &&
        _pictureRasterRevision == _rasterRevision &&
        _pictureFloatingRevision == _floatingRevision &&
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
        rasterSource: _rasterRenderer,
        floating: _buildFloatingRaster(rect),
      );
    }
    final picture = recorder.endRecording();
    _committedPicture = picture;
    _pictureRevision = _engine.revision;
    _pictureRasterRevision = _rasterRevision;
    _pictureFloatingRevision = _floatingRevision;
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
    required this.activePressure,
    required this.rasterSource,
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

  /// 活动笔画是否按压感绘制（取当前工具的开关）。
  final bool activePressure;

  /// 位图图层的图像来源。只在「擦除中整篇重绘」这条路径上用到——
  /// 常规路径已经把位图画进 [picture] 缓存了。
  final RasterTileSource rasterSource;

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
        rasterSource: rasterSource,
        activeLayerId: activeLayerId,
        activePoints: activePoints,
        activeColor: activeColor,
        activeWidth: activeWidth,
        activeErase: true,
        activePressure: activePressure,
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
    paintStrokePath(
      canvas,
      rect,
      activePoints,
      activeColor,
      activeWidth,
      pressure: activePressure,
    );
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
      oldDelegate.activeBlend != activeBlend ||
      oldDelegate.activePressure != activePressure;
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

/// 悬浮工具面板：默认左侧停靠，可拖动，只承载「工具」这一层。
///
/// 颜色、粗细与压感不再常驻——它们属于工具参数，长按工具图标（或再次点按
/// 已选中的工具）后在该工具的设置面板里调整。这样工具栏的长度只与工具数量相关。
class _BrushPanel extends StatelessWidget {
  const _BrushPanel({
    super.key,
    required this.metrics,
    required this.selectedTool,
    required this.onSelectTool,
    required this.onLongPressTool,
    required this.onDragToolbar,
    required this.onDragToolbarEnd,
  });

  final _ToolbarMetrics metrics;
  final CanvasTool selectedTool;
  final ValueChanged<CanvasTool> onSelectTool;
  final ValueChanged<CanvasTool> onLongPressTool;
  final ValueChanged<DragUpdateDetails> onDragToolbar;
  final VoidCallback onDragToolbarEnd;

  static const int _columns = 2;

  /// 工具栏里的工具。顺序即网格顺序（两列，自上而下、自左而右）。
  ///
  /// 图标放在 UI 层而不是枚举里：`CanvasTool` 属于模型，不该依赖 `assets/`。
  static const List<({CanvasTool kind, String icon, String label})> _tools = [
    (kind: CanvasTool.brush, icon: AppIcons.brush, label: '画笔'),
    (kind: CanvasTool.eraser, icon: AppIcons.eraser, label: '橡皮'),
    (kind: CanvasTool.lasso, icon: AppIcons.lasso, label: '选区'),
    (kind: CanvasTool.eyedropper, icon: AppIcons.eyedropper, label: '吸管'),
  ];

  /// 网格宽度：`列数 × 格子 + 列间距`。拖动条取同一宽度，视觉上像一条把手。
  double get _gridWidth =>
      metrics.cell * _columns + metrics.gap * (_columns - 1);

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
            _ToolbarDragHandle(
              metrics: metrics,
              width: _gridWidth,
              onDragUpdate: onDragToolbar,
              onDragEnd: onDragToolbarEnd,
            ),
            SizedBox(height: metrics.gap * 0.7),
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

/// 工具栏顶部的拖动把手：一条「三个小点」的横条。
///
/// 之所以做成独立把手而不是「整块面板可拖」：面板上全是工具按钮，让它们同时
/// 承担拖动必然误触；把手只有 20dp 高，牺牲的命中面积最小。
///
/// 拖动是**立即生效**的 pan，而不是长按后拖动——长按要等 500ms，拖动一个
/// 悬浮面板时这种延迟会被当成「没反应」。
class _ToolbarDragHandle extends StatelessWidget {
  const _ToolbarDragHandle({
    required this.metrics,
    required this.width,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final _ToolbarMetrics metrics;
  final double width;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = (metrics.cell * 0.42).clamp(16.0, 24.0);
    final dot = (metrics.cell * 0.075).clamp(2.5, 3.5);

    return Semantics(
      label: '拖动工具栏',
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          key: const Key('toolbar-drag-handle'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: onDragUpdate,
          onPanEnd: (_) => onDragEnd(),
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) SizedBox(width: dot * 1.8),
                    Container(
                      width: dot,
                      height: dot,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
