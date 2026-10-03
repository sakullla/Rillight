import 'package:flutter/material.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';

/// 电视外观三态。写入 [AppearanceScope] 中的 [AppearanceController],不另建偏好。
///
/// 选项键与连接页相同:`tv-appearance-system`、`tv-appearance-light`、
/// `tv-appearance-dark`。方向键在三项间移动,选中即调用 [AppearanceController.setStyle]。
class TvAppearancePicker extends StatelessWidget {
  const TvAppearancePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    final style = appearance?.style ?? AppearanceStyle.system;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsAppearance),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final value in AppearanceStyle.values) ...[
              TvAction(
                key: Key('tv-appearance-${value.name}'),
                selected: style == value,
                onPressed: appearance == null
                    ? null
                    : () => appearance.setStyle(value),
                child: Text(value.label(l10n)),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }
}
