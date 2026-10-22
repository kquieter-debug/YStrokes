import 'dart:ui' show Offset, Rect;

import '../models/stroke.dart';
import 'transform_geometry.dart';

/// 单指拖动的语义。
enum TransformDragMode {
  /// 没有拖动。
  none,

  /// 正在画套索。
  draw,

  /// 移动选区。
  move,

  /// 拖动角柄等比缩放。
  scale,

  /// 拖动旋转柄。
  rotate,
}

/// 一次选区（或整层）变换的会话。
///
/// 关键设计：**变换始终以「原始快照 + 累计参数」重新计算**，绝不在上一帧的结果上
/// 继续乘。原因有二——逐帧累乘会让浮点误差可见（长按旋转几下就能看出抖动），
/// 而且撤销需要的正是「变换前」的那份快照。
///
/// 几何上，[pivot] 是**选区原始包围盒的中心**；[transform.offset] 恰好是它移动后
/// 的位置。因此绕「当前中心」旋转与缩放只是在乘 `rotation` / `scale`，
/// 不需要再重算锚点（见 [StrokeTransform]）。
class TransformSession {
  TransformSession({
    required this.layerId,
    required this.before,
    required this.selectedIds,
    required this.layerWide,
  }) : pivot = _centerOf(before, selectedIds);

  /// 目标图层。
  final String layerId;

  /// 变换前的完整笔画列表（该层）。
  final List<Stroke> before;

  /// 参与变换的笔画 id。
  final Set<int> selectedIds;

  /// 是否为「整层变换」——决定撤销提示与手柄是否常显。
  final bool layerWide;

  /// 选区原始包围盒中心（归一化）。
  final Offset pivot;

  /// 累计变换参数。
  StrokeTransform transform = StrokeTransform.identity;

  /// 是否还没被拖动过（用于「未改动就取消」的短路）。
  bool get isPristine => transform.isIdentity;

  /// 归一化坐标下的当前中心。
  Offset get currentCenter => pivot + transform.offset;

  /// 按当前参数生成的笔画列表。
  List<Stroke> strokes() => transformSelection(
        before,
        selectedIds,
        transform,
        pivot,
      );

  /// 已选内容当前的包围盒（归一化）。
  ///
  /// 每次调用都要重算——变换参数在拖动手势里每帧都在变；缓存反而要额外维护
  /// 「何时失效」，而这里一次只处理几十到几百笔，重算的开销远小于维护缓存的复杂度。
  Rect get bounds {
    final selected = strokes().where((s) => selectedIds.contains(s.id));
    return boundsOfStrokes(selected);
  }

  static Offset _centerOf(List<Stroke> strokes, Set<int> ids) {
    final rect = boundsOfStrokes(strokes.where((s) => ids.contains(s.id)));
    if (rect.isEmpty) return const Offset(0.5, 0.5);
    return rect.center;
  }
}
