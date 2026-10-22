import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
import '../services/document_painter.dart';
import '../services/document_store.dart';
import '../services/drawing_engine.dart';
import '../services/exporter.dart';
import '../services/project_store.dart';
import '../services/stroke_smoother.dart';
import '../widgets/app_icon.dart';
import '../widgets/layers_bubble.dart';
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
    // 画笔默认开启压感：这是产品主张「笔触手感」的主要载体。
    ToolKind.brush: const ToolSettings(
      color: Color(0xFF000000),
      widthRatio: 0.01,
      pressureEnabled: true,
    ),
    // 橡皮默认粗一些、且不跟随压力：擦除需要的是稳定的覆盖范围，
    // 而不是笔锋——压力一变细，擦除会变得难以控制。
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
      erases: false,
    ),
    ToolKind.eraser: ToolProfile(
      smoothWindow: 3,
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

    final wasTransforming = _transforming;
    if (wasTransforming && _pointers.length < 2) _endTransform();
    // 只有所有手指都离开时才判定双指双击：中途抬手属于变换收尾，不算轻点。
    if (_pointers.isEmpty) _settleTouchGesture();

    if (wasTransforming) {
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
        // 画下这一刻的开关状态随笔画一起保存，之后改开关不影响它（ADR-019）。
        usesPressure: _activeSettings.pressureEnabled,
      );
    });
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
    if (_engine.undo()) _onDocumentChanged();
  }

  void _redo() {
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
  void _selectTool(ToolKind tool) {
    if (tool == _tool) {
      unawaited(_openToolSettings(tool));
      return;
    }
    setState(() => _tool = tool);
  }

  /// 长按工具（或再次点按已选中的工具）：在工具栏旁边弹出设置气泡。
  Future<void> _openToolSettings(ToolKind tool) async {
    final anchor = _toolbarGlobalRect();
    if (anchor == null) return;

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
        tool: tool,
        initial: _settings[tool]!,
        anchor: anchor,
        animation: animation,
        onChanged: (value) => _applyToolSettings(tool, value),
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  /// 应用气泡里的改动。
  ///
  /// 只更新「当前工具参数」：已画笔画的外观由自身标记决定（ADR-019），
  /// 因此不需要让渲染缓存失效——这一点与上一轮全局重绘的做法相反。
  void _applyToolSettings(ToolKind tool, ToolSettings value) {
    if (!mounted) return;
    setState(() {
      _settings[tool] = value;
      // 活动笔画（若恰好存在）按新参数重绘。
      _activeRevision++;
    });
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
                  activeColor: _activeSettings.color.toARGB32(),
                  // 与已提交笔画共用同一换算，避免极细笔画在提交前后差 1px。
                  activeWidth: strokeWidthPx(
                    _activeSettings.widthRatio,
                    rect.shortestSide,
                  ),
                  activeErase: erasing,
                  activeRevision: _activeRevision,
                  viewport: _viewport,
                  activeBlend: _engine.activeLayer.blendMode,
                  activePressure: _activeSettings.pressureEnabled,
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
  /// 缓存键为「笔画版本 + 文档矩形」：
  /// - 旋转或分屏会改变矩形，触发一次重建，之后恢复稳定；
  /// - 绘制过程中矩形不变，不会重复重建；
  /// - 压感开关**不再需要**进键：已提交笔画的外观光看自身标记，改开关不会改变它们。
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
    required this.activePressure,
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
  final ToolKind selectedTool;
  final ValueChanged<ToolKind> onSelectTool;
  final ValueChanged<ToolKind> onLongPressTool;
  final ValueChanged<DragUpdateDetails> onDragToolbar;
  final VoidCallback onDragToolbarEnd;

  static const int _columns = 2;

  /// 当前可用的绘画工具。后续扩容直接在这里追加。
  static const List<({ToolKind kind, String icon, String label})> _tools = [
    (kind: ToolKind.brush, icon: AppIcons.brush, label: '画笔'),
    (kind: ToolKind.eraser, icon: AppIcons.eraser, label: '橡皮'),
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
