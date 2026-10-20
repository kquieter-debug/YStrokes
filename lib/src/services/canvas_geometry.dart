import 'dart:ui';

/// 计算文档在可用区域内的绘制矩形：保持文档自身宽高比，居中放置。
///
/// 这是「画布独立于屏幕」的实现基础：文档比例由工程自身决定，屏幕怎么变，
/// 文档只是被等比缩放并居中，不会因为视口变化而被拉伸。
///
/// - [available]：可用绘制区域（画布层的大小）。
/// - [aspectRatio]：文档宽高比（`width / height`）。
///
/// 参数非法（区域为空或比例非正）时返回 [Rect.zero]，调用方应跳过绘制。
Rect fitDocumentRect(Size available, double aspectRatio) {
  if (available.width <= 0 ||
      available.height <= 0 ||
      !aspectRatio.isFinite ||
      aspectRatio <= 0) {
    return Rect.zero;
  }

  final viewportAspect = available.width / available.height;
  if (viewportAspect > aspectRatio) {
    // 视口更宽：高度撑满，左右留边（letterbox）。
    final height = available.height;
    final width = height * aspectRatio;
    return Rect.fromLTWH((available.width - width) / 2, 0, width, height);
  }

  // 视口更窄（或等宽）：宽度撑满，上下留边（pillarbox）。
  final width = available.width;
  final height = width / aspectRatio;
  return Rect.fromLTWH(0, (available.height - height) / 2, width, height);
}
