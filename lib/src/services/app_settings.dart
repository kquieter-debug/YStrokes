import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/export_destination.dart';

/// 应用级行为开关（非外观）。
///
/// 与 `AppTheme` 一样用全局 [ValueNotifier]：设置项少且需要被多个页面读到，
/// 引入依赖注入不划算。
abstract final class AppSettings {
  static const String _liveLayerReorderKey = 'live_layer_reorder';
  static const String _rasterMaskDimKey = 'raster_mask_dim';
  static const String _toolbarXKey = 'canvas_toolbar_x';
  static const String _toolbarYKey = 'canvas_toolbar_y';
  static const String _exportDestinationKey = 'export_destination';

  /// 拖拽调整图层顺序时，是否**即时**重新合成画布。
  ///
  /// 默认关闭：拖动过程中只更新列表内的视觉占位，松手后才真正改写图层顺序并
  /// 重绘。图层多、笔画重时，逐帧重建合成结果会明显掉帧，而拖动本身只需要
  /// 「看起来跟手」。
  static final ValueNotifier<bool> liveLayerReorder = ValueNotifier<bool>(false);

  /// 像素选区是否把**选区之外**压暗（快速蒙版效果）。
  ///
  /// 默认开启：压暗让「哪一块被选中」在任何底色上都一眼可辨，比单靠一圈虚线清楚。
  /// 但它会盖住画面的一部分细节，因此在设置里留了开关。
  /// 选区的**流动虚线**不受这个开关影响，始终显示。
  static final ValueNotifier<bool> rasterMaskDim = ValueNotifier<bool>(true);

  /// 画板工具栏的锚点位置。
  ///
  /// 取值是 `0~1` 的**归一化**坐标：`(0, 0)` 左上、`(1, 1)` 右下、`(1, 0.5)` 右侧居中。
  /// 用归一化而不是像素，是因为同一份偏好在竖屏、横屏、分屏与不同 DPI 的设备上
  /// 都要落在视觉上等价的位置；像素值换个屏幕就可能跑到画面外。
  ///
  /// `null` 表示「从未拖动过」，由画板使用默认位置（贴左、垂直居中）。
  static final ValueNotifier<Offset?> toolbarAnchor = ValueNotifier<Offset?>(null);

  /// 导出目标（默认位置 / 自选目录）。
  ///
  /// 记忆的是「用户上次选的位置」，而不只是本次会话的选项：导出目录一旦选定，
  /// 下次导出理应还落在那里，否则每次都要重新挑一遍。
  static final ValueNotifier<ExportDestination> exportDestination =
      ValueNotifier<ExportDestination>(ExportDestination.platformDefault);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    liveLayerReorder.value = prefs.getBool(_liveLayerReorderKey) ?? false;
    rasterMaskDim.value = prefs.getBool(_rasterMaskDimKey) ?? true;

    final x = prefs.getDouble(_toolbarXKey);
    final y = prefs.getDouble(_toolbarYKey);
    toolbarAnchor.value =
        (x == null || y == null) ? null : Offset(x, y);

    exportDestination.value =
        ExportDestination.decode(prefs.getString(_exportDestinationKey));
  }

  static Future<void> setLiveLayerReorder(bool value) async {
    liveLayerReorder.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liveLayerReorderKey, value);
  }

  static Future<void> setRasterMaskDim(bool value) async {
    rasterMaskDim.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rasterMaskDimKey, value);
    } catch (_) {
      // 偏好不可用：本次会话仍然生效，下次启动回默认。
    }
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

  /// 记住导出目标；传默认位置等于清除自定义。
  static Future<void> setExportDestination(ExportDestination value) async {
    exportDestination.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = value.encode();
      if (encoded == null) {
        await prefs.remove(_exportDestinationKey);
      } else {
        await prefs.setString(_exportDestinationKey, encoded);
      }
    } catch (_) {
      // 同上：记忆失败不影响本次导出。
    }
  }
}
