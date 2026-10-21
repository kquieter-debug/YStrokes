import 'dart:math' as math;
import 'dart:ui';

import '../rust/api/stroke.dart' as rust;

/// 压感映射：把 0~1 的压力换算成「相对基准笔宽的系数」。
///
/// 形状为 `factor = min + (1 - min) · pressure^gamma`，三个常量都在此显式声明，
/// 调参只改这里。选择这条曲线的理由：
///
/// 1. **`factor(1) == 1` 精确成立**。手指与不支持压感的电容笔上报的
///    `pressure` 恒为 1.0，必须让它们得到与「关闭压感」完全相同的线宽，
///    否则同一支笔在有无压感开关时会画出两种粗细。
/// 2. `gamma < 1` 时中段偏细，笔尖起落更明显；`gamma = 1` 即线性。
/// 3. 上界 [kPressureMaxFactor] 在当前输入范围（压力 ≤ 1）内不可达，保留它是为了
///    夹住异常输入（个别设备驱动会上报 > 1 的压力），同时给未来的「压力放大」留口。
const double kPressureMinFactor = 0.25;
const double kPressureMaxFactor = 1.5;
const double kPressureGamma = 1.2;

/// 圆头帽的折线段数：半圆近似为 [_capSegments] 段，单段圆心角 18°。
///
/// 取 10 是因为在 1~200px 的笔宽范围内，弦高误差始终小于 0.02px，肉眼不可辨；
/// 再高只会增加路径点，不会改善观感。
const int _capSegments = 10;

/// 压力 → 笔宽系数（乘在基准笔宽上）。
///
/// 非有限值按 1.0（无压感）处理，避免 NaN 污染整条路径。
double pressureWidthFactor(double pressure) {
  final p = pressure.isFinite ? pressure.clamp(0.0, 1.0) : 1.0;
  final shaped = math.pow(p, kPressureGamma).toDouble();
  final factor = kPressureMinFactor + (1.0 - kPressureMinFactor) * shaped;
  return factor.clamp(kPressureMinFactor, kPressureMaxFactor);
}

/// 生成一条笔画的**填充轮廓**多边形（屏幕坐标系下的闭合折线）。
///
/// 为什么是轮廓而不是「分段变宽的描边」：后者要求每两点一次 `drawLine`，
/// 一笔 100 个点就是 100 次 draw call。已完成笔画在每次新增笔画时都会整体重烘焙，
/// 1000 笔的文档会因此从 1000 次调用涨到十万级，直接掉帧。轮廓填充保持
/// 「一笔一次填充」，成本只体现在路径构建上。
///
/// 关键约束：**[spaceWidth] / [spaceHeight] 必须是保持文档宽高比的空间**。
/// 轮廓在这里按 `x · spaceWidth`、`y · spaceHeight` 展开，宽度按 `baseWidth`
/// 展开；只有空间等比时，半圆帽才仍然是圆，笔宽才不会随文档长宽比漂移。
/// 因此画布传屏幕上的文档矩形，SVG 传文档像素尺寸——两处得到的是同一个形状
/// 的等比缩放，这正是「所见即所得」可证明的原因。
///
/// 返回空列表表示无法生成（点数不足两点、空间或笔宽非法）。单点笔画不走这里，
/// 由调用方画圆点。
List<Offset> buildStrokeOutline({
  required List<rust.StrokePoint> points,
  required double spaceWidth,
  required double spaceHeight,
  required double baseWidth,
  bool pressure = false,
}) {
  if (points.length < 2) return const <Offset>[];
  if (!spaceWidth.isFinite || !spaceHeight.isFinite) return const <Offset>[];
  if (spaceWidth <= 0 || spaceHeight <= 0) return const <Offset>[];
  if (!baseWidth.isFinite || baseWidth <= 0) return const <Offset>[];

  final count = points.length;
  final centers = List<Offset>.generate(
    count,
    (i) => Offset(points[i].x * spaceWidth, points[i].y * spaceHeight),
    growable: false,
  );
  final halfWidths = List<double>.generate(
    count,
    (i) => baseWidth *
        (pressure ? pressureWidthFactor(points[i].pressure) : 1.0) /
        2,
    growable: false,
  );

  final left = List<Offset>.filled(count, Offset.zero);
  final right = List<Offset>.filled(count, Offset.zero);

  // 方向取「前后点连线」而非「当前段」：这样每个采样点的法向是切线的法向，
  // 偏移点列的走向不会在采样点处拐折。首末点退化为单侧差分。
  var unit = const Offset(1, 0);
  for (var i = 0; i < count; i++) {
    final Offset delta;
    if (i == 0) {
      delta = centers[1] - centers[0];
    } else if (i == count - 1) {
      delta = centers[count - 1] - centers[count - 2];
    } else {
      delta = centers[i + 1] - centers[i - 1];
    }
    final length = delta.distance;
    // 重复点或极短段：沿用上一段的方向，避免除零并保持轮廓连续。
    if (length > 1e-9) unit = delta / length;

    final normal = Offset(-unit.dy, unit.dx);
    left[i] = centers[i] + normal * halfWidths[i];
    right[i] = centers[i] - normal * halfWidths[i];
  }

  final outline = <Offset>[...left];

  // 尾端半圆：从左侧绕行到右侧，扫过 -π（屏幕坐标 y 轴向下，负角即沿前进方向鼓出）。
  final endCenter = centers[count - 1];
  _appendArc(
    outline,
    endCenter,
    halfWidths[count - 1],
    _angleOf(left[count - 1] - endCenter),
    -math.pi,
    includeEnd: true,
  );

  for (var i = count - 2; i >= 0; i--) {
    outline.add(right[i]);
  }

  // 首端半圆：从右侧绕回左侧，同样扫过 -π（此时鼓出方向为来的反方向）。
  final startCenter = centers[0];
  _appendArc(
    outline,
    startCenter,
    halfWidths[0],
    _angleOf(right[0] - startCenter),
    -math.pi,
    includeEnd: false,
  );

  return outline;
}

/// 把轮廓折线转成可填充的 [Path]；[translate] 用于把局部空间平移到文档矩形。
Path outlineToPath(List<Offset> outline, {Offset translate = Offset.zero}) {
  final path = Path();
  if (outline.isEmpty) return path;
  final first = outline.first + translate;
  path.moveTo(first.dx, first.dy);
  for (var i = 1; i < outline.length; i++) {
    final p = outline[i] + translate;
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  return path;
}

/// 追加一段圆弧上的采样点（不含起点，[includeEnd] 控制是否含终点）。
///
/// 半径为零时整段是同一个点，直接跳过——此时多边形退化为「去程与回程重合」，
/// 用 nonzero 填充规则仍能得到正确（零面积）结果，不会画出异常图形。
void _appendArc(
  List<Offset> out,
  Offset center,
  double radius,
  double startAngle,
  double sweep, {
  required bool includeEnd,
}) {
  if (radius <= 0) return;
  final steps = includeEnd ? _capSegments : _capSegments - 1;
  for (var k = 1; k <= steps; k++) {
    final angle = startAngle + sweep * (k / _capSegments);
    out.add(
      Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      ),
    );
  }
}

double _angleOf(Offset v) => math.atan2(v.dy, v.dx);
