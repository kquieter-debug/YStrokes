import 'raster_mask.dart';
import 'raster_patch.dart';
import 'raster_surface.dart';

/// 一次像素选区变换的会话。
///
/// ## 生命周期
///
/// ```
/// lift()   → 拍快照 + 抠出选区内像素 + 清空源区域（图层此时已经「有洞」）
/// transform 改动 → 只改参数，不碰像素（预览走 GPU 合成）
/// commit() → 按参数重采样写回，返回被改到的瓦片
/// cancel() → 调用方把图层内容换回 [before]，像素完全复原
/// ```
///
/// ## 为什么提起是惰性的
///
/// 套索抬手只生成蒙版，**不动像素**。只有真正开始拖动时才提起：
/// 「圈一下又放开」是极常见的动作，不该在图层上留下一次内容改动，
/// 更不该产生一条撤销记录。
///
/// ## 为什么必须清空源区域
///
/// 不清空的话，移动一块内容之后原位置还留着一份——那不是「移动」而是
/// 「复制」。清空与提起是同一个动作的两面，因此放在 [lift] 里一次做完，
/// 调用方不需要记得两者要配对。
class RasterSelectionSession {
  RasterSelectionSession._({
    required this.layerId,
    required this.surface,
    required this.before,
    required this.mask,
    required this.patch,
  });

  /// 从图层提起 [mask] 覆盖的内容。
  ///
  /// [layerId] 只用于在预览时确认这张浮动内容属于哪一层——浮动内容必须画在
  /// 它所属图层的 `saveLayer` 之内，否则图层不透明度与混合模式对它不生效。
  ///
  /// 选区为空（或整块透明）时返回 null，此时**不会**改动 [surface]。
  static RasterSelectionSession? lift({
    required String layerId,
    required RasterSurface surface,
    required RasterMask mask,
  }) {
    if (mask.isEmpty) return null;

    // 快照必须在清空之前拍：它是撤销与「取消」的唯一退路。
    final before = surface.fork();
    final patch = RasterPatch.lift(surface, mask);
    if (patch == null) return null;

    RasterPatch.clearRegion(surface, mask);
    return RasterSelectionSession._(
      layerId: layerId,
      surface: surface,
      before: before,
      mask: mask,
      patch: patch,
    );
  }

  final String layerId;

  /// 图层当前的内容（提起后源区域已被清空）。
  final RasterSurface surface;

  /// 提起之前的快照。取消时换回它即可完全复原。
  final RasterSurface before;

  final RasterMask mask;
  final RasterPatch patch;

  /// 当前的摆放参数。拖动时由调用方直接改写。
  PatchTransform transform = PatchTransform.identity;

  /// 是否真的移动过。没动过的提交应当被当作「取消」处理。
  bool get isMoved => !transform.isIdentity;

  /// 按当前参数把内容写回图层，返回被改动的瓦片。
  ///
  /// 未移动时直接返回空集，调用方据此走还原分支——原地往返会在部分覆盖的
  /// 边界像素上损失一次 alpha（清空扣掉 k，合成又按 k 叠加，得到
  /// `a - a²k(1-k)`），虽然只有一像素宽的过渡带，但没有必要承受。
  Set<TileKey> commit() {
    if (!isMoved) return const <TileKey>{};
    return patch.compositeInto(surface, transform: transform);
  }

  /// 取消后应当装回图层的对象。
  RasterSurface get restoreTarget => before;
}
