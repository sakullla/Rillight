import '../aggregation/identity/media_identity.dart';

const userConfirmedEpisodeNumbering = 'user-confirmed-season-episode';

/// Marks season and episode numbers as usable for this lookup.
/// The detail sheet applies this itself so the user is not asked to confirm.
EpisodeSource withConfirmedEpisodeMapping(EpisodeSource episode) =>
    EpisodeSource(
      reference: episode.reference,
      series: episode.series,
      season: episode.season,
      episode: episode.episode,
      endEpisode: episode.endEpisode,
      isSpecial: episode.isSpecial,
      providerIds: episode.providerIds,
      name: episode.name,
      numberingScheme: userConfirmedEpisodeNumbering,
    );
