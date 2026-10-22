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

  /// 按更新时间倒序加载工程。
  ///
  /// 默认不含回收站里的条目：已删除的工程不该出现在首页，但它们仍在索引里，
  /// 这样「恢复」不需要去扫描文件系统。
  Future<List<DrawingProject>> loadProjects({bool includeTrashed = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_projectsKey);
    if (raw == null || raw.isEmpty) return <DrawingProject>[];

    final list = jsonDecode(raw) as List<dynamic>;
    final projects = <DrawingProject>[];
    for (final entry in list) {
      try {
        projects.add(DrawingProject.fromJson(entry as Map<String, dynamic>));
      } catch (_) {
        // 单条记录损坏（字段缺失、时间格式错误等）时跳过。
        // 一条坏数据不应该让用户整个工程列表都打不开。
      }
    }
    final visible = includeTrashed
        ? projects
        : projects.where((project) => !project.isTrashed).toList();
    visible.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return visible;
  }

  /// 回收站内容，按删除时间倒序。
  Future<List<DrawingProject>> loadTrashedProjects() async {
    final all = await loadProjects(includeTrashed: true);
    final trashed =
        all.where((project) => project.isTrashed).toList(growable: false);
    trashed.sort((a, b) => b.deletedAt!.compareTo(a.deletedAt!));
    return trashed;
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

  /// 移入回收站（软删除）。
  ///
  /// 不删文件：删除是绘画应用里唯一不可接受的失败，而一份笔画的体积很小。
  /// 真正的清理发生在 [purgeProject]。
  Future<void> deleteProject(String id) async {
    final projects = await loadProjects(includeTrashed: true);
    final index = projects.indexWhere((project) => project.id == id);
    if (index == -1) return;
    if (projects[index].isTrashed) return;
    projects[index] = projects[index].copyWith(deletedAt: DateTime.now());
    await saveProjects(projects);
  }

  /// 从回收站恢复。
  Future<void> restoreProject(String id) async {
    final projects = await loadProjects(includeTrashed: true);
    final index = projects.indexWhere((project) => project.id == id);
    if (index == -1 || !projects[index].isTrashed) return;
    projects[index] = projects[index].copyWith(restore: true);
    await saveProjects(projects);
  }

  /// 彻底删除：只从索引移除，文件由调用方（`DocumentStore.deleteStrokes`）清理。
  Future<void> purgeProject(String id) async {
    final projects = await loadProjects(includeTrashed: true);
    final before = projects.length;
    projects.removeWhere((project) => project.id == id);
    if (projects.length == before) return;
    await saveProjects(projects);
  }
}
