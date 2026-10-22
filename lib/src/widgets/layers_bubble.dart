import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/drawing_engine.dart';
import 'bubble_surface.dart';
import 'layers_panel.dart';

/// 图层气泡：固定在屏幕右侧、从顶栏「图层」按钮下方向下展开。
///
/// 为什么不像工具设置气泡那样跟着工具栏走：图层不是「画一笔」的即时参数，
/// 它是全局结构，固定在右上角更符合「随时点开看一眼」的使用节奏；而且图层
/// 内容比工具设置高得多，横向跟随会频繁压到画布中央。
///
/// 展开方向固定为向下，所以缩放锚点取右上角——动画看起来是从按钮下沿长出来的。
class LayersBubble extends StatelessWidget {
  const LayersBubble({
    super.key,
    required this.engine,
    required this.anchor,
    required this.onChanged,
    required this.onCleared,
    required this.onTransform,
    required this.onFlip,
    required this.onClose,
    this.animation,
  });

  final DrawingEngine engine;

  /// 顶栏「图层」按钮的全局矩形；气泡上沿落在它下方。
  final Rect anchor;

  /// 图层状态改变后回调：通知画板重绘并触发自动保存。
  final VoidCallback onChanged;

  /// 刚刚清空过当前图层，由画板弹提示。
  final VoidCallback onCleared;

  /// 请求对某图层做整体变换。
  final ValueChanged<String> onTransform;

  /// 翻转整层：`(layerId, 是否水平)`。
  final void Function(String layerId, bool horizontal) onFlip;

  final VoidCallback onClose;

  final Animation<double>? animation;

  /// 与按钮、屏幕边缘的间距。
  static const double _gap = 10;

  /// 面板宽度上限：再宽就会盖住画布中线。
  static const double _maxWidth = 320;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final inset = media.padding;

    // 固定贴屏幕右缘，而不是对齐按钮：按钮是「触发器」，气泡是「停靠的侧栏」。
    // 对齐按钮会让面板整体左移，反而比贴边更靠画面中央。
    final right = inset.right + _gap;
    // 不设宽度下限，只受可用宽度与上限约束——窄屏上宁可瘦一点也不越界。
    final width = math.min(screen.width - right - inset.left - _gap, _maxWidth);

    final top = anchor.bottom + 4;
    // 向下展开：剩余高度即上限，内容超出时由面板内部滚动消化。
    final maxHeight = math.max(240.0, screen.height - inset.bottom - _gap - top);

    return Stack(
      children: [
        BubbleBarrier(key: const Key('layers-barrier'), onClose: onClose),
        Positioned(
          key: const Key('layers-bubble'),
          top: top,
          right: right,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: BubbleSurface(
              animation: animation,
              alignment: Alignment.topRight,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: LayersPanel(
                  engine: engine,
                  onChanged: onChanged,
                  onClose: onClose,
                  onCleared: onCleared,
                  onTransform: onTransform,
                  onFlip: onFlip,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
