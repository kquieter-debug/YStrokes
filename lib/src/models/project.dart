import 'document_spec.dart';

/// 一个绘画工程（画板）的元数据。
class DrawingProject {
  const DrawingProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.document,
    this.deletedAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 移入回收站的时刻；为空表示工程仍在列表中。
  ///
  /// 「删除」只打这个标记、不动文件：作品丢失是绘画应用里最不可接受的失败，
  /// 而一份笔画的体积远小于一张照片，留着比删掉更划算。彻底删除要用户再点一次。
  final DateTime? deletedAt;

  bool get isTrashed => deletedAt != null;

  /// 文档规格（像素尺寸、分辨率、底色）。
  ///
  /// 由创建时用户选定的参数决定，构成画布的固有形状与导出尺寸；
  /// 之后不随屏幕或设备变化。
  final DocumentSpec document;

  /// 文档宽高比，渲染时用于容纳画布。
  double get aspectRatio => document.aspectRatio;

  /// 创建一个新工程；[id] 为空时自动生成。
  ///
  /// 自动 id 由「微秒时间戳 + 进程内序号」组成：只用时间戳时，连续创建多个工程
  /// 有可能落在同一微秒上而得到相同 id，删除其中一个就会连带删掉另一个。
  factory DrawingProject.create(
    String name, {
    String? id,
    required DocumentSpec document,
  }) {
    final now = DateTime.now();
    return DrawingProject(
      id: id ?? '${now.microsecondsSinceEpoch}-${_sequence++}',
      name: name,
      createdAt: now,
      updatedAt: now,
      document: document,
    );
  }

  static int _sequence = 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'document': document.toJson(),
        if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
      };

  /// 从持久化 JSON 还原。
  ///
  /// 缺少 `document` 视为坏数据并抛出 [FormatException]：画布规格是工程的
  /// 固有属性，没有它就无法渲染。调用方（`ProjectStore`）会跳过这类条目，
  /// 而不是让整个工程列表打不开。
  factory DrawingProject.fromJson(Map<String, dynamic> json) {
    final rawDocument = json['document'];
    if (rawDocument is! Map<String, dynamic>) {
      throw const FormatException('工程缺少画布规格（document）');
    }
    return DrawingProject(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      document: DocumentSpec.fromJson(rawDocument),
      deletedAt: json['deletedAt'] is String
          ? DateTime.tryParse(json['deletedAt'] as String)
          : null,
    );
  }

  DrawingProject copyWith({
    String? name,
    DateTime? updatedAt,
    DocumentSpec? document,
    DateTime? deletedAt,
    bool restore = false,
  }) =>
      DrawingProject(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        document: document ?? this.document,
        // `restore: true` 才能把标记清空——`deletedAt ?? this.deletedAt` 无法表达
        // 「显式置 null」，这是 copyWith 处理可空字段的经典陷阱。
        deletedAt: restore ? null : (deletedAt ?? this.deletedAt),
      );
}
