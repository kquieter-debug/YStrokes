import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import 'home_screen.dart';

/// 首次启动展示的欢迎界面
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  Future<void> _onStart(BuildContext context) async {
    // 记录是否首次启动，之后启动不再显示
    await SettingsService().markWelcomeSeen();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              Icon(Icons.brush, size: 96, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                'YStrokes',
                textAlign: TextAlign.center,
                style: textTheme.displaySmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                '专注于笔触的绘画应用',
                textAlign: TextAlign.center,
                style: textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                '现代化的前端框架 高性能的绘图引擎',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(flex: 3),
              FilledButton.icon(
                onPressed: () => _onStart(context),
                icon: const Icon(Icons.arrow_forward),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('开始使用'),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
