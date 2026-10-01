import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_controller.dart';

class PlaybackSkipSettings extends StatelessWidget {
  const PlaybackSkipSettings({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final scheme = Theme.of(context).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            key: const Key('player-skip-intro-enabled'),
            title: Text(
              l10n.settingsSkipIntro,
              style: TextStyle(color: scheme.onSurface),
            ),
            subtitle: compact ? null : Text(l10n.settingsSkipIntroHint),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            thumbIcon: const WidgetStateProperty.fromMap({
              WidgetState.selected: Icon(Icons.check_rounded, size: 16),
            }),
            value: controller.skipIntroEnabled,
            onChanged: (value) => unawaited(
              controller.setSkipEnabled(PlayerSkipKind.intro, value),
            ),
          ),
          SwitchListTile(
            key: const Key('player-skip-outro-enabled'),
            title: Text(
              l10n.settingsSkipOutro,
              style: TextStyle(color: scheme.onSurface),
            ),
            subtitle: compact ? null : Text(l10n.settingsSkipOutroHint),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            thumbIcon: const WidgetStateProperty.fromMap({
              WidgetState.selected: Icon(Icons.check_rounded, size: 16),
            }),
            value: controller.skipOutroEnabled,
            onChanged: (value) => unawaited(
              controller.setSkipEnabled(PlayerSkipKind.outro, value),
            ),
          ),
        ],
      );
    },
  );
}
