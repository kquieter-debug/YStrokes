import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/app_theme.dart';

/// 应用根组件：负责主题与首页路由。
///
/// 主题模式来自 [AppTheme.mode]，切换后无需重启即可整体刷新。
class YStrokesApp extends StatelessWidget {
  const YStrokesApp({super.key, required this.showWelcome});

  /// 首次启动时为 true，显示欢迎界面；否则直接进入主界面。
  final bool showWelcome;

  static const Color _seedColor = Color(0xFF4F46E5);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'YStrokes',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: mode,
        home: showWelcome ? const WelcomeScreen() : const HomeScreen(),
      ),
    );
  }

  static ThemeData _buildTheme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: brightness,
        ),
      );
}
