import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用级行为开关（非外观）。
///
/// 与 `AppTheme` 一样用全局 [ValueNotifier]：设置项少且需要被多个页面读到，
/// 引入依赖注入不划算。
abstract final class AppSettings {
  static const String _liveLayerReorderKey = 'live_layer_reorder';
  static const String _toolbarXKey = 'canvas_toolbar_x';
  static const String _toolbarYKey = 'canvas_toolbar_y';

  /// 拖拽调整图层顺序时，是否**即时**重新合成画布。
  ///
  /// 默认关闭：拖动过程中只更新列表内的视觉占位，松手后才真正改写图层顺序并
  /// 重绘。图层多、笔画重时，逐帧重建合成结果会明显掉帧，而拖动本身只需要
  /// 「看起来跟手」。
  static final ValueNotifier<bool> liveLayerReorder = ValueNotifier<bool>(false);

  /// 画板工具栏的锚点位置。
  ///
  /// 取值是 `0~1` 的**归一化**坐标：`(0, 0)` 左上、`(1, 1)` 右下、`(1, 0.5)` 右侧居中。
  /// 用归一化而不是像素，是因为同一份偏好在竖屏、横屏、分屏与不同 DPI 的设备上
  /// 都要落在视觉上等价的位置；像素值换个屏幕就可能跑到画面外。
  ///
  /// `null` 表示「从未拖动过」，由画板使用默认位置（贴左、垂直居中）。
  static final ValueNotifier<Offset?> toolbarAnchor = ValueNotifier<Offset?>(null);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    liveLayerReorder.value = prefs.getBool(_liveLayerReorderKey) ?? false;

    final x = prefs.getDouble(_toolbarXKey);
    final y = prefs.getDouble(_toolbarYKey);
    toolbarAnchor.value =
        (x == null || y == null) ? null : Offset(x, y);
  }

  static Future<void> setLiveLayerReorder(bool value) async {
    liveLayerReorder.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liveLayerReorderKey, value);
  }

  /// 记住工具栏位置；传 `null` 表示恢复默认。
  ///
  /// 写盘失败不影响本次拖动（位置已在内存里生效），因此整体吞掉异常——
  /// 记住位置是锦上添花，不该因为它让画板报错。
  static Future<void> setToolbarAnchor(Offset? value) async {
    toolbarAnchor.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_toolbarXKey);
        await prefs.remove(_toolbarYKey);
      } else {
        await prefs.setDouble(_toolbarXKey, value.dx);
        await prefs.setDouble(_toolbarYKey, value.dy);
      }
    } catch (_) {
      // 偏好不可用（例如测试环境未注册插件）：只影响下次启动的位置。
    }
  }
}
