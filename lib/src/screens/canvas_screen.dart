import 'package:flutter/material.dart';

import '../models/project.dart';
import '../models/stroke.dart';
import '../rust/api.dart' as rust;
import '../services/drawing_engine.dart';
import '../services/project_store.dart';

/// 工程画板：采集指针事件 → 交给 Rust 平滑/简化 → 渲染为笔触。
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.project});

  final DrawingProject project;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  final DrawingEngine _engine = DrawingEngine();

  /// 当前画笔颜色（ARGB）。
  Color _color = const Color(0xFF000000);

  /// 当前画笔粗细（逻辑像素）。
  double _width = 4.0;

  /// 正在绘制中的原始采样点（归一化坐标，尚未入栈）。
  final List<rust.StrokePoint> _activePoints = [];

  /// 当前被跟踪的指针 id（忽略第二根手指）。
  int? _activePointer;

  /// 当前笔画起点时间（用于计算点间时间戳）。
  int _strokeStartMs = 0;

  /// 画布逻辑尺寸，用于坐标归一化/还原。
  Size _canvasSize = Size.zero;

  static const List<Color> _palette = [
    Color(0xFF000000), // 黑
    Color(0xFFEF4444), // 红
    Color(0xFF3B82F6), // 蓝
    Color(0xFF22C55E), // 绿
    Color(0xFFF97316), // 橙
    Color(0xFFFFFFFF), // 白
  ];

  static const List<double> _strokeWidths = [2.0, 4.0, 8.0, 16.0];

  @override
  void initState() {
    super.initState();
    // 进入画板时刷新工程更新时间。
    ProjectStore().touchProject(widget.project.id);
  }

  // ---- 指针采集 ----

  void _onPointerDown(PointerDownEvent e) {
    if (_activePointer != null) return; // 已有一根手指在绘制
    _activePointer = e.pointer;
    _strokeStartMs = DateTime.now().millisecondsSinceEpoch;
    _activePoints
      ..clear()
      ..add(_toNormalized(e.localPosition, e.pressure));
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    _activePoints.add(_toNormalized(e.localPosition, e.pressure));
    setState(() {});
  }

  Future<void> _onPointerUp(PointerUpEvent e) async {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    if (_activePoints.isEmpty) return;

    final points = List<rust.StrokePoint>.from(_activePoints);
    _activePoints.clear();
    setState(() {});

    // 交给 Rust 处理（平滑 + 简化）后入栈。
    await _engine.addStroke(points, color: _color.toARGB32(), width: _width);
    if (mounted) setState(() {});
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

  void _undo() => setState(() => _engine.undo());

  void _redo() => setState(() => _engine.redo());

  void _clear() => setState(() => _engine.clear());

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
            onPressed: _engine.strokeCount > 0 ? _clear : null,
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(child: _buildCanvas()),
        ],
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
            Container(width: 1, height: 24, color: theme.colorScheme.outlineVariant),
            const SizedBox(width: 12),
            ..._strokeWidths.map(_buildWidthDot),
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

  Widget _buildWidthDot(double width) {
    final selected = width == _width;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: InkWell(
        onTap: () => setState(() => _width = width),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          child: Container(
            width: width + 4,
            height: width + 4,
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
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: CustomPaint(
            size: Size.infinite,
            painter: _StrokePainter(
              strokes: _engine.strokes,
              activePoints: _activePoints,
              activeColor: _color.toARGB32(),
              activeWidth: _width,
            ),
          ),
        );
      },
    );
  }
}

/// 把归一化笔画渲染到画布。
class _StrokePainter extends CustomPainter {
  _StrokePainter({
    required this.strokes,
    required this.activePoints,
    required this.activeColor,
    required this.activeWidth,
  });

  final List<Stroke> strokes;
  final List<rust.StrokePoint> activePoints;
  final int activeColor;
  final double activeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // 画布底色（纸张白）。
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );

    for (final stroke in strokes) {
      _drawPoints(canvas, size, stroke.points, stroke.color, stroke.width);
    }
    if (activePoints.isNotEmpty) {
      _drawPoints(canvas, size, activePoints, activeColor, activeWidth);
    }
  }

  void _drawPoints(
    Canvas canvas,
    Size size,
    List<rust.StrokePoint> points,
    int color,
    double width,
  ) {
    if (points.isEmpty) return;

    Offset toOffset(rust.StrokePoint p) =>
        Offset(p.x * size.width, p.y * size.height);

    if (points.length == 1) {
      // 单点笔画：画一个实心圆点。
      canvas.drawCircle(
        toOffset(points.first),
        width / 2,
        Paint()..color = Color(color),
      );
      return;
    }

    final paint = Paint()
      ..color = Color(color)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final path = Path()..moveTo(toOffset(points.first).dx, toOffset(points.first).dy);
    for (final p in points.skip(1)) {
      final o = toOffset(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) {
    // 骨架阶段每次重绘；后续可按笔画数量/版本号优化。
    return true;
  }
}
