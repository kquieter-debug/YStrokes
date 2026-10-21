import 'dart:ui' show BlendMode;

import '../rust/api/document.dart' show LayerBlendMode;

// 让调用方只 import 本文件即可同时获得枚举与扩展。
export '../rust/api/document.dart' show LayerBlendMode;

/// 混合模式的展示名与对应的 Skia 合成方式。
///
/// 名称沿用 Photoshop 中文版叫法，便于用户对照迁移；映射目标是 Flutter/Skia 的
/// [BlendMode]，其 multiply / screen / overlay 等公式与 PS 一致。
extension LayerBlendModeX on LayerBlendMode {
  String get label => switch (this) {
        LayerBlendMode.normal => '正常',
        LayerBlendMode.multiply => '正片叠底',
        LayerBlendMode.screen => '滤色',
        LayerBlendMode.overlay => '叠加',
        LayerBlendMode.darken => '变暗',
        LayerBlendMode.lighten => '变亮',
        LayerBlendMode.colorDodge => '颜色减淡',
        LayerBlendMode.colorBurn => '颜色加深',
        LayerBlendMode.softLight => '柔光',
        LayerBlendMode.hardLight => '强光',
        LayerBlendMode.difference => '差值',
        LayerBlendMode.exclusion => '排除',
      };

  BlendMode get blendMode => switch (this) {
        LayerBlendMode.normal => BlendMode.srcOver,
        LayerBlendMode.multiply => BlendMode.multiply,
        LayerBlendMode.screen => BlendMode.screen,
        LayerBlendMode.overlay => BlendMode.overlay,
        LayerBlendMode.darken => BlendMode.darken,
        LayerBlendMode.lighten => BlendMode.lighten,
        LayerBlendMode.colorDodge => BlendMode.colorDodge,
        LayerBlendMode.colorBurn => BlendMode.colorBurn,
        LayerBlendMode.softLight => BlendMode.softLight,
        LayerBlendMode.hardLight => BlendMode.hardLight,
        LayerBlendMode.difference => BlendMode.difference,
        LayerBlendMode.exclusion => BlendMode.exclusion,
      };

  /// 是否为默认混合方式（合成时可跳过独立成层）。
  bool get isNormal => this == LayerBlendMode.normal;
}

/// 面板中的展示顺序：按 Photoshop 的常用顺序排列。
const List<LayerBlendMode> kLayerBlendModes = <LayerBlendMode>[
  LayerBlendMode.normal,
  LayerBlendMode.multiply,
  LayerBlendMode.screen,
  LayerBlendMode.overlay,
  LayerBlendMode.darken,
  LayerBlendMode.lighten,
  LayerBlendMode.colorDodge,
  LayerBlendMode.colorBurn,
  LayerBlendMode.softLight,
  LayerBlendMode.hardLight,
  LayerBlendMode.difference,
  LayerBlendMode.exclusion,
];
