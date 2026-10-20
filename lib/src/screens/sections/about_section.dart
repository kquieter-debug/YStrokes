import 'package:flutter/material.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/section_card.dart';

/// 关于栏目。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  /// 版本号与 pubspec.yaml 的 `version` 保持一致；发布流程变动时需同步修改。
  static const String _version = '1.0.0';

  static const String _repository = 'https://github.com/kquieter-debug/YStrokes';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text('关于', style: theme.textTheme.titleLarge),
        const SizedBox(height: 20),
        Row(
          children: [
            AppIcon(
              AppIcons.logo,
              size: 44,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('YStrokes', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  '版本 $_version',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        SectionCard(
          title: '定位',
          child: Text(
            '面向 Android 的矢量笔画绘画应用。笔画以归一化坐标存储，'
            '与分辨率解耦；几何与文档编解码由 Rust 承担。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
        ),
        SectionCard(
          title: '技术栈',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const <Widget>[
              _TechChip('Flutter'),
              _TechChip('Dart'),
              _TechChip('Rust'),
              _TechChip('flutter_rust_bridge'),
            ],
          ),
        ),
        SectionCard(
          title: '开源协议',
          child: Text(
            'WTFPL v2 —— 可自由复制、修改与分发。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
        ),
        SectionCard(
          title: '源代码',
          child: SelectableText(
            _repository,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

class _TechChip extends StatelessWidget {
  const _TechChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
