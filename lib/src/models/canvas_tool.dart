import '../rust/api/tools.dart';

/// 工具栏里的工具。
///
/// 与 Rust 的 [ToolKind] **有意分开**：`ToolKind` 是**笔画自身的属性**——它随笔画
/// 落盘、决定渲染方式；而工具栏里还有不产生笔画的交互工具（吸管、套索）。
/// 把两者合成一个枚举，文档格式就会被逼着容纳纯 UI 概念，将来加「移动视图」
/// 这类工具时还会污染解码逻辑。
enum CanvasTool {
  brush(label: '画笔', strokeKind: ToolKind.brush),
  eraser(label: '橡皮', strokeKind: ToolKind.eraser),
  eyedropper(label: '吸管', strokeKind: null),
  lasso(label: '选区', strokeKind: null);

  const CanvasTool({required this.label, required this.strokeKind});

  final String label;

  /// 该工具产生的笔画类型；为空表示它不画画。
  final ToolKind? strokeKind;

  /// 是否会产生笔画（决定是否需要笔宽、颜色、压感等参数）。
  bool get paints => strokeKind != null;

  bool get isEraser => strokeKind == ToolKind.eraser;
}
