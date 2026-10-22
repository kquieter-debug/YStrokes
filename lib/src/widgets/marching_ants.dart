import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 持续显示的选区轮廓：预烘焙 8 个相位的流动虚线。
///
/// ## 为什么不是每帧重算虚线
///
/// 真·蚂蚁线每帧都要跑一遍 `PathMetric.extractPath`。按 2000 屏幕像素周长、
/// 6+5 的短划周期算，就是一百八十来段路径截取——单次不算贵，但它是**每帧**
/// 都要付的，而且会把整层覆盖区重画一遍。
///
/// 这里把成本挪到「选区形状变化时」：按 8 个相位各烘焙一张 `ui.Picture`，
/// 运行时只是按定时器换索引、画一张缓存好的图。每帧的绘制指令数与相位无关，
/// 相位切换也不重建任何路径。代价是选区变了要重建 8 张（8 次描边，一次性）。
///
/// ## 为什么 8 个相位、120ms
///
/// 短划周期 11px，一个周期分成 8 步即 1.4px 的位移——肉眼看到的是连续滑动而不是
/// 跳格。120ms 换一帧约 8fps：蚂蚁线的移动本来就慢，再快只会让人分心，而且
/// 更高的换帧频率并不会让画面更顺滑，只会让定时器更忙。
class MarchingAnts extends StatefulWidget {
  const MarchingAnts({
    super.key,
    required this.points,
    required this.color,
    this.translation = Offset.zero,
    this.strokeWidth = 3,
  });

  /// 轮廓顶点（**屏幕坐标**，自动闭合）。
  ///
  /// 传空列表等于不画。坐标换算由调用方完成——这一层不需要知道视口存在。
  final List<Offset> points;

  final Color color;

  /// 整体平移（屏幕坐标）。
  ///
  /// 拖动选区时轮廓要跟着内容走，但**不能把平移烘焙进 [points]**：那会让
  /// 「几何变了」从而每帧重建 8 张相位图。平移在绘制时施加，几乎是免费的。
  final Offset translation;

  /// 白色垫底的宽度；虚线本身按 [strokeWidth] 的一半画。
  final double strokeWidth;

  @override
  State<MarchingAnts> createState() => _MarchingAntsState();
}

class _MarchingAntsState extends State<MarchingAnts> {
  /// 短划与间隙（屏幕像素）。两者之和即一个周期。
  static const double _dash = 6;
  static const double _gap = 5;
  static const double _period = _dash + _gap;

  /// 相位数量与切换间隔。
  static const int _phases = 8;
  static const Duration _interval = Duration(milliseconds: 120);

  Timer? _timer;
  int _phase = 0;

  /// 已烘焙的相位图，以及它们对应的几何/颜色。
  List<ui.Picture>? _baked;
  List<Offset>? _bakedPoints;
  Color? _bakedColor;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted) return;
      setState(() => _phase = (_phase + 1) % _phases);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _disposeBaked();
    super.dispose();
  }

  void _disposeBaked() {
    for (final picture in _baked ?? const <ui.Picture>[]) {
      picture.dispose();
    }
    _baked = null;
  }

  /// 几何或颜色变了才重建；否则复用上一批图。
  void _ensureBaked() {
    final points = widget.points;
    final stale = _baked == null ||
        _bakedColor != widget.color ||
        _bakedPoints == null ||
        !listEquals(_bakedPoints, points);
    if (!stale) return;

    _disposeBaked();
    _bakedPoints = List<Offset>.of(points);
    _bakedColor = widget.color;
    _baked = points.length < 3
        ? const <ui.Picture>[]
        : _bake(Path()..addPolygon(points, true));
  }

  List<ui.Picture> _bake(Path path) {
    // 先垫一条浅色实线，再叠深色虚线：纸面可深可浅，单色必然在某种底色上消失。
    final underlay = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = widget.strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.75)
      ..isAntiAlias = true;
    final dashes = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = widget.strokeWidth * 0.47
      ..color = widget.color
      ..isAntiAlias = true;

    // 每个轮廓的相位都从 0 开始：多段轮廓（自相交的套索）各自流动，
    // 比强行连续更好看，也不必去累加各段的长度。
    final metrics = path.computeMetrics().toList();

    return <ui.Picture>[
      for (var phase = 0; phase < _phases; phase++)
        _bakeOne(
          path,
          metrics,
          underlay,
          dashes,
          phase * _period / _phases,
        ),
    ];
  }

  ui.Picture _bakeOne(
    Path path,
    List<ui.PathMetric> metrics,
    Paint underlay,
    Paint dashes,
    double offset,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawPath(path, underlay);
    canvas.drawPath(_dashed(metrics, offset), dashes);
    return recorder.endRecording();
  }

  /// 按 [offset] 平移后的虚线路径。
  ///
  /// 从 `-offset` 起步让短划向前滚动；越过起点的那一段被裁掉，
  /// 于是每帧的段数恒定，不会出现「相位越走越多段」的抖动。
  Path _dashed(List<ui.PathMetric> metrics, double offset) {
    final result = Path();
    for (final metric in metrics) {
      var distance = -offset;
      while (distance < metric.length) {
        final start = distance < 0 ? 0.0 : distance;
        final end = (distance + _dash).clamp(0.0, metric.length);
        if (end > start) {
          result.addPath(metric.extractPath(start, end), Offset.zero);
        }
        distance += _period;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    _ensureBaked();
    final baked = _baked;
    if (baked == null || baked.isEmpty) {
      return const SizedBox.expand();
    }

    return IgnorePointer(
      child: CustomPaint(
        painter: _AntsPainter(
          pictures: baked,
          phase: _phase,
          translation: widget.translation,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _AntsPainter extends CustomPainter {
  const _AntsPainter({
    required this.pictures,
    required this.phase,
    required this.translation,
  });

  final List<ui.Picture> pictures;
  final int phase;
  final Offset translation;

  @override
  void paint(Canvas canvas, Size size) {
    if (pictures.isEmpty) return;
    final needsShift = translation != Offset.zero;
    if (needsShift) {
      canvas.save();
      canvas.translate(translation.dx, translation.dy);
    }
    canvas.drawPicture(pictures[phase % pictures.length]);
    if (needsShift) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AntsPainter oldDelegate) =>
      oldDelegate.pictures != pictures ||
      oldDelegate.phase != phase ||
      oldDelegate.translation != translation;
}
