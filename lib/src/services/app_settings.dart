import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用级行为开关（非外观）。
///
/// 与 `AppTheme` 一样用全局 [ValueNotifier]：设置项少且需要被多个页面读到，
/// 引入依赖注入不划算。
abstract final class AppSettings {
  static const String _liveLayerReorderKey = 'live_layer_reorder';

  /// 拖拽调整图层顺序时，是否**即时**重新合成画布。
  ///
  /// 默认关闭：拖动过程中只更新列表内的视觉占位，松手后才真正改写图层顺序并
  /// 重绘。图层多、笔画重时，逐帧重建合成结果会明显掉帧，而拖动本身只需要
  /// 「看起来跟手」。
  static final ValueNotifier<bool> liveLayerReorder = ValueNotifier<bool>(false);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    liveLayerReorder.value = prefs.getBool(_liveLayerReorderKey) ?? false;
  }

  static Future<void> setLiveLayerReorder(bool value) async {
    liveLayerReorder.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liveLayerReorderKey, value);
  }
}
