import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// `RasterSurface` 是 P2 的像素地基，这里锁住四件事：
/// 惰性分配、写时复制（撤销快照的正确性）、有效瓦片判定、整层像素搬运。
void main() {
  /// 往指定像素写一个不透明色。
  void plot(RasterSurface surface, int x, int y, {int alpha = 255}) {
    final tx = x ~/ surface.tileSize;
    final ty = y ~/ surface.tileSize;
    final data = surface.writableTile(tx, ty);
    final lx = x % surface.tileSize;
    final ly = y % surface.tileSize;
    final index = (ly * surface.tileSize + lx) * RasterSurface.bytesPerPixel;
    data[index] = 255;
    data[index + 1] = 0;
    data[index + 2] = 0;
    data[index + 3] = alpha;
  }

  int alphaAt(RasterSurface surface, int x, int y) {
    final data = surface.tile(x ~/ surface.tileSize, y ~/ surface.tileSize);
    if (data == null) return 0;
    final lx = x % surface.tileSize;
    final ly = y % surface.tileSize;
    return data[(ly * surface.tileSize + lx) * RasterSurface.bytesPerPixel + 3];
  }

  group('惰性分配', () {
    test('新建时没有任何瓦片', () {
      final surface = RasterSurface(width: 1080, height: 1920);
      expect(surface.isEmpty, isTrue);
      expect(surface.tileCount, 0);
      expect(surface.columns, 5, reason: '1080 / 256 向上取整');
      expect(surface.rows, 8, reason: '1920 / 256 向上取整');
    });

    test('画一个点只分配一块瓦片', () {
      final surface = RasterSurface(width: 1080, height: 1920);
      plot(surface, 10, 10);
      expect(surface.tileCount, 1);
      expect(surface.allocatedByteSize, 256 * 256 * 4);
    });

    test('跨瓦片写两个点分配两块', () {
      final surface = RasterSurface(width: 1080, height: 1920);
      plot(surface, 10, 10);
      plot(surface, 300, 300);
      expect(surface.tileCount, 2);
    });

    test('越界坐标被断言拦住', () {
      final surface = RasterSurface(width: 300, height: 300);
      expect(surface.containsTile(1, 1), isTrue);
      expect(surface.containsTile(2, 0), isFalse, reason: '300/256 → 只有 2 列');
      expect(() => surface.writableTile(2, 0), throwsA(isA<AssertionError>()));
    });
  });

  group('写时复制', () {
    test('快照在源继续绘制后保持不变', () {
      final surface = RasterSurface(width: 512, height: 512);
      plot(surface, 10, 10);
      final snapshot = surface.fork();

      plot(surface, 20, 20); // 同一块瓦片内继续画

      expect(alphaAt(snapshot, 20, 20), 0, reason: '快照不应看到后续写入');
      expect(alphaAt(surface, 20, 20), 255);
      expect(alphaAt(snapshot, 10, 10), 255);
    });

    test('快照不继承脏标记', () {
      final surface = RasterSurface(width: 512, height: 512);
      plot(surface, 10, 10);
      final snapshot = surface.fork();
      expect(surface.dirtyTiles, isNotEmpty);
      expect(snapshot.dirtyTiles, isEmpty, reason: '快照本身不需要落盘');
    });

    test('分叉后新增的瓦片不会出现在快照里', () {
      final surface = RasterSurface(width: 512, height: 512);
      plot(surface, 10, 10);
      final snapshot = surface.fork();

      plot(surface, 300, 300); // 新瓦片

      expect(snapshot.tileCount, 1);
      expect(surface.tileCount, 2);
      expect(snapshot.tile(1, 1), isNull);
    });
  });

  group('有效瓦片', () {
    test('全透明瓦片不算有效内容', () {
      final surface = RasterSurface(width: 512, height: 512);
      plot(surface, 10, 10, alpha: 0);
      expect(surface.tileCount, 1, reason: '瓦片仍然分配着');
      expect(surface.liveTiles, isEmpty, reason: '但没有像素内容');
    });

    test('擦成透明后从有效集合消失', () {
      final surface = RasterSurface(width: 512, height: 512);
      plot(surface, 10, 10);
      expect(surface.liveTiles, contains((0, 0)));

      plot(surface, 10, 10, alpha: 0);
      expect(surface.liveTiles, isEmpty);
    });
  });

  group('整层像素搬运', () {
    test('toPixelBytes 把瓦片拼回行优先序列', () {
      final surface = RasterSurface(width: 300, height: 300);
      plot(surface, 0, 0);
      plot(surface, 299, 299);
      plot(surface, 260, 10); // 第二列瓦片

      final bytes = surface.toPixelBytes();
      expect(bytes.length, 300 * 300 * 4);

      int alphaAtByte(int x, int y) => bytes[(y * 300 + x) * 4 + 3];
      expect(alphaAtByte(0, 0), 255);
      expect(alphaAtByte(299, 299), 255);
      expect(alphaAtByte(260, 10), 255);
      expect(alphaAtByte(150, 150), 0);
    });

    test('fromPixels 丢弃全透明瓦片', () {
      final rgba = Uint8List(512 * 512 * 4);
      // 只在右下角（第二块瓦片）涂一个像素。
      final index = ((300 * 512) + 300) * 4;
      rgba[index] = 255;
      rgba[index + 3] = 255;

      final surface = RasterSurface.fromPixels(512, 512, rgba);
      expect(surface.tileCount, 1);
      expect(surface.allocatedTiles, contains((1, 1)));
      expect(alphaAt(surface, 300, 300), 255);
      expect(alphaAt(surface, 10, 10), 0);
    });

    test('toPixelBytes 与 fromPixels 往返一致', () {
      final surface = RasterSurface(width: 300, height: 300);
      plot(surface, 5, 5);
      plot(surface, 270, 270);

      final restored = RasterSurface.fromPixels(
        300,
        300,
        surface.toPixelBytes(),
      );
      expect(restored.toPixelBytes(), surface.toPixelBytes());
    });
  });

  group('尺寸兼容性', () {
    test('同尺寸同瓦片视为兼容，否则不兼容', () {
      final a = RasterSurface(width: 100, height: 100);
      expect(a.sameShapeAs(RasterSurface(width: 100, height: 100)), isTrue);
      expect(a.sameShapeAs(RasterSurface(width: 100, height: 100, tileSize: 128)),
          isFalse);
      expect(a.sameShapeAs(RasterSurface(width: 200, height: 100)), isFalse);
    });
  });
}
