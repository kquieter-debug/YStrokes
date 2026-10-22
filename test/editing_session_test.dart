import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/layer.dart';
import 'package:ystrokes/src/models/stroke.dart';
import 'package:ystrokes/src/rust/api/stroke.dart' as rust;
import 'package:ystrokes/src/rust/api/tools.dart';
import 'package:ystrokes/src/services/drawing_engine.dart';
import 'package:ystrokes/src/services/edit_journal.dart';

/// 编辑能力：撤销上限、复制图层、整段替换、日志回放。
void main() {
  Stroke strokeOf(int id, {double x = 0.2}) => Stroke(
        id: id,
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        points: <rust.StrokePoint>[
          rust.StrokePoint(x: x, y: x, pressure: 1, timestampMs: 0),
        ],
        usesPressure: false,
      );

  group('撤销上限', () {
    test('超过 25 步后丢弃最旧的一条', () {
      final engine = DrawingEngine();

      for (var i = 0; i < DrawingEngine.maxUndoSteps + 5; i++) {
        engine.addStroke(
          <rust.StrokePoint>[
            rust.StrokePoint(x: 0.1, y: 0.1, pressure: 1, timestampMs: 0),
          ],
          tool: ToolKind.brush,
          color: 0xFF000000,
          widthRatio: 0.01,
          usesPressure: false,
        );
      }
      expect(engine.strokeCount, DrawingEngine.maxUndoSteps + 5);

      var undone = 0;
      while (engine.undo()) {
        undone++;
      }
      expect(undone, DrawingEngine.maxUndoSteps);

      // 最早的 5 笔已经无法撤销，它们必须仍在文档里。
      expect(engine.strokeCount, 5);
    });

    test('上限只在入栈时裁剪，重做不会凭空多出历史', () {
      final engine = DrawingEngine()
        ..addStroke(
          <rust.StrokePoint>[
            rust.StrokePoint(x: 0.1, y: 0.1, pressure: 1, timestampMs: 0),
          ],
          tool: ToolKind.brush,
          color: 0xFF000000,
          widthRatio: 0.01,
          usesPressure: false,
        );

      expect(engine.undo(), isTrue);
      expect(engine.redo(), isTrue);
      expect(engine.canUndo, isTrue);
      expect(engine.canRedo, isFalse);
    });
  });

  group('复制图层', () {
    test('副本插在上方、选中副本、笔画按新 id 复制', () {
      final engine = DrawingEngine();
      engine.addLayer(name: '线稿');
      final source = engine.activeLayer
        ..strokes.addAll(<Stroke>[
          strokeOf(1),
          strokeOf(2, x: 0.4),
        ]);

      final copy = engine.duplicateLayer(source.id);

      expect(copy, isNotNull);
      expect(copy!.name, '线稿 副本');
      expect(engine.activeLayerId, copy.id);
      expect(engine.layers.indexOf(copy), engine.layers.indexOf(source) + 1);
      expect(copy.strokes, hasLength(2));
      expect(
        copy.strokes.map((stroke) => stroke.id).toSet(),
        isNot(<int>{1, 2}),
        reason: '两层共用 id 会让按 id 定位的撤销误伤另一层',
      );
    });

    test('复制可撤销', () {
      final engine = DrawingEngine();
      engine.addLayer(name: '层');
      final countBefore = engine.layers.length;
      engine.duplicateLayer(engine.activeLayerId);

      expect(engine.layers, hasLength(countBefore + 1));
      expect(engine.undo(), isTrue);
      expect(engine.layers, hasLength(countBefore));
    });
  });

  group('笔画整段替换', () {
    test('预览不入栈，提交只留一条记录', () {
      final engine = DrawingEngine();
      engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
        ],
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        usesPressure: false,
      );
      final layerId = engine.activeLayerId;
      final before = engine.snapshotStrokes(layerId);

      for (var i = 1; i <= 5; i++) {
        engine.setStrokes(layerId, <Stroke>[strokeOf(100, x: i / 10)]);
      }
      expect(engine.layers.single.strokes.single.id, 100);

      engine.commitStrokes(layerId, before);
      expect(engine.undo(), isTrue);
      expect(engine.layers.single.strokes.single.id, before.single.id);
      // 再撤一次应当把「最初那一笔」也撤掉，证明中间 5 次预览没有各占一步。
      expect(engine.undo(), isTrue);
      expect(engine.layers.single.strokes, isEmpty);
    });

    test('删除指定笔画可撤销', () {
      final engine = DrawingEngine();
      engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.2, y: 0.2, pressure: 1, timestampMs: 0),
        ],
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        usesPressure: false,
      );
      final id = engine.layers.single.strokes.single.id;

      expect(engine.removeStrokes(engine.activeLayerId, <int>{id}), 1);
      expect(engine.layers.single.strokes, isEmpty);
      expect(engine.undo(), isTrue);
      expect(engine.layers.single.strokes, hasLength(1));
    });
  });

  group('崩溃日志', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('ystrokes_journal_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('追加后可读回，清空后为空', () async {
      final journal = EditJournal(rootDirectory: temp);
      await journal.appendStroke(
        projectId: 'p1',
        layerIndex: 0,
        stroke: strokeOf(5),
      );
      await journal.appendStroke(
        projectId: 'p2',
        layerIndex: 1,
        stroke: strokeOf(6, x: 0.7),
      );

      final first = await journal.read('p1');
      expect(first, hasLength(1));
      expect(first.single.stroke.id, 5);
      expect(first.single.stroke.points.single.x, closeTo(0.2, 1e-6));

      final second = await journal.read('p2');
      expect(second.single.layerIndex, 1);

      await journal.clear('p1');
      expect(await journal.read('p1'), isEmpty);
      expect(await journal.read('p2'), hasLength(1), reason: '按工程隔离');
    });

    test('尾部被截断时只丢最后一帧', () async {
      final journal = EditJournal(rootDirectory: temp);
      await journal.appendStroke(
        projectId: 'p1',
        layerIndex: 0,
        stroke: strokeOf(1),
      );
      await journal.appendStroke(
        projectId: 'p1',
        layerIndex: 0,
        stroke: strokeOf(2),
      );

      // 模拟进程在写第二帧的中途被杀：截掉若干字节。
      final file = File('${temp.path}/projects/p1/edits.journal');
      final bytes = await file.readAsBytes();
      await file.writeAsBytes(bytes.sublist(0, bytes.length - 7));

      final entries = await journal.read('p1');
      expect(entries, hasLength(1));
      expect(entries.single.stroke.id, 1);
    });

    test('回放按 id 去重并按图层下标落位', () {
      final engine = DrawingEngine();
      engine.addLayer(name: '第二层');
      final targetLayer = engine.activeLayer;

      final added = engine.restoreStrokes(<int, List<Stroke>>{
        0: <Stroke>[strokeOf(11)],
        1: <Stroke>[strokeOf(12), strokeOf(12)],
      });

      expect(added, 2, reason: '同一 id 的第二条应被忽略');
      expect(engine.layers[0].strokes.single.id, 11);
      expect(targetLayer.strokes.single.id, 12);
    });

    test('回放遇到越界图层下标时跳过而不是抛错', () {
      final engine = DrawingEngine();
      expect(
        engine.restoreStrokes(<int, List<Stroke>>{
          9: <Stroke>[strokeOf(1)],
        }),
        0,
      );
    });

    test('回放后新笔画 id 不会与恢复的撞车', () {
      final engine = DrawingEngine();
      engine.restoreStrokes(<int, List<Stroke>>{
        0: <Stroke>[strokeOf(42)],
      });

      final added = engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.1, y: 0.1, pressure: 1, timestampMs: 0),
        ],
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        usesPressure: false,
      );
      expect(added.id, greaterThan(42));
    });
  });

  test('新建工程至少有一个图层（复制/变换都依赖它）', () {
    final engine = DrawingEngine();
    expect(engine.layers, hasLength(1));
    expect(engine.layers.single, isA<DrawingLayer>());
  });

  group('翻转图层', () {
    test('水平翻转把坐标镜像到对侧，可撤销', () {
      final engine = DrawingEngine();
      engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.2, y: 0.3, pressure: 1, timestampMs: 0),
        ],
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        usesPressure: false,
      );

      expect(engine.flipLayer(engine.activeLayerId, horizontal: true), isTrue);
      final flipped = engine.layers.single.strokes.single.points.single;
      expect(flipped.x, closeTo(0.8, 1e-6));
      expect(flipped.y, closeTo(0.3, 1e-6));

      expect(engine.undo(), isTrue);
      expect(
        engine.layers.single.strokes.single.points.single.x,
        closeTo(0.2, 1e-6),
      );
    });

    test('空图层翻转返回 false，不产生撤销记录', () {
      final engine = DrawingEngine();
      expect(engine.flipLayer(engine.activeLayerId, horizontal: true), isFalse);
      expect(engine.canUndo, isFalse);
    });
  });

  group('切分笔画', () {
    test('跨边界的笔画被替换成多段，且各自有新 id', () {
      final engine = DrawingEngine();
      engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.1, y: 0.5, pressure: 1, timestampMs: 0),
          rust.StrokePoint(x: 0.9, y: 0.5, pressure: 1, timestampMs: 10),
        ],
        tool: ToolKind.brush,
        color: 0xFF00FF00,
        widthRatio: 0.01,
        usesPressure: false,
      );
      final originalId = engine.layers.single.strokes.single.id;

      final square = <Offset>[
        const Offset(0.3, 0.3),
        const Offset(0.7, 0.3),
        const Offset(0.7, 0.7),
        const Offset(0.3, 0.7),
      ];
      final created = engine.splitStrokes(
        engine.activeLayerId,
        <int>{originalId},
        square,
      );

      expect(created, greaterThanOrEqualTo(1));
      expect(engine.layers.single.strokes, hasLength(1), reason: '切一次仍是一段');
      final cut = engine.layers.single.strokes.single;
      expect(cut.id, isNot(originalId), reason: '碎片是独立对象');
      expect(cut.color, 0xFF00FF00, reason: '样式沿用原笔画');
      expect(cut.points.first.x, closeTo(0.3, 1e-6));

      expect(engine.undo(), isTrue);
      expect(engine.layers.single.strokes.single.id, originalId);
    });

    test('整条在区域内时不切分，返回 0', () {
      final engine = DrawingEngine();
      engine.addStroke(
        <rust.StrokePoint>[
          rust.StrokePoint(x: 0.4, y: 0.4, pressure: 1, timestampMs: 0),
          rust.StrokePoint(x: 0.6, y: 0.6, pressure: 1, timestampMs: 10),
        ],
        tool: ToolKind.brush,
        color: 0xFF000000,
        widthRatio: 0.01,
        usesPressure: false,
      );
      final id = engine.layers.single.strokes.single.id;

      final created = engine.splitStrokes(
        engine.activeLayerId,
        <int>{id},
        <Offset>[
          const Offset(0.3, 0.3),
          const Offset(0.7, 0.3),
          const Offset(0.7, 0.7),
          const Offset(0.3, 0.7),
        ],
      );

      expect(created, 0);
      expect(engine.canUndo, isTrue, reason: '只有最初那一笔');
    });
  });
}
