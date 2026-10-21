import 'package:flutter/foundation.dart';

import '../rust/api/tools.dart';

/// 渲染笔画时的全局选项。
///
/// 这是**视图层开关**，不是文档数据：它不落盘，也不改变笔画本身，只决定
/// 「已提交的笔画此刻怎么画」。因此切换开关会让整篇内容重绘一遍，
/// 与 Photoshop 的「模拟压力」行为一致（见 ADR-014）。
///
/// 两个开关分工具保存，但**渲染时同时生效**：画着画笔时，画布上已有的橡皮笔画
/// 仍要按 [eraserPressure] 决定是否变宽，否则切换工具会让画面跳变。
@immutable
class StrokeRenderOptions {
  const StrokeRenderOptions({
    this.brushPressure = false,
    this.eraserPressure = false,
  });

  /// 关闭全部压感：渲染结果与引入压感之前逐位一致。
  static const StrokeRenderOptions none = StrokeRenderOptions();

  /// 画笔笔画是否按压感变宽。
  final bool brushPressure;

  /// 橡皮笔画是否按压感变宽。
  final bool eraserPressure;

  bool get anyPressure => brushPressure || eraserPressure;

  /// 指定工具产出的笔画是否按压感渲染。
  bool pressureFor(ToolKind tool) =>
      tool == ToolKind.eraser ? eraserPressure : brushPressure;

  @override
  bool operator ==(Object other) =>
      other is StrokeRenderOptions &&
      other.brushPressure == brushPressure &&
      other.eraserPressure == eraserPressure;

  @override
  int get hashCode => Object.hash(brushPressure, eraserPressure);

  @override
  String toString() =>
      'StrokeRenderOptions(brush: $brushPressure, eraser: $eraserPressure)';
}
