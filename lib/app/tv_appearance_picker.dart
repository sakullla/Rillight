import 'package:flutter/material.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';

/// 电视外观三态。写入 [AppearanceScope] 中的 [AppearanceController],不另建偏好。
///
/// 选项键:`tv-appearance-system`、`tv-appearance-light`、`tv-appearance-dark`。
/// 方向键在三项间移动,选中即调用 [AppearanceController.setStyle]。
/// 标题由所在分区提供,这里只画一行胶囊选项。
class TvAppearancePicker extends StatelessWidget {
  const TvAppearancePicker({super.key});

  static const _icons = {
    AppearanceStyle.system: Icons.brightness_auto_rounded,
    AppearanceStyle.light: Icons.light_mode_rounded,
    AppearanceStyle.dark: Icons.dark_mode_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final style = appearance?.style ?? AppearanceStyle.system;
    return Wrap(
      spacing: 8 * s,
      runSpacing: 8 * s,
      children: [
        for (final value in AppearanceStyle.values)
          TvAction(
            key: Key('tv-appearance-${value.name}'),
            pill: true,
            selected: style == value,
            leading: Icon(style == value ? Icons.check_rounded : _icons[value]),
            onPressed: appearance == null
                ? null
                : () => appearance.setStyle(value),
            child: Text(value.label(l10n)),
          ),
      ],
    );
  }
}
