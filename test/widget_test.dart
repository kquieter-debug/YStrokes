import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/app.dart';

void main() {
  testWidgets('首次启动：欢迎界面 → 主界面（空状态）', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const YStrokesApp(showWelcome: true));

    // 欢迎界面。
    expect(find.text('YStrokes'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);

    // 点击「开始使用」进入主界面。
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    // 主界面空状态。
    expect(find.text('还没有工程'), findsOneWidget);
  });

  testWidgets('非首次启动：直接进入主界面', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'welcome_seen': true});

    await tester.pumpWidget(const YStrokesApp(showWelcome: false));
    await tester.pumpAndSettle();

    expect(find.text('还没有工程'), findsOneWidget);
  });
}
