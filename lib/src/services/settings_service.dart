import 'package:shared_preferences/shared_preferences.dart';

/// 应用级设置（当前仅用于「首次启动欢迎界面」）。
class SettingsService {
  static const String _welcomeSeenKey = 'welcome_seen';

  /// 是否应显示欢迎界面（首次启动时返回 true）。
  Future<bool> shouldShowWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_welcomeSeenKey) ?? false);
  }

  /// 标记欢迎界面已展示，后续启动不再显示。
  Future<void> markWelcomeSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_welcomeSeenKey, true);
  }

  /// 清除「已展示」标记，下次启动重新显示欢迎界面。
  Future<void> resetWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_welcomeSeenKey);
  }
}
