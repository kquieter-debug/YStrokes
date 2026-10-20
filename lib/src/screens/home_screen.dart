import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/project_store.dart';
import '../widgets/app_icon.dart';
import '../widgets/project_tile.dart';
import 'canvas_screen.dart';
import 'new_document_screen.dart';
import 'sections/about_section.dart';
import 'sections/settings_section.dart';

/// 主界面栏目。右侧竖排导航与内容区一一对应。
enum HomeSection { projects, settings, about }

/// 主界面：左侧为当前栏目的内容，右侧为常驻导航栏。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProjectStore _store = ProjectStore();
  List<DrawingProject> _projects = const [];
  bool _loading = true;
  HomeSection _section = HomeSection.projects;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final projects = await _store.loadProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  Future<void> _createProject() async {
    // 先设定画布模板与规格，再建工程：参数是工程的固有属性，不能事后补。
    final result = await Navigator.of(context).push<NewDocumentResult>(
      MaterialPageRoute<NewDocumentResult>(
        builder: (_) => const NewDocumentScreen(),
      ),
    );
    if (result == null || !mounted) return;

    final project = await _store.createProject(result.name, result.document);
    if (!mounted) return;
    await _openProject(project);
  }

  Future<void> _openProject(DrawingProject project) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CanvasScreen(project: project),
      ),
    );
    await _reload(); // 返回后刷新更新时间
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _HomeHeader(),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildSection()),
                  _SideRail(
                    section: _section,
                    onSelect: (section) => setState(() => _section = section),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // 只有工程区需要新建入口，其余栏目不显示，避免语义错位。
      floatingActionButton: _section == HomeSection.projects
          ? FloatingActionButton.extended(
              onPressed: _createProject,
              icon: const Icon(Icons.add),
              label: const Text('新建工程'),
            )
          : null,
    );
  }

  Widget _buildSection() => switch (_section) {
        HomeSection.projects => _buildProjects(),
        HomeSection.settings => const SettingsSection(),
        HomeSection.about => const AboutSection(),
      };

  Widget _buildProjects() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects.isEmpty) {
      return const _EmptyState();
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: _projects.length,
      itemBuilder: (context, index) {
        final project = _projects[index];
        return ProjectTile(
          project: project,
          onTap: () => _openProject(project),
        );
      },
    );
  }
}

/// 主界面标题栏。
///
/// 标题右侧的应用图标目前是占位资源（`assets/icons/app_logo.svg`），
/// 后续替换该文件即可，无需改动代码。
class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          Text(
            'YStrokes',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 10),
          AppIcon(
            AppIcons.logo,
            size: 24,
            color: theme.colorScheme.primary,
            semanticLabel: '应用图标占位',
          ),
        ],
      ),
    );
  }
}

/// 右侧竖向导航栏。
class _SideRail extends StatelessWidget {
  const _SideRail({required this.section, required this.onSelect});

  final HomeSection section;
  final ValueChanged<HomeSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _RailButton(
            icon: AppIcons.projects,
            label: '工程',
            selected: section == HomeSection.projects,
            onTap: () => onSelect(HomeSection.projects),
          ),
          _RailButton(
            icon: AppIcons.settings,
            label: '设置',
            selected: section == HomeSection.settings,
            onTap: () => onSelect(HomeSection.settings),
          ),
          _RailButton(
            icon: AppIcons.about,
            label: '关于',
            selected: section == HomeSection.about,
            onTap: () => onSelect(HomeSection.about),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 22, color: foreground, semanticLabel: label),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, size: 72, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('还没有工程', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点击右下角「新建工程」开始创作',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
