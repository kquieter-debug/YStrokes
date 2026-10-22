import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/app_theme.dart';
import '../../services/settings_service.dart';
import '../../widgets/section_card.dart';

/// 设置栏目。
///
/// 目前只包含两个真实生效的设置项：外观主题与欢迎页重置。
/// 不摆放尚未实现的开关，避免出现「点了没反应」的假控件。
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text('设置', style: theme.textTheme.titleLarge),
        const SizedBox(height: 20),
        SectionCard(
          title: '外观',
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: AppTheme.mode,
            builder: (context, mode, _) => SegmentedButton<ThemeMode>(
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment(value: ThemeMode.system, label: Text('系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: <ThemeMode>{mode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  AppTheme.set(selection.first),
            ),
          ),
        ),
        SectionCard(
          title: '图层',
          child: ValueListenableBuilder<bool>(
            valueListenable: AppSettings.liveLayerReorder,
            builder: (context, value, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('即时渲染图层上下关系变化'),
              subtitle: const Text('开启后拖动排序时画布实时重绘；关闭则松手后一次性更新'),
              value: value,
              onChanged: AppSettings.setLiveLayerReorder,
            ),
          ),
        ),
        SectionCard(
          title: '选区',
          child: ValueListenableBuilder<bool>(
            valueListenable: AppSettings.rasterMaskDim,
            builder: (context, value, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('压暗选区之外的画面'),
              subtitle: const Text(
                '像素图层上圈出选区后，选区外盖一层淡黑（类似快速蒙版）。'
                '选区边界的流动虚线始终显示，不受此开关影响',
              ),
              value: value,
              onChanged: AppSettings.setRasterMaskDim,
            ),
          ),
        ),
        SectionCard(
          title: '启动',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('重新显示欢迎页'),
            subtitle: const Text('下次启动时展示引导界面'),
            trailing: const Icon(Icons.restart_alt),
            onTap: () async {
              await SettingsService().resetWelcome();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(content: Text('已重置，下次启动将显示欢迎页')),
                );
            },
          ),
        ),
        SectionCard(
          title: '存储',
          child: Text(
            '笔画数据保存在应用文档目录下的 projects/ 中，'
            '工程索引保存在本地偏好设置里。卸载应用会一并删除，请勿将其作为唯一备份。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}
