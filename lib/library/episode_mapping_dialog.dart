import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../aggregation/identity/media_identity.dart';
import '../app/l10n/app_localizations.dart';

const userConfirmedEpisodeNumbering = 'user-confirmed-season-episode';

/// A user's explicit mapping assertion, not a title/duration matching rule.
/// Null means cancelled; false preserves T4's uncertain/missing boundaries.
Future<bool?> confirmEpisodeMapping(BuildContext context) => showDialog<bool>(
  context: context,
  useRootNavigator: false,
  builder: (dialog) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    child: AlertDialog(
      title: Text(AppLocalizations.of(dialog).aggregationEpisodeMapping),
      content: Text(
        AppLocalizations.of(dialog).aggregationEpisodeMappingWarning,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(AppLocalizations.of(dialog).aggregationEpisodeUncertain),
        ),
        TextButton(
          key: const Key('episode-mapping-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(
            AppLocalizations.of(dialog).aggregationEpisodeMappingConfirm,
          ),
        ),
      ],
    ),
  ),
);

EpisodeSource withConfirmedEpisodeMapping(EpisodeSource episode) =>
    EpisodeSource(
      reference: episode.reference,
      series: episode.series,
      season: episode.season,
      episode: episode.episode,
      endEpisode: episode.endEpisode,
      isSpecial: episode.isSpecial,
      providerIds: episode.providerIds,
      numberingScheme: userConfirmedEpisodeNumbering,
    );
