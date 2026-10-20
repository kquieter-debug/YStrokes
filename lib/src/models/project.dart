/// 一个绘画工程（画板）的元数据。
class DrawingProject {
  const DrawingProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.aspectRatio,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 文档宽高比（`width / height`），决定画布的固有形状。
  ///
  /// 为 `null` 表示历史工程尚未记录：画板会在首次打开时采用当前视口比例并回写，
  /// 从而在「不改变现有观感」的前提下完成迁移。
  ///
  /// 一旦确定就不再随屏幕变化——这是画布独立于设备的前提。
  final double? aspectRatio;

  /// 创建一个新工程；[id] 为空时自动生成。
  factory DrawingProject.create(
    String name, {
    String? id,
    double? aspectRatio,
  }) {
    final now = DateTime.now();
    return DrawingProject(
      id: id ?? now.microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: now,
      updatedAt: now,
      aspectRatio: aspectRatio,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      };

  factory DrawingProject.fromJson(Map<String, dynamic> json) => DrawingProject(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        // 历史数据没有该字段：保持 null，由画板在首次打开时补齐。
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble(),
      );

  DrawingProject copyWith({
    String? name,
    DateTime? updatedAt,
    double? aspectRatio,
  }) =>
      DrawingProject(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        aspectRatio: aspectRatio ?? this.aspectRatio,
      );
}
