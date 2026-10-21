import 'dart:math' as math;

/// 画布的计量单位。
enum DocumentUnit {
  pixel('像素', 'px'),
  millimeter('毫米', 'mm'),
  centimeter('厘米', 'cm'),
  inch('英寸', 'in');

  const DocumentUnit(this.label, this.suffix);

  final String label;
  final String suffix;
}

/// 一个文档的像素与物理规格。
///
/// **像素尺寸是唯一权威值**：宽高比、画笔粗细、导出尺寸都由它派生。
/// 分辨率（ppi/dpi）只参与「物理尺寸 ↔ 像素」的换算与打印输出，不影响屏幕渲染。
class DocumentSpec {
  const DocumentSpec({
    required this.widthPx,
    required this.heightPx,
    required this.dpi,
    this.backgroundArgb = 0xFFFFFFFF,
  });

  final int widthPx;
  final int heightPx;

  /// 像素密度（ppi）。例如 A4 常用 300。
  final double dpi;

  /// 纸面底色（ARGB）。
  final int backgroundArgb;

  double get aspectRatio => heightPx <= 0 ? 1 : widthPx / heightPx;

  int get shortSidePx => math.min(widthPx, heightPx);

  /// 物理宽度（英寸）。
  double get widthInch => dpi <= 0 ? 0 : widthPx / dpi;

  /// 物理高度（英寸）。
  double get heightInch => dpi <= 0 ? 0 : heightPx / dpi;

  /// 规格是否可用于创建文档。
  bool get isValid =>
      widthPx >= 16 && heightPx >= 16 && dpi >= 1 && dpi <= 1200;

  /// 把「指定单位下的数值」换算为像素。
  static double toPixels(double value, DocumentUnit unit, double dpi) =>
      switch (unit) {
        DocumentUnit.pixel => value,
        DocumentUnit.millimeter => value / 25.4 * dpi,
        DocumentUnit.centimeter => value / 2.54 * dpi,
        DocumentUnit.inch => value * dpi,
      };

  /// 把像素换算为「指定单位下的数值」。
  static double fromPixels(num pixels, DocumentUnit unit, double dpi) =>
      switch (unit) {
        DocumentUnit.pixel => pixels.toDouble(),
        DocumentUnit.millimeter => dpi <= 0 ? 0 : pixels / dpi * 25.4,
        DocumentUnit.centimeter => dpi <= 0 ? 0 : pixels / dpi * 2.54,
        DocumentUnit.inch => dpi <= 0 ? 0 : pixels / dpi,
      };

  DocumentSpec copyWith({
    int? widthPx,
    int? heightPx,
    double? dpi,
    int? backgroundArgb,
  }) =>
      DocumentSpec(
        widthPx: widthPx ?? this.widthPx,
        heightPx: heightPx ?? this.heightPx,
        dpi: dpi ?? this.dpi,
        backgroundArgb: backgroundArgb ?? this.backgroundArgb,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'widthPx': widthPx,
        'heightPx': heightPx,
        'dpi': dpi,
        'backgroundArgb': backgroundArgb,
      };

  factory DocumentSpec.fromJson(Map<String, dynamic> json) => DocumentSpec(
        widthPx: (json['widthPx'] as num).toInt(),
        heightPx: (json['heightPx'] as num).toInt(),
        dpi: (json['dpi'] as num).toDouble(),
        backgroundArgb:
            (json['backgroundArgb'] as num?)?.toInt() ?? 0xFFFFFFFF,
      );

}
