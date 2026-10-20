import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/reveal_selected.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 整数倍速写成 `1x`，小数保留原样。
String playerRateLabel(double rate) =>
    '${rate == rate.roundToDouble() ? rate.round() : rate}x';

String playerQualityLabel(AppLocalizations l10n, int bitrate) =>
    bitrate == kTranscodeBitrates.first || !kTranscodeBitrates.contains(bitrate)
    ? l10n.qualityAuto
    : l10n.qualityMbps(bitrate ~/ 1000000);

/// 互斥选项。格子固定 40 高，窄面板减少列数，避免勾和文字挤出格子。
class PlayerOption {
  const PlayerOption({
    required this.label,
    required this.selected,
    this.onPressed,
    this.key,
  });

  final Key? key;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;
}

class PlayerOptionGrid extends StatelessWidget {
  const PlayerOptionGrid({super.key, required this.options});

  final List<PlayerOption> options;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        const cellHeight = 40.0;
        var columns = constraints.maxWidth >= 336
            ? 4
            : constraints.maxWidth >= 248
            ? 3
            : 2;
        if (options.length > 1 &&
            options.length % columns == 1 &&
            columns > 2) {
          columns -= 1;
        }
        return GridView.builder(
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: options.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellHeight,
          ),
          itemBuilder: (context, index) {
            final option = options[index];
            return RevealSelected(
              selected: option.selected,
              child: PlayerRateCell(
                key: option.key,
                label: option.label,
                selected: option.selected,
                onPressed: option.onPressed,
              ),
            );
          },
        );
      },
    );
  }
}

/// 倍速选项。格子固定 40 高，不随面板剩余高度拉长。
class PlayerRateGrid extends StatelessWidget {
  const PlayerRateGrid({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });

  final double selected;
  final ValueChanged<double> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return PlayerOptionGrid(
      options: [
        for (final rate in kPlaybackRateLadder)
          PlayerOption(
            key: ValueKey('player-rate-$rate'),
            label: playerRateLabel(rate),
            selected: rate == selected,
            onPressed: enabled ? () => onSelected(rate) : null,
          ),
      ],
    );
  }
}

class PlayerRateCell extends StatelessWidget {
  const PlayerRateCell({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    // 播放器面板固定深色,保持原来的灰阶选中;浅色设置页里改用强调色:
    // 未选是浅灰平铺,选中是强调色浅底加描边,一眼分清。
    final light = scheme.brightness == Brightness.light;
    final foreground = light && selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final Color fill;
    final Color edge;
    if (light) {
      fill = selected ? scheme.primaryContainer : scheme.surfaceContainer;
      edge = selected ? scheme.primary : AppInk.transparent;
    } else {
      fill = selected ? scheme.surfaceBright : scheme.surfaceContainerHighest;
      edge = selected
          ? scheme.onSurface.withValues(alpha: .7)
          : scheme.outlineVariant;
    }
    return Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: edge, width: light && selected ? 1.5 : 1),
            color: fill,
          ),
          child: AppSurfaceAction(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(
                        AppIcons.check,
                        fill: AppIcons.filled,
                        size: 16,
                        color: foreground,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: AppUiTheme.of(context).textTheme.labelLarge
                          ?.copyWith(
                            color: foreground,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
