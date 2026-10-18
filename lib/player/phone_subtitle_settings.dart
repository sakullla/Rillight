import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// Shared preference editor. The playback host decides track capability.
class PhoneSubtitleSettingsControls extends StatelessWidget {
  const PhoneSubtitleSettingsControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.error,
    this.showHeading = true,
  });
  final PhoneSubtitleSettings value;
  final ValueChanged<PhoneSubtitleSettings> onChanged;
  final String? error;

  /// Player menus already title the section. Settings keeps the heading.
  final bool showHeading;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeading) ...[
          Text(
            l.phoneSubtitleSize,
            style: AppUiTheme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        PlayerOptionGrid(
          options: [
            for (final size in PhoneSubtitleSize.values)
              PlayerOption(
                key: ValueKey('phone-subtitle-${size.name}'),
                label: switch (size) {
                  PhoneSubtitleSize.small => l.phoneSubtitleSmall,
                  PhoneSubtitleSize.standard => l.phoneSubtitleStandard,
                  PhoneSubtitleSize.large => l.phoneSubtitleLarge,
                  PhoneSubtitleSize.extraLarge => l.phoneSubtitleExtraLarge,
                },
                selected: !value.originalAss && value.size == size,
                onPressed: () => onChanged(
                  PhoneSubtitleSettings(size: size, originalAss: false),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        AppSwitchTile(
          key: const Key('phone-subtitle-original'),
          title: Text(l.phoneSubtitleOriginal),
          subtitle: Text(l.phoneSubtitleOriginalHint),
          value: value.originalAss,
          onChanged: (original) => onChanged(
            PhoneSubtitleSettings(size: value.size, originalAss: original),
          ),
        ),
        if (value.size != PhoneSubtitleSize.standard || value.originalAss)
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton.icon(
              key: const Key('phone-subtitle-reset'),
              variant: AppButtonVariant.tinted,
              style: const AppButtonStyle(minimumSize: Size(0, 44)),
              icon: const Icon(AppIcons.replay, fill: AppIcons.filled),
              onPressed: () => onChanged(const PhoneSubtitleSettings()),
              label: Text(l.settingsRestoreDefaults),
            ),
          ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: AppUiTheme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
