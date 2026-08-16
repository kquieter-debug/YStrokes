import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/welcome_screen.dart';

/// 应用根组件：负责主题与首页路由。
class YStrokesApp extends StatelessWidget {
  const YStrokesApp({super.key, required this.showWelcome});

  /// 首次启动时为 true，显示欢迎界面；否则直接进入主界面。
  final bool showWelcome;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YStrokes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5),
          brightness: Brightness.dark,
        ),
      ),
      home: showWelcome ? const WelcomeScreen() : const HomeScreen(),
    );
  }
}
