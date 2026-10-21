import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/rust/frb_generated.dart';
import 'src/services/app_settings.dart';
import 'src/services/app_theme.dart';
import 'src/services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 flutter_rust_bridge，加载 Rust 动态库。
  // 必须在任何 Rust API 调用之前完成，否则会抛 "has not been initialized"。
  await RustLib.init();

  // 恢复上次选择的外观模式（默认深色）与行为开关。
  await AppTheme.load();
  await AppSettings.load();

  // 首次启动显示欢迎界面，之后直接进入主界面。
  final settings = SettingsService();
  final showWelcome = await settings.shouldShowWelcome();

  runApp(YStrokesApp(showWelcome: showWelcome));
}
