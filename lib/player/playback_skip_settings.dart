import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
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
      final scheme = AppUiTheme.of(context).colorScheme;
      Widget card({required Key key, required Widget child}) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: child,
          ),
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          card(
            key: const Key('player-skip-intro-card'),
            child: AppSwitchTile(
              key: const Key('player-skip-intro-enabled'),
              title: Text(
                l10n.settingsSkipIntro,
                style: TextStyle(color: scheme.onSurface),
              ),
              subtitle: compact ? null : Text(l10n.settingsSkipIntroHint),
              value: controller.skipIntroEnabled,
              onChanged: (value) => unawaited(
                controller.setSkipEnabled(PlayerSkipKind.intro, value),
              ),
            ),
          ),
          card(
            key: const Key('player-skip-outro-card'),
            child: AppSwitchTile(
              key: const Key('player-skip-outro-enabled'),
              title: Text(
                l10n.settingsSkipOutro,
                style: TextStyle(color: scheme.onSurface),
              ),
              subtitle: compact ? null : Text(l10n.settingsSkipOutroHint),
              value: controller.skipOutroEnabled,
              onChanged: (value) => unawaited(
                controller.setSkipEnabled(PlayerSkipKind.outro, value),
              ),
            ),
          ),
        ],
      );
    },
  );
}
