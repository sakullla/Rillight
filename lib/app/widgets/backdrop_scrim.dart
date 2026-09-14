import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// 海报/剧照之上的三段实色渐变遮罩:顶带、左侧文字带、底带。
///
/// 不含 [BackdropFilter],可以铺在整幅 backdrop 上。[backdrop] 为空或
/// 图片加载失败时,遮罩仍绘制在主题页面底色之上,保证前景文字可读。
/// 系统要求减少动态效果时,各段非透明 alpha 抬到 ≥ [AppScrim.reduced]。
///
/// 整体 [IgnorePointer]:底图与遮罩都不拦截点击,前景控件叠在其上或其下均可。
class BackdropScrim extends StatelessWidget {
  const BackdropScrim({
    super.key,
    this.backdrop,
    this.topBandHeight = AppScrim.topBandHeight,
    this.textBandWidthFactor = AppScrim.textBandWidthFactor,
  }) : assert(topBandHeight >= 0),
       assert(textBandWidthFactor > 0 && textBandWidthFactor <= 1);

  /// 铺满整幅的底图(通常为 `MediaImage(preferBackdrop: true)`)。
  final Widget? backdrop;

  /// 顶带高度;有窗口铬时传入顶栏实际高度 + 溶入高度。
  final double topBandHeight;

  /// 左侧文字带占宽比例。
  final double textBandWidthFactor;

  static const Key topBandKey = Key('backdrop-scrim-top');
  static const Key textBandKey = Key('backdrop-scrim-text');
  static const Key bottomBandKey = Key('backdrop-scrim-bottom');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final scrim = theme.colorScheme.scrim;
    final pageBg = theme.scaffoldBackgroundColor;

    Color scrimAt(double alpha) =>
        scrim.withValues(alpha: AppScrim.resolve(alpha, reduce: reduce));
    Color pageBgAt(double alpha) =>
        pageBg.withValues(alpha: AppScrim.resolve(alpha, reduce: reduce));

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: pageBg),
          ?backdrop,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: topBandHeight,
            child: _Band(
              key: topBandKey,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scrimAt(AppScrim.top), scrimAt(0)],
              ),
            ),
          ),
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: textBandWidthFactor,
              child: _Band(
                key: textBandKey,
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: AppScrim.textStops,
                  colors: [
                    scrimAt(AppScrim.textStart),
                    scrimAt(AppScrim.textMid),
                    scrimAt(0),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: _Band(
              key: bottomBandKey,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: AppScrim.bottomStops,
                colors: [pageBgAt(0), pageBgAt(AppScrim.bottomMid), pageBg],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({super.key, required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: const SizedBox.expand(),
    );
  }
}
