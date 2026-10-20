import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/canvas_geometry.dart';

void main() {
  group('fitDocumentRect', () {
    test('宽视口：高度撑满并水平居中', () {
      // 800×600 视口，文档 1:1 → 文档 600×600，左右各留 100。
      final rect = fitDocumentRect(const Size(800, 600), 1.0);
      expect(rect.left, 100);
      expect(rect.top, 0);
      expect(rect.width, 600);
      expect(rect.height, 600);
    });

    test('高视口：宽度撑满并垂直居中', () {
      // 400×800 视口，文档 1:1 → 文档 400×400，上下各留 200。
      final rect = fitDocumentRect(const Size(400, 800), 1.0);
      expect(rect.left, 0);
      expect(rect.top, 200);
      expect(rect.width, 400);
      expect(rect.height, 400);
    });

    test('文档始终位于视口内且不越界', () {
      final rect = fitDocumentRect(const Size(360, 780), 3 / 4);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.bottom, lessThanOrEqualTo(780));
    });

    test('旋转屏幕后文档宽高比不变（画布独立于设备）', () {
      const aspect = 3 / 4;
      final portrait = fitDocumentRect(const Size(400, 800), aspect);
      final landscape = fitDocumentRect(const Size(800, 400), aspect);

      expect(portrait.width / portrait.height, closeTo(aspect, 1e-9));
      expect(landscape.width / landscape.height, closeTo(aspect, 1e-9));

      // 旋转后显示尺寸改变，但形状不变——这正是「画布不受屏幕调整影响」的定义。
      expect(portrait.width, isNot(landscape.width));
    });

    test('宽高比相等时铺满且无偏移', () {
      final rect = fitDocumentRect(const Size(500, 500), 1.0);
      expect(rect, const Rect.fromLTWH(0, 0, 500, 500));
    });

    test('非法输入返回 Rect.zero', () {
      expect(fitDocumentRect(Size.zero, 1.0), Rect.zero);
      expect(fitDocumentRect(const Size(-10, 100), 1.0), Rect.zero);
      expect(fitDocumentRect(const Size(100, 100), 0), Rect.zero);
      expect(fitDocumentRect(const Size(100, 100), -1), Rect.zero);
      expect(fitDocumentRect(const Size(100, 100), double.nan), Rect.zero);
      expect(fitDocumentRect(const Size(100, 100), double.infinity), Rect.zero);
    });
  });
}
