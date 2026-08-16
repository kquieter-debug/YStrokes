/// 一个绘画工程（画板）的元数据。
class DrawingProject {
  const DrawingProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 创建一个新工程；[id] 为空时自动生成。
  factory DrawingProject.create(String name, {String? id}) {
    final now = DateTime.now();
    return DrawingProject(
      id: id ?? now.microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DrawingProject.fromJson(Map<String, dynamic> json) => DrawingProject(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  DrawingProject copyWith({String? name, DateTime? updatedAt}) =>
      DrawingProject(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
