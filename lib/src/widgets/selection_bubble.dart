import 'package:flutter/material.dart';

import 'bubble_surface.dart';

/// 选区工具的气泡。
///
/// 与画笔气泡共用同一套外壳规则（锚在工具栏旁、点外部关闭、无确认按钮），
/// 但内容不是「笔宽/颜色」——套索没有笔触参数，它需要的是**对当前选区的动作**。
///
/// 这里刻意不做「变换参数」滑杆：变换直接在画布上用手柄拖，数值输入反而是
/// 第二个真相来源，容易和手势结果对不上。
class SelectionBubble extends StatelessWidget {
  const SelectionBubble({
    super.key,
    required this.anchor,
    required this.selectedCount,
    required this.hasSession,
    required this.onDelete,
    required this.onClear,
    required this.onClose,
    this.animation,
  });

  /// 工具栏面板的全局矩形。
  final Rect anchor;

  /// 当前选区命中的笔画数；0 表示没有选区。
  final int selectedCount;

  /// 是否存在可提交的变换（决定提示文案）。
  final bool hasSession;

  final VoidCallback onDelete;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final Animation<double>? animation;

  static const double _gap = 12;
  static const double _maxWidth = 300;
  static const double _minWidth = 220;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;
    final inset = media.padding;

    final spaceRight = screen.width - anchor.right - _gap - inset.right;
    final spaceLeft = anchor.left - _gap - inset.left;
    final onRight = spaceRight >= spaceLeft;
    final width = (onRight ? spaceRight : spaceLeft).clamp(_minWidth, _maxWidth);
    final left = onRight ? anchor.right + _gap : anchor.left - _gap - width;
    final top = anchor.top.clamp(
      inset.top + _gap,
      (screen.height - inset.bottom - _gap - 260).clamp(
        inset.top + _gap,
        double.infinity,
      ),
    );

    return Stack(
      children: [
        BubbleBarrier(key: const Key('selection-barrier'), onClose: onClose),
        Positioned(
          key: const Key('selection-bubble'),
          left: left.clamp(inset.left + _gap, screen.width),
          top: top,
          width: width,
          child: BubbleSurface(
            animation: animation,
            alignment: onRight ? Alignment.centerLeft : Alignment.centerRight,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.gesture,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text('选区', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text(
                          selectedCount == 0 ? '空' : '$selectedCount 笔',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      selectedCount == 0
                          ? '在画面上拖出一个闭合区域，圈住要变换的笔画。'
                          : hasSession
                              ? '拖动框内移动，拖角等比缩放，拖顶部圆点旋转。\n确认后才会写入，可用撤销回退。'
                              : '选区已就绪，拖动即可变换。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        TextButton.icon(
                          key: const Key('selection-delete'),
                          onPressed: selectedCount == 0 ? null : onDelete,
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除选中'),
                        ),
                        const Spacer(),
                        TextButton(
                          key: const Key('selection-clear'),
                          onPressed: selectedCount == 0 && !hasSession
                              ? null
                              : onClear,
                          child: const Text('取消选区'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
