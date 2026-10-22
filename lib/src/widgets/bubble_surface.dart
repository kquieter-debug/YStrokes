import 'package:flutter/material.dart';

/// 气泡的出入场动画：淡入 + 轻微放大。
///
/// 缩放锚点由 [alignment] 指定，指向气泡「长出来」的那条边——工具气泡朝工具栏、
/// 图层气泡朝右上角。因此动画看起来是从触发点弹出，而不是在屏幕中央凭空放大。
///
/// 时长由调用方的路由决定（见 `CanvasScreen` 的 `showGeneralDialog`）：
/// 气泡本身只负责「随动画走」，不决定快慢。
class BubbleSurface extends StatefulWidget {
  const BubbleSurface({
    super.key,
    required this.alignment,
    required this.child,
    this.animation,
  });

  /// 缩放锚点。
  final Alignment alignment;

  final Widget child;

  /// 为空时直接呈现（便于单独测试布局，不必造动画控制器）。
  final Animation<double>? animation;

  @override
  State<BubbleSurface> createState() => _BubbleSurfaceState();
}

class _BubbleSurfaceState extends State<BubbleSurface> {
  /// 从 94% 放大到 100%：再小像闪烁，再大则拖慢「立刻可用」的感觉。
  static const double _scaleFrom = 0.94;

  CurvedAnimation? _curve;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant BubbleSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve?.dispose();
      _bind();
    }
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }

  void _bind() {
    final animation = widget.animation;
    // 退场用对称的 easeInCubic：入场要「快出现」，退场要「快消失」，
    // 两者都不该在中段拖泥带水。
    _curve = animation == null
        ? null
        : CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    final child = widget.child;
    if (curve == null) return child;

    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: _scaleFrom, end: 1).animate(curve),
        alignment: widget.alignment,
        child: child,
      ),
    );
  }
}

/// 气泡的透明遮罩。
///
/// 只做一件事：把「点外部」与「尝试拖动」翻译成关闭。刻意不压暗画面——
/// 变暗会让人误以为画布不可操作，而气泡旁边的内容恰恰应当保持可用观感。
class BubbleBarrier extends StatelessWidget {
  const BubbleBarrier({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        // 在工具栏把手上尝试拖动也会命中这里：先关闭气泡，再拖一次即可移动面板。
        onPanStart: (_) => onClose(),
      ),
    );
  }
}
