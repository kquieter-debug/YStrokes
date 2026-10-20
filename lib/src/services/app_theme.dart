import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用级外观设置（当前仅主题模式）。
///
/// 采用全局 [ValueNotifier] 而非依赖注入：主题属于应用根节点的单例状态，
/// `MaterialApp` 只需监听它，任意页面都能直接读写，不必层层传递。
///
/// 默认深色，与既有观感保持一致；用户的选择会持久化到 shared_preferences。
abstract final class AppTheme {
  static const String _prefsKey = 'theme_mode';

  /// 当前主题模式。监听它即可在模式变化时重建。
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.dark);

  /// 启动时调用，恢复上次选择。
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = _decode(prefs.getString(_prefsKey));
  }

  /// 切换主题并持久化。
  static Future<void> set(ThemeMode value) async {
    mode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, _encode(value));
  }

  static ThemeMode _decode(String? raw) => switch (raw) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  static String _encode(ThemeMode value) => switch (value) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        ThemeMode.dark => 'dark',
      };
}
