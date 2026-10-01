import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_controller.dart';

class PlaybackSkipSettings extends StatelessWidget {
  const PlaybackSkipSettings({super.key, required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile.adaptive(
            key: const Key('player-skip-intro-enabled'),
            title: Text(l10n.settingsSkipIntro),
            subtitle: Text(l10n.settingsSkipIntroHint),
            value: controller.skipIntroEnabled,
            onChanged: (value) => unawaited(
              controller.setSkipEnabled(PlayerSkipKind.intro, value),
            ),
          ),
          SwitchListTile.adaptive(
            key: const Key('player-skip-outro-enabled'),
            title: Text(l10n.settingsSkipOutro),
            subtitle: Text(l10n.settingsSkipOutroHint),
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
