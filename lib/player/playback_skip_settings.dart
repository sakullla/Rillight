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
      Widget card({
        required Key key,
        required bool active,
        required Widget child,
      }) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            key: key,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primary.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(
                color: active
                    ? scheme.primary.withValues(alpha: 0.42)
                    : scheme.outlineVariant.withValues(alpha: 0.4),
              ),
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
            active: controller.skipIntroEnabled,
            child: AppSwitchTile(
              key: const Key('player-skip-intro-enabled'),
              title: Text(
                l10n.settingsSkipIntro,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
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
            active: controller.skipOutroEnabled,
            child: AppSwitchTile(
              key: const Key('player-skip-outro-enabled'),
              title: Text(
                l10n.settingsSkipOutro,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
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
