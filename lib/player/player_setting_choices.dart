import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/player_controller.dart';

/// 整数倍速写成 `1x`，小数保留原样。
String playerRateLabel(double rate) =>
    '${rate == rate.roundToDouble() ? rate.round() : rate}x';

String playerQualityLabel(AppLocalizations l10n, int bitrate) =>
    bitrate == kTranscodeBitrates.first || !kTranscodeBitrates.contains(bitrate)
    ? l10n.qualityAuto
    : l10n.qualityMbps(bitrate ~/ 1000000);

/// 倍速胶囊。选中只加勾和细边，保持和未选中一样的高度。
ChipThemeData playerChoiceChipTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final label = theme.textTheme.labelLarge;
  return ChipThemeData(
    backgroundColor: scheme.surfaceContainerHighest,
    selectedColor: scheme.surfaceBright,
    disabledColor: scheme.surfaceContainerHighest.withValues(alpha: .4),
    checkmarkColor: scheme.onSurface,
    labelStyle: label?.copyWith(color: scheme.onSurface),
    secondaryLabelStyle: label?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w700,
    ),
    side: BorderSide(color: scheme.outline.withValues(alpha: .55)),
    shape: const StadiumBorder(),
    padding: const EdgeInsets.symmetric(horizontal: 2),
    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
    showCheckmark: true,
  );
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
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        const cellHeight = 40.0;
        final columns = constraints.maxWidth >= 280 ? 4 : 2;
        final grid = GridView.builder(
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: kPlaybackRateLadder.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellHeight,
          ),
          itemBuilder: (context, index) {
            final rate = kPlaybackRateLadder[index];
            return PlayerRateCell(
              key: ValueKey('player-rate-$rate'),
              label: playerRateLabel(rate),
              selected: rate == selected,
              onPressed: enabled ? () => onSelected(rate) : null,
            );
          },
        );
        return grid;
      },
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
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onSurface;
    return Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        child: Material(
          color: selected
              ? scheme.surfaceBright
              : scheme.surfaceContainerHighest,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 16, color: foreground),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
