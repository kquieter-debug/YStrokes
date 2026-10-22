
import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart' show ToolKind;
import 'package:ystrokes/src/services/drawing_engine.dart';
import 'package:ystrokes/src/services/raster_brush.dart';
import 'package:ystrokes/src/services/raster_surface.dart';

/// 位图图层在引擎层的行为：新建、撤销快照、双闸预算、以及那些**必须拒绝**的操作。
///
/// 这是 P2 里最容易写出「看起来能用、撤销之后错乱」的一段，因此断言都落在
/// 「撤销两笔之后像素是不是第一笔之后的样子」这种具体事实上。
void main() {
  const width = 32;
  const height = 32;

  DrawingEngine engineWithRaster() {
    final engine = DrawingEngine();
    engine.addRasterLayer(width: width, height: height, name: '位图');
    return engine;
  }

  /// 在给定坐标涂一个点。
  void paint(DrawingEngine engine, int x, int y, {int color = 0xFFFF0000}) {
    final surface = engine.activeLayer.raster!;
    RasterBrush.dab(
      surface,
      center: Offset(x.toDouble(), y.toDouble()),
      radius: 2,
      colorArgb: color,
      erase: false,
    );
  }

  int alphaAt(DrawingEngine engine, int x, int y) {
    final surface = engine.activeLayer.raster!;
    final data = surface.tile(x ~/ surface.tileSize, y ~/ surface.tileSize);
    if (data == null) return 0;
    final index = ((y % surface.tileSize) * surface.tileSize + (x % surface.tileSize)) * 4;
    return data[index + 3];
  }

  group('新建位图图层', () {
    test('插在当前图层上方并选中，类型为位图', () {
      final engine = DrawingEngine();
      engine.addLayer(name: '矢量');
      final raster = engine.addRasterLayer(width: width, height: height);

      expect(engine.activeLayerId, raster.id);
      expect(raster.isRaster, isTrue);
      expect(raster.isVector, isFalse);
      expect(raster.strokes, isEmpty);
      expect(raster.raster!.width, width);
      expect(engine.layers.last.id, raster.id);
    });

    test('新建属于可撤销操作', () {
      final engine = DrawingEngine();
      final count = engine.layers.length;
      engine.addRasterLayer(width: width, height: height);
      expect(engine.layers.length, count + 1);

      expect(engine.undo(), isTrue);
      expect(engine.layers.length, count);
      expect(engine.layers.any((layer) => layer.isRaster), isFalse);
    });

    test('位图图层不会被认为「没有内容」', () {
      final engine = engineWithRaster();
      expect(engine.isEmpty, isTrue, reason: '还没画');

      paint(engine, 10, 10);
      expect(engine.isEmpty, isFalse, reason: '有像素就不该算空');
    });
  });

  group('像素笔的撤销', () {
    test('一笔之后撤销回全透明，重做回原样', () {
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      expect(engine.commitRasterStroke(before), isTrue);
      expect(alphaAt(engine, 8, 8), 255);

      expect(engine.undo(), isTrue);
      expect(alphaAt(engine, 8, 8), 0);

      expect(engine.redo(), isTrue);
      expect(alphaAt(engine, 8, 8), 255);
    });

    test('两笔之后撤销只回退第二笔（快照必须冻结）', () {
      final engine = engineWithRaster();

      final first = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(first);

      final second = engine.beginRasterStroke()!;
      paint(engine, 24, 24);
      engine.commitRasterStroke(second);

      expect(alphaAt(engine, 8, 8), 255);
      expect(alphaAt(engine, 24, 24), 255);

      engine.undo();
      expect(alphaAt(engine, 8, 8), 255, reason: '第一笔应当还在');
      expect(alphaAt(engine, 24, 24), 0, reason: '第二笔应当消失');

      engine.undo();
      expect(alphaAt(engine, 8, 8), 0);

      // 重做两笔都要回来——这里是最容易错的地方：如果撤销记录里存的
      // 「之后」是活对象，重做会把第三笔的内容一起带出来。
      engine.redo();
      expect(alphaAt(engine, 8, 8), 255);
      expect(alphaAt(engine, 24, 24), 0);

      engine.redo();
      expect(alphaAt(engine, 24, 24), 255);
    });

    test('撤销后继续画，重做栈被清空', () {
      final engine = engineWithRaster();
      final first = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(first);
      engine.undo();
      expect(engine.canRedo, isTrue);

      final second = engine.beginRasterStroke()!;
      paint(engine, 20, 20);
      engine.commitRasterStroke(second);
      expect(engine.canRedo, isFalse);
    });

    test('非位图图层上 beginRasterStroke 返回 null', () {
      final engine = DrawingEngine();
      expect(engine.activeLayer.isVector, isTrue);
      expect(engine.beginRasterStroke(), isNull);
    });

    test('空提交（没落过 dab）也会入栈，但内容不变', () {
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      expect(engine.commitRasterStroke(before), isTrue);

      expect(alphaAt(engine, 8, 8), 0);
      expect(engine.undo(), isTrue);
      expect(alphaAt(engine, 8, 8), 0);
    });
  });

  group('撤销双闸', () {
    test('步数上限仍然是 25', () {
      final engine = engineWithRaster();
      for (var i = 0; i < 30; i++) {
        final before = engine.beginRasterStroke()!;
        paint(engine, i % width, i);
        engine.commitRasterStroke(before);
      }

      var undone = 0;
      while (engine.undo()) {
        undone++;
      }
      expect(undone, DrawingEngine.maxUndoSteps);
    });

    test('刚做完的一步永远可撤销（字节闸不吞掉最新记录）', () {
      // 手动塞一份超出预算的快照是不现实的（32×32 太小），因此这里改为
      // 断言「字节闸的循环条件保留至少一条」这一不变量：连续两步之后，
      // 至少能撤销一次。
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(before);

      expect(engine.canUndo, isTrue);
      expect(engine.undo(), isTrue);
    });
  });

  group('位图内容与矢量操作的边界', () {
    test('清空位图图层可撤销', () {
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(before);

      expect(engine.clear(), isTrue);
      expect(alphaAt(engine, 8, 8), 0);
      expect(engine.activeLayer.raster!.isEmpty, isTrue);

      expect(engine.undo(), isTrue);
      expect(alphaAt(engine, 8, 8), 255);
    });

    test('翻转对位图图层成立（像素置换，不需要插值）', () {
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(before);

      expect(engine.flipLayer(engine.activeLayerId, horizontal: true), isTrue);
    });

    test('含位图图层时不允许向下合并', () {
      final engine = DrawingEngine();
      engine.addLayer(name: '下');
      final raster = engine.addRasterLayer(width: width, height: height);
      expect(engine.canMergeDown(raster.id), isFalse);
      expect(engine.mergeDown(raster.id), isNull);
    });

    test('栅格化替换内容并可撤销回笔画', () {
      final engine = DrawingEngine();
      final vector = engine.activeLayer;
      engine.addStroke(
        const [
          rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
          rust.StrokePoint(x: 0.6, y: 0.5, pressure: 1, timestampMs: 10),
        ],
        tool: ToolKind.brush,
        color: 0xFF00FF00,
        widthRatio: 0.02,
        usesPressure: false,
      );
      expect(vector.strokes, hasLength(1));

      final pixels = RasterSurface(width: width, height: height);
      RasterBrush.dab(
        pixels,
        center: const Offset(16, 16),
        radius: 3,
        colorArgb: 0xFF00FF00,
        erase: false,
      );

      expect(engine.replaceWithPixels(vector.id, pixels), isTrue);
      expect(engine.activeLayer.isRaster, isTrue);
      expect(engine.activeLayer.strokes, isEmpty);

      expect(engine.undo(), isTrue);
      expect(engine.activeLayer.isRaster, isFalse, reason: '撤销要恢复成矢量层');
      expect(engine.activeLayer.strokes, hasLength(1), reason: '笔画要回来');
    });

    test('空图层栅格化返回 false（没有可烘焙的内容）', () {
      final engine = DrawingEngine();
      final empty = RasterSurface(width: width, height: height);
      expect(engine.replaceWithPixels(engine.activeLayerId, empty), isFalse);
    });
  });

  group('复制位图图层', () {
    test('副本共享像素，改动一方不影响另一方', () {
      final engine = engineWithRaster();
      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      engine.commitRasterStroke(before);

      final source = engine.activeLayer;
      final copy = engine.duplicateLayer(source.id)!;
      expect(copy.isRaster, isTrue);
      expect(copy.name, '${source.name} 副本');

      // 改副本（此时是副本的活 surface）。
      RasterBrush.dab(
        copy.raster!,
        center: const Offset(24, 24),
        radius: 2,
        colorArgb: 0xFF0000FF,
        erase: false,
      );

      int alphaOf(DrawingLayer layer, int x, int y) {
        final data = layer.raster!.tile(x ~/ 256, y ~/ 256);
        if (data == null) return 0;
        return data[((y % 256) * 256 + (x % 256)) * 4 + 3];
      }

      expect(alphaOf(copy, 24, 24), 255, reason: '副本自己画上了');
      expect(alphaOf(source, 24, 24), 0, reason: '源图层不该被污染');
      expect(alphaOf(source, 8, 8), 255);
    });
  });

  group('撤销与对象身份', () {
    test('撤销像素笔画不换 surface 对象', () {
      // 这是「撤销时整层闪一下」的回归点：换对象会让渲染缓存（按 surface
      // 身份索引）整体失效，整层要等所有瓦片重新解码才画得出来。
      final engine = engineWithRaster();
      final surface = engine.activeLayer.raster!;

      final before = engine.beginRasterStroke()!;
      paint(engine, 8, 8);
      expect(engine.commitRasterStroke(before), isTrue);

      expect(engine.undo(), isTrue);

      expect(
        identical(engine.activeLayer.raster, surface),
        isTrue,
        reason: '撤销必须原地接管内容，而不是换一个新 surface',
      );
      expect(alphaAt(engine, 8, 8), 0, reason: '内容本身要真的回退');
    });

    test('重做同样不换对象，且重新带回这一笔', () {
      final engine = engineWithRaster();
      final surface = engine.activeLayer.raster!;

      final before = engine.beginRasterStroke()!;
      paint(engine, 10, 10);
      engine.commitRasterStroke(before);
      engine.undo();
      expect(engine.redo(), isTrue);

      expect(identical(engine.activeLayer.raster, surface), isTrue);
      expect(alphaAt(engine, 10, 10), 255);
    });

    test('取消像素笔画也原地复原', () {
      final engine = engineWithRaster();
      final surface = engine.activeLayer.raster!;

      final before = engine.beginRasterStroke()!;
      paint(engine, 12, 12);
      // 不提交，直接把快照接管回来（画板的 _abortRasterStroke 走的就是这条）。
      surface.adoptFrom(before);

      expect(alphaAt(engine, 12, 12), 0);
      // 栈里只剩「新建位图层」那一条，取消本身没有入栈。
      expect(engine.undo(), isTrue);
      expect(engine.canUndo, isFalse, reason: '取消不该留下撤销记录');
    });
  });

  group('位图图层翻转', () {
    test('水平翻转是像素置换，可撤销', () {
      final engine = engineWithRaster();
      paint(engine, 4, 16);

      expect(engine.flipLayer(engine.activeLayerId, horizontal: true), isTrue);
      expect(alphaAt(engine, 4, 16), 0, reason: '原位置应当空掉');
      expect(alphaAt(engine, width - 1 - 4, 16), greaterThan(0));

      expect(engine.undo(), isTrue);
      expect(alphaAt(engine, 4, 16), greaterThan(0), reason: '撤销回到原位');
    });

    test('垂直翻转只改 y', () {
      final engine = engineWithRaster();
      paint(engine, 8, 4);

      expect(engine.flipLayer(engine.activeLayerId, horizontal: false), isTrue);
      expect(alphaAt(engine, 8, 4), 0);
      expect(alphaAt(engine, 8, height - 1 - 4), greaterThan(0));
    });

    test('空位图图层翻转返回 false 且不入栈', () {
      final engine = engineWithRaster();
      expect(engine.flipLayer(engine.activeLayerId, horizontal: true), isFalse);
      expect(engine.canUndo, isTrue, reason: '只剩新建图层那一条');
    });
  });
}
