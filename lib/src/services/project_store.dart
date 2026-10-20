import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/document_spec.dart';
import '../models/project.dart';

/// 工程元数据的持久化存储。
///
/// 当前阶段用 shared_preferences 保存 JSON 列表；后续接入 Rust 后端
/// 保存笔画数据时，可平滑替换为文件/数据库存储而不影响调用方。
class ProjectStore {
  static const String _projectsKey = 'projects';

  /// 按更新时间倒序加载全部工程。
  Future<List<DrawingProject>> loadProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_projectsKey);
    if (raw == null || raw.isEmpty) return <DrawingProject>[];

    final list = jsonDecode(raw) as List<dynamic>;
    final projects = list
        .map((e) => DrawingProject.fromJson(e as Map<String, dynamic>))
        .toList();
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  Future<void> saveProjects(List<DrawingProject> projects) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(projects.map((p) => p.toJson()).toList());
    await prefs.setString(_projectsKey, raw);
  }

  /// 按用户选定的画布规格新建工程并持久化。
  Future<DrawingProject> createProject(
    String name,
    DocumentSpec document,
  ) async {
    final projects = await loadProjects();
    final project = DrawingProject.create(name, document: document);
    projects.insert(0, project);
    await saveProjects(projects);
    return project;
  }

  /// 更新工程的最后修改时间（进入/保存画板时调用）。
  Future<void> touchProject(String id) async {
    final projects = await loadProjects();
    final index = projects.indexWhere((p) => p.id == id);
    if (index == -1) return;
    projects[index] = projects[index].copyWith(updatedAt: DateTime.now());
    await saveProjects(projects);
  }

  /// 重命名工程。
  Future<void> renameProject(String id, String name) async {
    final projects = await loadProjects();
    final index = projects.indexWhere((p) => p.id == id);
    if (index == -1) return;
    projects[index] = projects[index].copyWith(
      name: name,
      updatedAt: DateTime.now(),
    );
    await saveProjects(projects);
  }

  /// 从索引中移除工程。
  ///
  /// 只负责元数据；对应的笔画文件由 `DocumentStore.deleteStrokes` 清理——
  /// 两处存储分离，删除也需要分两步执行。
  Future<void> deleteProject(String id) async {
    final projects = await loadProjects();
    final before = projects.length;
    projects.removeWhere((p) => p.id == id);
    if (projects.length == before) return;
    await saveProjects(projects);
  }
}
