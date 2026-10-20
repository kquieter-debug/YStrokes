import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ystrokes/src/models/document_spec.dart';
import 'package:ystrokes/src/services/project_store.dart';

/// 工程索引的读写与删除。笔画文件由 DocumentStore 负责，不在本组用例范围。
void main() {
  const spec = DocumentSpec(widthPx: 1080, heightPx: 1920, dpi: 72);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('新建工程会保存画布规格', () async {
    final store = ProjectStore();
    final project = await store.createProject('速写', spec);

    final loaded = await store.loadProjects();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, project.id);
    expect(loaded.single.document.widthPx, 1080);
    expect(loaded.single.document.heightPx, 1920);
    expect(loaded.single.document.dpi, 72);
  });

  test('删除只影响目标工程', () async {
    final store = ProjectStore();
    await store.createProject('A', spec);
    final b = await store.createProject('B', spec);

    await store.deleteProject(b.id);

    final remaining = await store.loadProjects();
    expect(remaining.map((p) => p.name), <String>['A']);
  });

  test('删除不存在的 id 不报错也不改写', () async {
    final store = ProjectStore();
    await store.createProject('A', spec);

    await store.deleteProject('missing-id');

    expect(await store.loadProjects(), hasLength(1));
  });

  test('历史数据缺少 document 时按比例还原', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'projects':
          '[{"id":"p1","name":"旧工程","createdAt":"2026-01-01T00:00:00.000",'
              '"updatedAt":"2026-01-01T00:00:00.000","aspectRatio":0.75}]',
    });

    final loaded = await ProjectStore().loadProjects();
    expect(loaded, hasLength(1));
    expect(loaded.single.document.aspectRatio, closeTo(0.75, 1e-3));
    expect(loaded.single.document.dpi, 72);
  });
}
