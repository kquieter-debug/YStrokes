
import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/raster_brush.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// 像素笔：覆盖、抗锯齿边缘、擦除、以及「改了哪几块瓦片」。
///
/// 最后一件事看着像实现细节，其实是渲染层唯一可靠的重传依据——
/// 从 `dirtyTiles` 推断会与落盘脏标记共用状态，保存后被清空就漏画。
void main() {
  const tileSize = 16;

  RasterSurface surface() =>
      RasterSurface(width: 64, height: 64, tileSize: tileSize);

  int alphaAt(RasterSurface s, int x, int y) {
    final data = s.tile(x ~/ tileSize, y ~/ tileSize);
    if (data == null) return 0;
    return data[((y % tileSize) * tileSize + (x % tileSize)) * 4 + 3];
  }

  List<int> rgbaAt(RasterSurface s, int x, int y) {
    final data = s.tile(x ~/ tileSize, y ~/ tileSize);
    if (data == null) return const [0, 0, 0, 0];
    final i = ((y % tileSize) * tileSize + (x % tileSize)) * 4;
    return [data[i], data[i + 1], data[i + 2], data[i + 3]];
  }

  group('单个 dab', () {
    test('圆心不透明、圆外全透明', () {
      final s = surface();
      RasterBrush.dab(
        s,
        center: const Offset(8, 8),
        radius: 3,
        colorArgb: 0xFFFF0000,
        erase: false,
      );

      expect(alphaAt(s, 8, 8), 255);
      expect(alphaAt(s, 8, 0), 0);
      expect(alphaAt(s, 0, 8), 0);
      expect(rgbaAt(s, 8, 8), [255, 0, 0, 255]);
    });

    test('边缘一个像素内有渐变（抗锯齿）', () {
      final s = surface();
      RasterBrush.dab(
        s,
        center: const Offset(8, 8),
        radius: 4,
        colorArgb: 0xFF000000,
        erase: false,
      );

      // 圆心实心区。
      expect(alphaAt(s, 8, 8), 255);

      // 沿 +y 方向扫一圈：必须存在「既不是 0 也不是 255」的过渡像素，
      // 否则边缘就是硬切（锯齿）。
      final column = [
        for (var y = 8; y < 16; y++) alphaAt(s, 8, y),
      ];
      expect(column.first, 255);
      expect(column.last, 0, reason: '半径外必须全透明');
      expect(
        column.any((a) => a > 0 && a < 255),
        isTrue,
        reason: '缺少半透明过渡说明没有抗锯齿：$column',
      );
    });

    test('dab 只分配覆盖到的瓦片', () {
      final s = surface();
      expect(s.tileCount, 0);
      RasterBrush.dab(
        s,
        center: const Offset(8, 8),
        radius: 2,
        colorArgb: 0xFF000000,
        erase: false,
      );
      expect(s.tileCount, 1);
    });

    test('跨瓦片边界的 dab 会同时改两块', () {
      final s = surface();
      // 圆心压在 (16,16) 这个瓦片角上。
      final touched = RasterBrush.dab(
        s,
        center: const Offset(16, 16),
        radius: 3,
        colorArgb: 0xFF000000,
        erase: false,
      );
      expect(touched, containsAll(<TileKey>[(0, 0), (1, 0), (0, 1), (1, 1)]));
      expect(s.tileCount, 4);
    });
  });

  group('线段', () {
    test('沿线均匀落 dab，两端都覆盖', () {
      final s = surface();
      RasterBrush.strokeSegment(
        s,
        from: const Offset(8, 8),
        to: const Offset(48, 8),
        radius: 2,
        colorArgb: 0xFF00FF00,
        erase: false,
      );

      expect(alphaAt(s, 8, 8), 255);
      expect(alphaAt(s, 24, 8), 255);
      expect(alphaAt(s, 48, 8), 255);
      // 线上方 5 像素处不该被涂到（半径 2）。
      expect(alphaAt(s, 24, 2), 0);
    });

    test('起终点相同也要落一个 dab（点一下要留下圆点）', () {
      final s = surface();
      RasterBrush.strokeSegment(
        s,
        from: const Offset(10, 10),
        to: const Offset(10, 10),
        radius: 2,
        colorArgb: 0xFF000000,
        erase: false,
      );
      expect(alphaAt(s, 10, 10), 255);
    });

    test('返回被改动的瓦片集合', () {
      final s = surface();
      final touched = RasterBrush.strokeSegment(
        s,
        from: const Offset(4, 4),
        to: const Offset(60, 60),
        radius: 2,
        colorArgb: 0xFF000000,
        erase: false,
      );
      expect(touched.length, greaterThan(1));
      for (final (x, y) in touched) {
        expect(s.tile(x, y), isNotNull, reason: '报告过的瓦片必须真的被分配');
      }
    });
  });

  group('合成与擦除', () {
    test('同一位置重复落 dab 单调逼近全不透明，不会溢出', () {
      final s = surface();
      for (var i = 0; i < 5; i++) {
        RasterBrush.dab(
          s,
          center: const Offset(8, 8),
          radius: 3,
          colorArgb: 0x80FF0000,
          erase: false,
        );
      }
      // 每次 50% 覆盖，5 次后 1-0.5^5 ≈ 97%。
      expect(alphaAt(s, 8, 8), greaterThan(240));
      expect(alphaAt(s, 8, 8), lessThanOrEqualTo(255));
      // 直通 alpha 合成：叠加同色不会让通道溢出。
      expect(rgbaAt(s, 8, 8).first, 255);
    });

    test('擦除把 alpha 削到 0，颜色一并清零', () {
      final s = surface();
      RasterBrush.dab(s, center: const Offset(8, 8), radius: 3, colorArgb: 0xFFFF0000, erase: false);
      expect(alphaAt(s, 8, 8), 255);

      RasterBrush.dab(s, center: const Offset(8, 8), radius: 4, colorArgb: 0xFF000000, erase: true);
      expect(alphaAt(s, 8, 8), 0);
      expect(rgbaAt(s, 8, 8), [0, 0, 0, 0]);
    });

    test('擦除空白区域不分配瓦片', () {
      final s = surface();
      final touched = RasterBrush.dab(
        s,
        center: const Offset(8, 8),
        radius: 3,
        colorArgb: 0xFF000000,
        erase: true,
      );
      expect(touched, isEmpty);
      expect(s.tileCount, 0);
    });

    test('部分覆盖的擦除留下半透明（这就是羽化的基础）', () {
      final s = surface();
      RasterBrush.dab(s, center: const Offset(8, 8), radius: 6, colorArgb: 0xFF000000, erase: false);
      final before = alphaAt(s, 8, 13);
      expect(before, greaterThan(0));

      RasterBrush.dab(s, center: const Offset(8, 8), radius: 8, colorArgb: 0xFF000000, erase: true);
      final after = alphaAt(s, 8, 13);
      expect(after, lessThan(before));
      expect(after, 0, reason: '半径更大的擦除应把这一圈完全擦掉');
    });
  });

  group('边界', () {
    test('画到画布外不崩溃，也不越界写', () {
      final s = surface();
      // 圆心在画布外，但圆仍压到左上角。
      RasterBrush.dab(s, center: const Offset(-2, -2), radius: 6, colorArgb: 0xFF000000, erase: false);
      expect(alphaAt(s, 0, 0), greaterThan(0));

      // 圆压到右下角。
      RasterBrush.dab(s, center: const Offset(60, 60), radius: 6, colorArgb: 0xFF000000, erase: false);
      expect(alphaAt(s, 63, 63), greaterThan(0));
      expect(s.containsTile(3, 3), isTrue, reason: '右下角属于第 4 列第 4 行');
    });

    test('整颗 dab 都在画布外时什么都不做', () {
      final s = surface();
      final touched = RasterBrush.dab(
        s,
        center: const Offset(200, 200),
        radius: 4,
        colorArgb: 0xFF000000,
        erase: false,
      );
      expect(touched, isEmpty);
      expect(s.tileCount, 0);
    });

    test('半径为 0 是空操作', () {
      final s = surface();
      expect(
        RasterBrush.dab(s, center: const Offset(8, 8), radius: 0, colorArgb: 0xFF000000, erase: false),
        isEmpty,
      );
      expect(s.tileCount, 0);
    });
  });
}
