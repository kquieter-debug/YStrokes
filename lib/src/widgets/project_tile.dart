import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/project.dart';

/// 工程预览卡片。
class ProjectTile extends StatelessWidget {
  const ProjectTile({
    super.key,
    required this.project,
    required this.onTap,
    this.onLongPress,
    this.thumbnail,
  });

  final DrawingProject project;
  final VoidCallback onTap;

  /// 长按回调：用于弹出工程操作（重命名 / 删除）。
  final VoidCallback? onLongPress;

  /// 工程缩略图（PNG 字节）；为空时显示占位图标。
  final Uint8List? thumbnail;

  String get _updatedLabel {
    final now = DateTime.now();
    final diff = now.difference(project.updatedAt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final d = project.updatedAt;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 缩略图：进入画板保存后会生成；未及时生成时回落为占位图标。
            Expanded(
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: thumbnail == null
                    ? Icon(
                        Icons.image_outlined,
                        size: 48,
                        color: theme.colorScheme.outline,
                      )
                    : Image.memory(
                        thumbnail!,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${project.document.widthPx} × ${project.document.heightPx} px'
                    ' · ${project.document.dpi.toStringAsFixed(0)} ppi',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _updatedLabel,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
