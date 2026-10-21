import 'package:rillight/app/ui/ui.dart';

/// 顶栏的近实底底色与下沿淡出。
///
/// 旧版在首页/详情用 0.55 的黑色渐变,白海报上的次要文字与图标达不到
/// 4.5:1 / 3:1。这里改为 [AppColorScheme.surface] 的近实底(surface)带,
/// 下方 [fadeHeight] 从同一底色缓动渐隐到透明,对比不再取决于海报明暗。
/// 非沉浸页面也使用同一组件,避免两套顶栏底色。
///
/// 实体带与淡出带是同一种材质、同一条缓动曲线:不做模糊——模糊只能
/// 停在实体带下沿,下面的淡出带又是清晰画面,两段材质一接就成了一道
/// 「玻璃纹」。实体带必须铺满整宽(无子节点的 [ColoredBox] 在 [Column]
/// 里会塌成 0 宽,只剩淡出带悬在透明顶栏下面)。
class TopBarBackdrop extends StatelessWidget {
  const TopBarBackdrop({super.key, required this.height, this.fade = true});

  /// 顶栏实体带的高度;窗口有系统标题按钮时高于 56。
  final double height;

  /// 是否在实体带下方画淡出。浅色首页顶栏是实心条,海报从下沿清晰开始,
  /// 不再铺一层白雾。
  final bool fade;

  /// 实体带下方的淡出高度。
  static const fadeHeight = 36.0;

  /// 深色在纯白海报上合成后仍保证 primary/error 文字达到 4.5:1。
  static const darkAlpha = 0.90;

  /// 浅色 surface 本身接近白色,0.96 保留一点画面透气。
  static const lightAlpha = 0.96;

  /// 淡出带的缓动停靠点(ease-out):起始处与实体带同色无台阶,
  /// 尾端平缓归零,不留可见的下沿线。
  static const fadeStops = [0.0, 0.3, 0.6, 1.0];
  static const fadeAlphas = [1.0, 0.62, 0.24, 0.0];

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
    return IgnorePointer(
      child: SizedBox(
        height: height + (fade ? fadeHeight : 0),
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: bandKey,
              height: height,
              child: ColoredBox(color: tint),
            ),
            if (fade)
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: fadeStops,
                      colors: [
                        for (final alpha in fadeAlphas)
                          tint.withValues(alpha: tint.a * alpha),
                      ],
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

  /// 实体带,供测试确认它铺满整宽。
  static const Key bandKey = Key('top-bar-backdrop-band');
}
