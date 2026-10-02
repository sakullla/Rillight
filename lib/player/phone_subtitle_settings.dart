import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_settings.dart';

/// Shared preference editor. The playback host decides track capability.
class PhoneSubtitleSettingsControls extends StatelessWidget {
  const PhoneSubtitleSettingsControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.error,
  });
  final PhoneSubtitleSettings value;
  final ValueChanged<PhoneSubtitleSettings> onChanged;
  final String? error;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.phoneSubtitleSize,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final size in PhoneSubtitleSize.values)
              ChoiceChip(
                key: ValueKey('phone-subtitle-${size.name}'),
                label: Text(switch (size) {
                  PhoneSubtitleSize.small => l.phoneSubtitleSmall,
                  PhoneSubtitleSize.standard => l.phoneSubtitleStandard,
                  PhoneSubtitleSize.large => l.phoneSubtitleLarge,
                  PhoneSubtitleSize.extraLarge => l.phoneSubtitleExtraLarge,
                }),
                selected: value.size == size,
                onSelected: (_) => onChanged(
                  PhoneSubtitleSettings(
                    size: size,
                    originalAss: value.originalAss,
                  ),
                ),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          key: const Key('phone-subtitle-original'),
          title: Text(l.phoneSubtitleOriginal),
          subtitle: Text(l.phoneSubtitleOriginalHint),
          value: value.originalAss,
          onChanged: (original) => onChanged(
            PhoneSubtitleSettings(size: value.size, originalAss: original),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('phone-subtitle-reset'),
            icon: const Icon(Icons.restore),
            onPressed: () => onChanged(const PhoneSubtitleSettings()),
            label: Text(l.settingsRestoreDefaults),
          ),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
