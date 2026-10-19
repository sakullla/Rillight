import 'dart:ui' show ImageFilter;

import 'package:rillight/app/ui/ui.dart';

/// 顶栏的近实底底色与下沿淡出。
///
/// 旧版在首页/详情用 0.55 的黑色渐变,白海报上的次要文字与图标达不到
/// 4.5:1 / 3:1。这里改为 [AppColorScheme.surface] 的近实底(surface)带,
/// 下方 [fadeHeight] 从同一底色渐隐到透明;沉浸感由模糊与淡出保留,
/// 对比不再取决于海报明暗。非沉浸页面也使用同一组件,避免两套顶栏底色。
class TopBarBackdrop extends StatelessWidget {
  const TopBarBackdrop({super.key, required this.height, this.blur = false});

  /// 顶栏实体带的高度;窗口有系统标题按钮时高于 56。
  final double height;

  /// 是否在实体带后模糊内容。仅沉浸顶栏需要;实心页面无需重复采样。
  final bool blur;

  /// 实体带下方的淡出高度。
  static const fadeHeight = 36.0;

  /// 深色在纯白海报上合成后仍保证 primary/error 文字达到 4.5:1。
  static const darkAlpha = 0.90;

  /// 浅色 surface 本身接近白色,0.96 保留一点画面透气。
  static const lightAlpha = 0.96;

  /// 顶栏底色在给定亮度下的不透明度。
  static double alphaFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkAlpha : lightAlpha;

  /// 顶栏实体带实际显示的颜色(已按亮度取 alpha)。
  static Color tintFor(AppColorScheme scheme, {bool highContrast = false}) =>
      scheme.surface.withValues(
        alpha: highContrast ? 1 : alphaFor(scheme.brightness),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final tint = tintFor(
      scheme,
      highContrast: MediaQuery.highContrastOf(context),
    );
    final band = ColoredBox(color: tint);
    return IgnorePointer(
      child: SizedBox(
        height: height + fadeHeight,
        child: Column(
          children: [
            SizedBox(
              height: height,
              child: blur
                  ? ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: AppGlass.barBlur,
                          sigmaY: AppGlass.barBlur,
                        ),
                        child: band,
                      ),
                    )
                  : band,
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [tint, tint.withValues(alpha: 0)],
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
