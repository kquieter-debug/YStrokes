import 'package:flutter_test/flutter_test.dart';

import 'package:ystrokes/src/models/export_destination.dart';

/// 导出目标的序列化与展示：偏好要能跨启动还原，坏数据要能安全回落。
void main() {
  test('默认位置编码为 null，便于清除偏好键', () {
    expect(ExportDestination.platformDefault.encode(), isNull);
    expect(ExportDestination.platformDefault.isCustom, isFalse);
    expect(ExportDestination.platformDefault.description, '默认位置');
  });

  test('文件系统目录可往返', () {
    final destination = ExportDestination.directory('/tmp/ystrokes-out');
    final restored = ExportDestination.decode(destination.encode());

    expect(restored, destination);
    expect(restored.isDirectory, isTrue);
    expect(restored.path, '/tmp/ystrokes-out');
    expect(restored.description, '/tmp/ystrokes-out');
    expect(restored.isCustom, isTrue);
  });

  test('SAF 树 URI 可往返，并保留展示名', () {
    final destination = ExportDestination.tree(
      uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload',
      label: '下载',
    );
    final restored = ExportDestination.decode(destination.encode());

    expect(restored, destination);
    expect(restored.isTree, isTrue);
    expect(restored.uri, startsWith('content://'));
    expect(restored.description, '下载');
  });

  test('偏好为空或损坏时回落到默认位置', () {
    expect(ExportDestination.decode(null), ExportDestination.platformDefault);
    expect(ExportDestination.decode(''), ExportDestination.platformDefault);
    expect(
      ExportDestination.decode('not-json'),
      ExportDestination.platformDefault,
    );
    // 结构对但缺字段：同样不能把导出弄挂。
    expect(
      ExportDestination.decode('{"kind":"directory"}'),
      ExportDestination.platformDefault,
    );
    expect(
      ExportDestination.decode('{"kind":"tree"}'),
      ExportDestination.platformDefault,
    );
    expect(
      ExportDestination.decode('{"kind":"unknown","path":"/tmp"}'),
      ExportDestination.platformDefault,
    );
  });

  test('不同目标不相等（偏好变更能被 ValueNotifier 识别）', () {
    expect(
      ExportDestination.directory('/a'),
      isNot(ExportDestination.directory('/b')),
    );
    expect(
      ExportDestination.tree(uri: 'content://a'),
      isNot(ExportDestination.directory('content://a')),
    );
  });
}
