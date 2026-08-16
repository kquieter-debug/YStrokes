import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/project_store.dart';
import '../widgets/project_tile.dart';
import 'canvas_screen.dart';

/// 主界面：文件管理区，负责工程列表预览与创建新工程。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProjectStore _store = ProjectStore();
  List<DrawingProject> _projects = const [];
  bool _loading = true;

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
    final name = await _promptProjectName();
    if (name == null || name.trim().isEmpty) return;
    final project = await _store.createProject(name.trim());
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

  Future<String?> _promptProjectName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建工程'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '工程名称',
            hintText: '例如：我的第一幅画',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('YStrokes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createProject,
        icon: const Icon(Icons.add),
        label: const Text('新建工程'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects.isEmpty) {
      return const _EmptyState();
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
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
