import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// Video shading belongs behind comments, while interactive chrome belongs
/// above them. Keeping these layers separate prevents controls fading in from
/// tinting white comment fills black.
class PlaybackControlScrims extends StatelessWidget {
  const PlaybackControlScrims({
    super.key,
    required this.visible,
    required this.topExtent,
    required this.showBottom,
  });

  final bool visible;
  final double topExtent;
  final bool showBottom;

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.durationOf(context),
        curve: AppMotion.standard,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topExtent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.transparent,
                      scrim.withValues(
                        alpha: AppScrim.of(context, AppScrim.playerBarSoft),
                      ),
                      scrim.withValues(
                        alpha: AppScrim.of(context, AppScrim.playerPanel),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (showBottom)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height:
                    AppSpacing.huge +
                    AppSpacing.xs +
                    AppSpacing.md +
                    48 +
                    48 * scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        scrim.withValues(
                          alpha: AppScrim.of(context, AppScrim.playerBar),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
