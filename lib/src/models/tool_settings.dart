import 'package:flutter/material.dart';

/// 单个工具的设置。
///
/// 画笔与橡皮各自持有独立的颜色与笔宽——这一点与 Photoshop 一致：
/// 切回某个工具时，它上次用的参数还在。
@immutable
class ToolSettings {
  const ToolSettings({
    required this.color,
    required this.widthRatio,
    this.pressureEnabled = false,
  });

  /// 颜色（橡皮忽略该值）。
  final Color color;

  /// 笔宽归一化比例：相对文档短边，例如 0.01 表示 1%。
  final double widthRatio;

  /// 是否按压感变宽。
  ///
  /// 默认关闭：只有显式开启才改变渲染结果，从而保证「关掉压感 = 回到压感之前」。
  /// 画笔默认开启、橡皮默认关闭由画板初始化时指定（见 `CanvasScreen`）。
  ///
  /// 这是一个**全局渲染开关**而非笔画属性：切换后画布上所有该工具的笔画都会
  /// 按新规则重绘（与 Photoshop 的「模拟压力」一致，见 ADR-014）。
  final bool pressureEnabled;

  /// 笔宽的可调范围（归一化）。
  static const double minWidthRatio = 0.002;
  static const double maxWidthRatio = 0.08;

  ToolSettings copyWith({
    Color? color,
    double? widthRatio,
    bool? pressureEnabled,
  }) =>
      ToolSettings(
        color: color ?? this.color,
        widthRatio: widthRatio ?? this.widthRatio,
        pressureEnabled: pressureEnabled ?? this.pressureEnabled,
      );

  /// 供界面展示的百分比文本。
  String get widthLabel => '${(widthRatio * 100).toStringAsFixed(1)}%';
}
