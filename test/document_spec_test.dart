import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/models/document_spec.dart';

void main() {
  group('单位换算', () {
    test('毫米 → 像素（300 ppi 下 A4 宽 210mm）', () {
      expect(
        DocumentSpec.toPixels(210, DocumentUnit.millimeter, 300),
        closeTo(2480.31, 0.01),
      );
    });

    test('英寸 → 像素', () {
      expect(DocumentSpec.toPixels(6, DocumentUnit.inch, 300), 1800);
    });

    test('像素单位直接返回', () {
      expect(DocumentSpec.toPixels(1080, DocumentUnit.pixel, 72), 1080);
    });

    test('像素 ↔ 毫米可往返', () {
      final mm = DocumentSpec.fromPixels(2480, DocumentUnit.millimeter, 300);
      expect(
        DocumentSpec.toPixels(mm, DocumentUnit.millimeter, 300),
        closeTo(2480, 0.5),
      );
    });

    test('dpi 为 0 时换算不产生除零', () {
      expect(DocumentSpec.fromPixels(100, DocumentUnit.millimeter, 0), 0);
    });
  });

  group('DocumentSpec', () {
    test('宽高比由像素尺寸派生', () {
      const spec = DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72);
      expect(spec.aspectRatio, closeTo(0.5625, 1e-9));
      expect(spec.shortSidePx, 1080);
    });

    test('物理尺寸按 dpi 计算', () {
      const spec = DocumentSpec(widthPx: 1800, heightPx: 1200, dpi: 300);
      expect(spec.widthInch, closeTo(6, 1e-9));
      expect(spec.heightInch, closeTo(4, 1e-9));
    });

    test('JSON 往返保留全部字段', () {
      const spec = DocumentSpec(
        widthPx: 2480,
        heightPx: 3508,
        dpi: 300,
        backgroundArgb: 0xFFF7F3E9,
      );
      final restored = DocumentSpec.fromJson(spec.toJson());
      expect(restored.widthPx, spec.widthPx);
      expect(restored.heightPx, spec.heightPx);
      expect(restored.dpi, spec.dpi);
      expect(restored.backgroundArgb, spec.backgroundArgb);
    });

    test('缺省背景色回退为白色', () {
      final restored = DocumentSpec.fromJson(<String, dynamic>{
        'widthPx': 100,
        'heightPx': 100,
        'dpi': 72,
      });
      expect(restored.backgroundArgb, 0xFFFFFFFF);
    });

    test('历史工程的宽高比可还原为等效规格', () {
      final portrait = DocumentSpec.fromLegacyAspect(0.75);
      expect(portrait.aspectRatio, closeTo(0.75, 1e-3));
      expect(portrait.shortSidePx, 2048);

      final landscape = DocumentSpec.fromLegacyAspect(16 / 9);
      expect(landscape.aspectRatio, closeTo(16 / 9, 1e-3));
      expect(landscape.shortSidePx, 2048);

      // 缺失或非法时退化为 3:4，不抛错。
      expect(
        DocumentSpec.fromLegacyAspect(null).aspectRatio,
        closeTo(0.75, 1e-3),
      );
    });

    test('合法性判定', () {
      expect(
        const DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72).isValid,
        isTrue,
      );
      expect(
        const DocumentSpec(widthPx: 8, heightPx: 1920, dpi: 72).isValid,
        isFalse,
      );
      expect(
        const DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 0).isValid,
        isFalse,
      );
    });
  });
}
