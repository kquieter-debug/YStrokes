import '../rust/api/document.dart' as rust_doc;
import 'stroke.dart';

/// 一个图层。
///
/// 图层本身只承载「一组笔画 + 合成参数」，不持有画布尺寸等文档级信息。
/// 顺序即绘制顺序：索引 0 在最底层。
class DrawingLayer {
  DrawingLayer({
    required this.id,
    required this.name,
    this.opacity = 1.0,
    this.visible = true,
    this.blendMode = rust_doc.LayerBlendMode.normal,
    List<Stroke>? strokes,
  }) : strokes = strokes ?? <Stroke>[];

  /// 会话内唯一 id。持久化格式里不存该值——载入时按顺序重新分配即可，
  /// 它只在「选中哪一层」与撤销记录中使用。
  final String id;

  String name;

  /// 不透明度 0.0 ~ 1.0。
  double opacity;

  bool visible;

  /// 与下方图层内容的混合方式。
  rust_doc.LayerBlendMode blendMode;

  final List<Stroke> strokes;

  bool get isEmpty => strokes.isEmpty;

  /// 是否只包含矢量内容。
  ///
  /// 当前文档只有笔画，因此恒为 true。位图图层（导入图片、PSD 合成、
  /// SVG 栅格化结果）落地后由图层类型决定；导出侧的「能否导出纯矢量 SVG」
  /// 判定只依赖这个属性，届时无需改动导出逻辑。
  bool get isVector => true;

  rust_doc.Layer toRust() => rust_doc.Layer(
        name: name,
        opacity: opacity,
        visible: visible,
        blendMode: blendMode,
        strokes: strokes.map((stroke) => stroke.toRust()).toList(),
      );

  factory DrawingLayer.fromRust(rust_doc.Layer source, {required String id}) =>
      DrawingLayer(
        id: id,
        name: source.name,
        opacity: source.opacity.clamp(0.0, 1.0),
        visible: source.visible,
        blendMode: source.blendMode,
        strokes: source.strokes.map(Stroke.fromRust).toList(),
      );
}
