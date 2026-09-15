import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// 海报/缩略图底部的实色渐变简介带。
///
/// 铺在图上,不走玻璃。底带用 [ColorScheme.scrim] + [AppScrim],保证白字
/// 在任意海报上对比度够。常驻用于详情海报与分集缩略图;目录墙悬停揭示
/// 仍走卡片内 overlay,避免小海报始终盖字。
class PosterOverviewBand extends StatelessWidget {
  const PosterOverviewBand({
    super.key,
    required this.text,
    this.maxLines = 3,
    this.textKey,
    this.style,
  });

  final String text;
  final int maxLines;
  final Key? textKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final body = text.trim();
    if (body.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final scrim = theme.colorScheme.scrim;
    Color at(double alpha) =>
        scrim.withValues(alpha: AppScrim.resolve(alpha, reduce: reduce));
    final textStyle =
        style ??
        theme.textTheme.bodySmall?.copyWith(
          color: Colors.white.withValues(alpha: 0.94),
          height: 1.35,
        );
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [at(0), at(AppScrim.bottomMid), at(AppScrim.playerPanel)],
              stops: const [0, 0.42, 1],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Text(
              body,
              key: textKey,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
        ),
      ),
    );
  }
}
