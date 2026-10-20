import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/document_store.dart';
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
  const HomeScreen({super.key, this.documentStore});

  /// 笔画存储实现。生产环境留空；测试可注入以临时目录为根的实例。
  final DocumentStore? documentStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProjectStore _store = ProjectStore();
  late final DocumentStore _documentStore =
      widget.documentStore ?? DocumentStore();
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
      MaterialPageRoute<void>(builder: (_) => CanvasScreen(project: project)),
    );
    await _reload(); // 返回后刷新更新时间
  }

  /// 长按工程：弹出操作菜单。
  Future<void> _showProjectActions(DrawingProject project) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text('删除', style: TextStyle(color: scheme.error)),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (action != 'delete' || !mounted) return;
    await _confirmDelete(project);
  }

  /// 删除前的二次确认。删除不可撤销，因此必须显式确认。
  Future<void> _confirmDelete(DrawingProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('删除工程'),
          content: const Text('确认删除吗？该操作不可回退！'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    // 先删索引、再删文件。若顺序相反且索引删除失败，用户会看到「工程还在但内容
    // 已经空了」，那是更坏的结果；反之文件清理失败只会留下一个无用目录。
    await _store.deleteProject(project.id);
    try {
      await _documentStore.deleteStrokes(project.id);
    } catch (_) {
      // 文件清理是尽力而为，不应阻塞删除流程。
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已删除「${project.name}」')));
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
          onLongPress: () => _showProjectActions(project),
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

/// 导航栏条目：图标、文案与目标栏目。
class _RailEntry {
  const _RailEntry(this.section, this.icon, this.label);

  final HomeSection section;
  final String icon;
  final String label;
}

/// 右侧竖向导航栏。
///
/// 条目由 [_entries] 单一来源驱动：增删栏目只需改这一个列表，
/// 布局与选中态会自动跟随，不需要改动栏体结构。
class _SideRail extends StatelessWidget {
  const _SideRail({required this.section, required this.onSelect});

  final HomeSection section;
  final ValueChanged<HomeSection> onSelect;

  static const List<_RailEntry> _entries = <_RailEntry>[
    _RailEntry(HomeSection.projects, AppIcons.projects, '工程'),
    _RailEntry(HomeSection.settings, AppIcons.settings, '设置'),
    _RailEntry(HomeSection.about, AppIcons.about, '关于'),
  ];

  static const double _width = 76;

  /// 条目之间的统一间距，保证图标在竖向上等距排布。
  static const double _itemGap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _width,
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
          const SizedBox(height: 12),
          for (var i = 0; i < _entries.length; i++) ...[
            if (i > 0) const SizedBox(height: _itemGap),
            _RailButton(
              entry: _entries[i],
              selected: section == _entries[i].section,
              onTap: () => onSelect(_entries[i].section),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个导航条目：圆形选中底色 + 居中图标 + 下方文案。
///
/// 全部条目共用同一宽度与同一圆心横坐标，因此天然对齐；圆形底色固定 44dp，
/// 既满足触控尺寸，也比原先贴边的矩形底色更容易识别。
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _RailEntry entry;
  final bool selected;
  final VoidCallback onTap;

  static const double _highlight = 44;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;

    return InkResponse(
      onTap: onTap,
      radius: _highlight * 0.6,
      child: SizedBox(
        width: _SideRail._width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: _highlight,
              height: _highlight,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.primaryContainer.withValues(alpha: 0.85)
                    : Colors.transparent,
              ),
              child: Center(
                child: AppIcon(
                  entry.icon,
                  size: 22,
                  color: foreground,
                  semanticLabel: entry.label,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              entry.label,
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
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
