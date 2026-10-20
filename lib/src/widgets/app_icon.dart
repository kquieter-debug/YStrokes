import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 图标资源路径集中管理，便于后续替换为自己的图标集。
abstract final class AppIcons {
  static const String logo = 'assets/icons/app_logo.svg';
  static const String projects = 'assets/icons/projects.svg';
  static const String settings = 'assets/icons/settings.svg';
  static const String about = 'assets/icons/about.svg';
  static const String brush = 'assets/icons/brush.svg';
  static const String eraser = 'assets/icons/eraser.svg';
}

/// 单色矢量图标。
///
/// 资源文件按单色绘制（纯黑），运行时用 [ColorFilter.mode] + [BlendMode.srcIn]
/// 整体着色，因此同一份 SVG 可以适配任意主题色。
///
/// 替换图标时只需覆盖对应的 `.svg` 文件，无需改动代码。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.asset, {
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  final String asset;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tint = color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      semanticsLabel: semanticLabel,
    );
  }
}
