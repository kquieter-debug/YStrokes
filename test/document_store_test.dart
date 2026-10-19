import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ystrokes/src/services/document_store.dart';

/// 仅覆盖文件层（字节读写 / 原子性 / 目录隔离）。
///
/// 编解码由 Rust 负责，其往返与容错已由 `cargo test` 覆盖；此处注入临时目录，
/// 从而无需 path_provider 插件与 Rust 动态库即可验证 I/O 语义。
void main() {
  late Directory temp;
  late DocumentStore store;
  late Directory projectDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ystrokes_store_test_');
    store = DocumentStore(rootDirectory: temp);
    projectDir = Directory('${temp.path}/projects/p1');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('写入后可原样读回', () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    await store.writeBytes('p1', bytes);

    expect(await store.readBytes('p1'), bytes);
    expect(await store.hasStrokes('p1'), isTrue);
  });

  test('文件不存在时返回 null 且不抛错', () async {
    expect(await store.readBytes('missing'), isNull);
    expect(await store.hasStrokes('missing'), isFalse);
  });

  test('重复写入覆盖旧内容，且不残留临时文件', () async {
    await store.writeBytes('p1', Uint8List.fromList(<int>[1, 2, 3]));
    await store.writeBytes('p1', Uint8List.fromList(<int>[9, 9]));

    expect(await store.readBytes('p1'), <int>[9, 9]);

    final entries = await projectDir.list().toList();
    expect(entries, hasLength(1), reason: '校验通过后应只剩目标文件');
    expect(entries.single.path, endsWith('strokes.bin'));
  });

  test('不同工程的文档互相隔离', () async {
    await store.writeBytes('p1', Uint8List.fromList(<int>[1]));
    await store.writeBytes('p2', Uint8List.fromList(<int>[2]));

    expect(await store.readBytes('p1'), <int>[1]);
    expect(await store.readBytes('p2'), <int>[2]);
  });

  test('deleteStrokes 移除工程目录', () async {
    await store.writeBytes('p1', Uint8List.fromList(<int>[1]));
    expect(await projectDir.exists(), isTrue);

    await store.deleteStrokes('p1');

    expect(await projectDir.exists(), isFalse);
    expect(await store.readBytes('p1'), isNull);
  });

  test('拒绝含路径分隔符或上跳的工程 id', () async {
    for (final badId in <String>['', '../evil', r'a\b', 'x/y']) {
      await expectLater(
        store.writeBytes(badId, Uint8List(0)),
        throwsArgumentError,
        reason: 'id "$badId" 不应被接受',
      );
    }
  });
}
