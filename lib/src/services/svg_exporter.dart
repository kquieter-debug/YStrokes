import '../models/document_spec.dart';
import '../models/layer.dart';
import '../models/layer_blend.dart';
import '../models/stroke.dart';
import '../rust/api/stroke.dart' as rust;

/// 把文档转换为可再编辑的 SVG。
///
/// 设计约束（与画布渲染保持一致，否则「所见即所得」不成立）：
/// - 路径使用与 `paintStrokePath` 相同的二次贝塞尔构造：以相邻采样点的中值作
///   端点、原始点作控制点。
/// - 坐标由归一化值乘以文档像素尺寸得到；笔宽为 `宽度比例 × 短边`。
/// - 橡皮无法表达为「减去的路径」，转为 `<mask>`：白色铺底 + 黑色擦除路径，
///   结果仍是纯矢量，可继续在矢量编辑器里修改。
/// - 只有可见且非空的图层会输出；隐藏图层完全不参与。
///
/// 输出中每个图层是一个 `<g>`，带 `data-name`（中文名）与稳定的 `id`，
/// 便于在 Illustrator / Figma / Inkscape 中按图层编辑。
String buildDocumentSvg({
  required DocumentSpec document,
  required List<DrawingLayer> layers,
}) {
  final width = document.widthPx.toDouble();
  final height = document.heightPx.toDouble();
  final shortestSide = width < height ? width : height;

  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'width="${_num(width)}" height="${_num(height)}" '
      'viewBox="0 0 ${_num(width)} ${_num(height)}">',
    );

  var layerIndex = 0;
  for (final layer in layers) {
    if (!layer.visible || layer.opacity <= 0) continue;
    final brushes = layer.strokes.where((stroke) => !stroke.isEraser).toList();
    final erasers = layer.strokes.where((stroke) => stroke.isEraser).toList();
    if (brushes.isEmpty && erasers.isEmpty) continue;

    layerIndex++;
    final layerId = 'layer-$layerIndex';
    final attrs = <String>[
      'id="${_escapeAttr(layerId)}"',
      'data-name="${_escapeAttr(layer.name)}"',
    ];
    if (layer.opacity < 0.999) {
      attrs.add('opacity="${_num(layer.opacity)}"');
    }
    if (!layer.blendMode.isNormal) {
      attrs.add('style="mix-blend-mode:${_cssBlend(layer.blendMode)}"');
    }

    // 擦除必须通过蒙版表达：先用白色铺满，再把擦除笔画画成黑色。
    final maskId = 'erase-$layerIndex';
    if (erasers.isNotEmpty) {
      attrs.add('mask="url(#$maskId)"');
    }

    buffer.writeln('  <g ${attrs.join(' ')}>');

    if (erasers.isNotEmpty) {
      buffer
        ..writeln(
          '    <mask id="$maskId" maskUnits="userSpaceOnUse" '
          'x="0" y="0" width="${_num(width)}" height="${_num(height)}">',
        )
        ..writeln(
          '      <rect x="0" y="0" width="${_num(width)}" '
          'height="${_num(height)}" fill="#FFFFFF"/>',
        );
      for (final stroke in erasers) {
        if (stroke.points.isEmpty) continue;
        buffer.writeln(
          '      ${_pathElement(stroke, width, height, shortestSide, forceBlack: true)}',
        );
      }
      buffer.writeln('    </mask>');
    }

    for (final stroke in brushes) {
      if (stroke.points.isEmpty) continue;
      buffer.writeln(
        '    ${_pathElement(stroke, width, height, shortestSide)}',
      );
    }

    buffer.writeln('  </g>');
  }

  buffer.writeln('</svg>');
  return buffer.toString();
}

/// 单条笔画的 SVG 元素。
///
/// 单点笔画输出 `<circle>`——与画布上「点一下留下圆点」的行为保持一致；
/// 多点为 `<path>`。
String _pathElement(
  Stroke stroke,
  double width,
  double height,
  double shortestSide, {
  bool forceBlack = false,
}) {
  final points = stroke.points;
  final strokeWidth = stroke.widthRatio * shortestSide;
  final color = forceBlack
      ? '#000000'
      : '#${(stroke.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  if (points.length == 1) {
    final p = points.first;
    final cx = _num(p.x * width);
    final cy = _num(p.y * height);
    return '<circle cx="$cx" cy="$cy" r="${_num(strokeWidth / 2)}" fill="$color"/>';
  }

  final d = _pathData(points, width, height);
  return '<path d="$d" fill="none" stroke="$color" '
      'stroke-width="${_num(strokeWidth)}" '
      'stroke-linecap="round" stroke-linejoin="round"/>';
}

/// 与画布一致的路径数据：`M … Q(控制点=原始点, 端点=相邻中值) … L 末点`。
String _pathData(List<rust.StrokePoint> points, double width, double height) {
  final buffer = StringBuffer();
  final first = points.first;
  buffer.write('M ${_num(first.x * width)} ${_num(first.y * height)}');

  for (var i = 1; i < points.length - 1; i++) {
    final current = points[i];
    final next = points[i + 1];
    final cx = current.x * width;
    final cy = current.y * height;
    final mx = (current.x + next.x) / 2 * width;
    final my = (current.y + next.y) / 2 * height;
    buffer.write(' Q ${_num(cx)} ${_num(cy)} ${_num(mx)} ${_num(my)}');
  }

  final last = points.last;
  buffer.write(' L ${_num(last.x * width)} ${_num(last.y * height)}');
  return buffer.toString();
}

/// CSS `mix-blend-mode` 名称。
String _cssBlend(LayerBlendMode mode) => switch (mode) {
      LayerBlendMode.normal => 'normal',
      LayerBlendMode.multiply => 'multiply',
      LayerBlendMode.screen => 'screen',
      LayerBlendMode.overlay => 'overlay',
      LayerBlendMode.darken => 'darken',
      LayerBlendMode.lighten => 'lighten',
      LayerBlendMode.colorDodge => 'color-dodge',
      LayerBlendMode.colorBurn => 'color-burn',
      LayerBlendMode.softLight => 'soft-light',
      LayerBlendMode.hardLight => 'hard-light',
      LayerBlendMode.difference => 'difference',
      LayerBlendMode.exclusion => 'exclusion',
    };

/// 数值格式化：整数不带小数点，其余最多两位小数（去掉尾随 0）。
String _num(double value) {
  if (value.isNaN || value.isInfinite) return '0';
  if ((value - value.roundToDouble()).abs() < 1e-6) {
    return value.round().toString();
  }
  final text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String _escapeAttr(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
    .replaceAll('\n', ' ')
    .replaceAll('\r', ' ');
