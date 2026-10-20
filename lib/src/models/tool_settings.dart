import 'package:flutter/material.dart';

/// 单个工具的设置。
///
/// 画笔与橡皮各自持有独立的颜色与笔宽——这一点与 Photoshop 一致：
/// 切回某个工具时，它上次用的参数还在。
@immutable
class ToolSettings {
  const ToolSettings({required this.color, required this.widthRatio});

  /// 颜色（橡皮忽略该值）。
  final Color color;

  /// 笔宽归一化比例：相对文档短边，例如 0.01 表示 1%。
  final double widthRatio;

  /// 笔宽的可调范围（归一化）。
  static const double minWidthRatio = 0.002;
  static const double maxWidthRatio = 0.08;

  ToolSettings copyWith({Color? color, double? widthRatio}) => ToolSettings(
        color: color ?? this.color,
        widthRatio: widthRatio ?? this.widthRatio,
      );

  /// 供界面展示的百分比文本。
  String get widthLabel => '${(widthRatio * 100).toStringAsFixed(1)}%';
}
