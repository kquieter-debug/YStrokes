import 'document_spec.dart';

/// 画布模板（预设）。
///
/// 参照 Photoshop 新建文档的思路：先选模板再微调，而不是让用户面对空白参数。
/// 预设只是 [DocumentSpec] 的常用组合，选定后仍可手动修改任意字段。
class CanvasPreset {
  const CanvasPreset({
    required this.name,
    required this.summary,
    required this.spec,
  });

  final String name;

  /// 展示用摘要，例如「1080 × 1920 px · 72 ppi」。
  final String summary;

  final DocumentSpec spec;

  static const List<CanvasPreset> all = <CanvasPreset>[
    CanvasPreset(
      name: '手机竖屏',
      summary: '1080 × 1920 px · 72 ppi',
      spec: DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72),
    ),
    CanvasPreset(
      name: '手机横屏',
      summary: '1920 × 1080 px · 72 ppi',
      spec: DocumentSpec(widthPx: 1920, heightPx: 1080, dpi: 72),
    ),
    CanvasPreset(
      name: '正方形',
      summary: '2048 × 2048 px · 72 ppi',
      spec: DocumentSpec(widthPx: 2048, heightPx: 2048, dpi: 72),
    ),
    CanvasPreset(
      name: 'A4 纸',
      summary: '210 × 297 mm · 300 ppi',
      spec: DocumentSpec(widthPx: 2480, heightPx: 3508, dpi: 300),
    ),
    CanvasPreset(
      name: 'A5 纸',
      summary: '148 × 210 mm · 300 ppi',
      spec: DocumentSpec(widthPx: 1748, heightPx: 2480, dpi: 300),
    ),
    CanvasPreset(
      name: '照片 6×4',
      summary: '6 × 4 英寸 · 300 ppi',
      spec: DocumentSpec(widthPx: 1800, heightPx: 1200, dpi: 300),
    ),
  ];
}
