import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从一帧画面里取一个像素的颜色（吸管工具）。
///
/// 做法是把整篇内容画到 **1×1** 的画布上再读取：整幅光栅化（1080×1920 约 8MB）
/// 只为取一个像素是浪费，而裁剪到 1×1 之后光栅器只处理落在这一个像素上的内容。
///
/// 取到的是**合成后的颜色**（含图层不透明度与混合模式），这正是「屏幕上看到的
/// 那个颜色」。透明像素（纸外或透明区域）回落到 [fallback]，通常是纸色——
/// 返回黑色会让「点了空白却取到黑」显得像 bug。
Future<Color> sampleColorAt({
  required ui.Picture picture,
  required Offset docPoint,
  required Color fallback,
}) async {
  ui.Image? shot;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..translate(-docPoint.dx, -docPoint.dy);
    canvas.drawPicture(picture);
    shot = await recorder.endRecording().toImage(1, 1);

    final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return fallback;

    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (bytes.length < 4 || bytes[3] == 0) return fallback;
    return Color.from(
      alpha: bytes[3] / 255,
      red: bytes[0] / 255,
      green: bytes[1] / 255,
      blue: bytes[2] / 255,
    );
  } catch (_) {
    // 光栅化失败（例如测试环境没有 GPU）不应让吸管崩掉，回落纸色即可。
    return fallback;
  } finally {
    shot?.dispose();
  }
}
