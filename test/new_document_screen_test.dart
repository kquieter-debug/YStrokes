import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/screens/new_document_screen.dart';

/// 新建文档页的行为：模板选择、单位换算、校验与结果回传。
void main() {
  /// 打开新建文档页，并把页面返回的结果交给 [onResult]。
  Future<void> openScreen(
    WidgetTester tester,
    ValueSetter<NewDocumentResult?> onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final result =
                      await Navigator.of(context).push<NewDocumentResult>(
                    MaterialPageRoute<NewDocumentResult>(
                      builder: (_) => const NewDocumentScreen(),
                    ),
                  );
                  onResult(result);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认载入首个模板（手机竖屏）', (tester) async {
    await openScreen(tester, (_) {});

    expect(find.text('新建文档'), findsOneWidget);
    expect(find.text('1080 × 1920 px · 72 ppi'), findsOneWidget);
    expect(find.textContaining('1080 × 1920 px'), findsWidgets);
  });

  testWidgets('选择 A4 模板直接得到 2480×3508 / 300ppi', (tester) async {
    NewDocumentResult? result;
    await openScreen(tester, (value) => result = value);

    await tester.tap(find.text('A4 纸'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('doc-create')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.document.widthPx, 2480);
    expect(result!.document.heightPx, 3508);
    expect(result!.document.dpi, 300);
    expect(result!.name, '未命名-1');
  });

  testWidgets('毫米输入按当前 ppi 换算为像素', (tester) async {
    NewDocumentResult? result;
    await openScreen(tester, (value) => result = value);

    // 切到毫米后，先填物理尺寸，再改 ppi —— 尺寸应保持，像素随之换算。
    await tester.tap(find.text('毫米'));
    await tester.pumpAndSettle();

    Future<void> typeInto(String key, String text) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
      await tester.enterText(find.byKey(Key(key)), text);
      await tester.pump();
    }

    await typeInto('doc-width', '210');
    await typeInto('doc-height', '297');
    await typeInto('doc-dpi', '300');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('doc-create')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.document.widthPx, 2480);
    expect(result!.document.heightPx, 3508);
    expect(result!.document.dpi, 300);
  });

  testWidgets('名称为空时禁止创建', (tester) async {
    await openScreen(tester, (_) {});

    await tester.enterText(find.byKey(const Key('doc-name')), '');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('doc-create')),
    );
    expect(button.onPressed, isNull, reason: '名称为空时不应允许创建');
  });
}
