import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/rust/api.dart';
import 'package:ystrokes/src/services/stroke_smoother.dart';

StrokePoint pt(double x, double y, {double pressure = 1.0, int t = 0}) =>
    StrokePoint(x: x, y: y, pressure: pressure, timestampMs: t);

void main() {
  group('中心移动平均（与 Rust smooth_stroke 语义一致）', () {
    test('五点输入的平滑取值符合手算结果', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0);
      for (final point in <StrokePoint>[
        pt(0, 0),
        pt(1, 0),
        pt(2, 2),
        pt(3, 0),
        pt(4, 0),
      ]) {
        smoother.add(point);
      }

      final out = smoother.finish();
      expect(out, hasLength(5));

      // i=0: 窗口 [0,2] → x=(0+1+2)/3, y=(0+0+2)/3
      expect(out[0].x, closeTo(1.0, 1e-12));
      expect(out[0].y, closeTo(2 / 3, 1e-12));
      // i=1: 窗口 [0,3] → x=(0+1+2+3)/4, y=(0+0+2+0)/4
      expect(out[1].x, closeTo(1.5, 1e-12));
      expect(out[1].y, closeTo(0.5, 1e-12));
      // i=2: 窗口 [0,4] → x=2, y=(0+0+2+0+0)/5
      expect(out[2].x, closeTo(2.0, 1e-12));
      expect(out[2].y, closeTo(0.4, 1e-12));
      // i=3: 窗口 [1,4] → x=(1+2+3+4)/4, y=(0+2+0+0)/4
      expect(out[3].x, closeTo(2.5, 1e-12));
      expect(out[3].y, closeTo(0.5, 1e-12));
      // i=4: 窗口 [2,4] → x=(2+3+4)/3, y=(2+0+0)/3
      expect(out[4].x, closeTo(3.0, 1e-12));
      expect(out[4].y, closeTo(2 / 3, 1e-12));
    });

    test('压力与坐标使用同一窗口', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0)
        ..add(pt(0, 0, pressure: 1))
        ..add(pt(1, 0, pressure: 0))
        ..add(pt(2, 0, pressure: 0));

      final out = smoother.finish();
      expect(out[0].pressure, closeTo(1 / 3, 1e-12));
    });

    test('时间戳保持原始值', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0)
        ..add(pt(0, 0, t: 0))
        ..add(pt(1, 0, t: 16))
        ..add(pt(2, 0, t: 32));

      final out = smoother.finish();
      expect(out.map((p) => p.timestampMs).toList(), <int>[0, 16, 32]);
    });
  });

  group('增量的稳定性', () {
    test('已定稿的点不会被后续采样改写', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0);
      for (var i = 0; i < 5; i++) {
        smoother.add(pt(i.toDouble(), i.isEven ? 0 : 2));
      }
      final before = smoother.finish();
      // n=5 时下标 0..2 已定稿（窗口右端 2 已存在）。
      expect(before, hasLength(5));

      smoother.add(pt(5, 0));
      final after = smoother.finish();

      for (var i = 0; i < 3; i++) {
        expect(after[i].x, before[i].x, reason: '点 $i 的 x 不应变化');
        expect(after[i].y, before[i].y, reason: '点 $i 的 y 不应变化');
      }
    });

    test('流式输入与逐点提交的最终结果一致（幂等）', () {
      final smoother = StrokeSmoother(shortestSide: 800, minDistancePx: 0.5);
      for (var i = 0; i < 40; i++) {
        smoother.add(pt(
          i / 40,
          0.5 + 0.1 * (i % 3),
          pressure: i.isEven ? 1.0 : 0.4,
          t: i * 8,
        ));
      }

      final first = smoother.finish();
      final second = smoother.finish();
      expect(second, first, reason: 'finish 应幂等，不得再改变几何');
    });
    test('绘制过程中未被定稿的尾部会随新点更新，但总点数保持稳定', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0);
      for (var i = 0; i < 10; i++) {
        smoother.add(pt(i.toDouble(), 0));
      }
      expect(smoother.points, hasLength(10));
      expect(smoother.rawPointCount, 10);
    });
  });

  group('边界情况', () {
    test('不足三点时原样透传，避免两点笔画被均值压成一个点', () {
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 0)
        ..add(pt(0, 0))
        ..add(pt(0.5, 0.5));

      final out = smoother.finish();
      expect(out, hasLength(2));
      expect(out[0].x, 0);
      expect(out[1].x, 0.5);
      expect(out[1].y, 0.5);
    });

    test('单点笔画保留', () {
      final smoother = StrokeSmoother(shortestSide: 1000)
        ..add(pt(0.3, 0.4));
      final out = smoother.finish();
      expect(out, hasLength(1));
      expect(out.single.x, 0.3);
    });

    test('抽稀不会吞掉收笔位置', () {
      // 阈值 5px、画布短边 1000 → 归一化阈值 0.005，三个点几乎重合。
      final smoother = StrokeSmoother(shortestSide: 1000, minDistancePx: 5)
        ..add(pt(0.1000, 0.5))
        ..add(pt(0.1001, 0.5))
        ..add(pt(0.1002, 0.5));

      final out = smoother.finish();
      expect(out.length, lessThan(3), reason: '过近的点应被抽掉');
      expect(
        out.last.x,
        closeTo((0.1000 + 0.1001 + 0.1002) / 3, 1e-12),
        reason: '最后一个点必须保留，且保持平滑后的取值',
      );
    });

    test('抽稀按屏幕像素而非归一化距离判断', () {
      // 同一组归一化数据，短边越大，屏幕距离越大，保留点越多。
      List<StrokePoint> run(double shortestSide) {
        final smoother =
            StrokeSmoother(shortestSide: shortestSide, minDistancePx: 1);
        for (var i = 0; i < 6; i++) {
          smoother.add(pt(0.5 + i * 0.001, 0.5));
        }
        return smoother.finish();
      }

      expect(run(2000).length, greaterThan(run(100).length));
    });
  });
}
