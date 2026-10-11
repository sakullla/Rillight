import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/errors.dart';
import 'plex_http.dart';

Duration? plexDuration(Object? value) =>
    plexInt(value) == null ? null : Duration(milliseconds: plexInt(value)!);
String plexStreamType(Object? value) => switch (plexInt(value)) {
  1 => 'Video',
  2 => 'Audio',
  3 => 'Subtitle',
  _ => 'Unknown',
};
List<Map<String, dynamic>> plexStreams(Map<String, dynamic> media) =>
    plexList(plexList(media['Part']).firstOrNull?['Stream']);

MediaItem plexItem(Map<String, dynamic> row, {bool section = false}) {
  final type = switch (row['type']) {
    'movie' => 'Movie',
    'show' => 'Series',
    'season' => 'Season',
    'episode' => 'Episode',
    _ => 'Unknown',
  };
  final id = plexString(section ? row['key'] : row['ratingKey']);
  final media = plexList(row['Media']);
  final providers = <String, String>{};
  for (final guid in plexList(row['Guid'])) {
    final value = Uri.tryParse(plexString(guid['id']));
    if (value != null && ['imdb', 'tmdb', 'tvdb'].contains(value.scheme)) {
      providers[value.scheme] = value.host.isNotEmpty ? value.host : value.path;
    }
  }
  DateTime? epoch(Object? n) => plexInt(n) == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(plexInt(n)! * 1000, isUtc: true);
  final chapters = <ItemChapter>[
    for (final chapter in plexList(row['Chapter']))
      if (plexInt(chapter['startTimeOffset']) != null)
        ItemChapter(
          name: plexString(chapter['title']),
          startPosition: plexDuration(chapter['startTimeOffset'])!,
          imageTag: chapter['thumb'] as String?,
          imageIndex: plexInt(chapter['index']),
        ),
  ];
  for (final marker in plexList(row['Marker'])) {
    final start = plexDuration(marker['startTimeOffset']);
    final end = plexDuration(marker['endTimeOffset']);
    if (start == null || end == null || end <= start) continue;
    final kind = marker['type'];
    if (kind == 'intro' || kind == 'credits') {
      final prefix = kind == 'intro' ? 'Intro' : 'Credits';
      chapters.add(
        ItemChapter(
          name: '$prefix start',
          startPosition: start,
          markerType: '${prefix}Start',
        ),
      );
      chapters.add(
        ItemChapter(
          name: '$prefix end',
          startPosition: end,
          markerType: '${prefix}End',
        ),
      );
    }
  }
  chapters.sort((a, b) => a.startPosition.compareTo(b.startPosition));
  return MediaItem(
    id: id,
    name: plexString(row['title']),
    type: section ? 'CollectionFolder' : type,
    collectionType: section
        ? (row['type'] == 'movie'
              ? 'movies'
              : row['type'] == 'show'
              ? 'tvshows'
              : row['type'] as String?)
        : null,
    overview: row['summary'] as String?,
    productionYear: plexInt(row['year']),
    premiereDate: DateTime.tryParse(plexString(row['originallyAvailableAt'])),
    dateCreated: epoch(row['addedAt']),
    runtime: plexDuration(row['duration']),
    childCount: plexInt(row['childCount'] ?? row['leafCount']),
    seriesName: row['grandparentTitle'] as String?,
    seriesId:
        plexString(
          row[type == 'Season' ? 'parentRatingKey' : 'grandparentRatingKey'],
        ).isEmpty
        ? null
        : plexString(
            row[type == 'Season' ? 'parentRatingKey' : 'grandparentRatingKey'],
          ),
    seasonId: type == 'Episode' ? row['parentRatingKey']?.toString() : null,
    parentId:
        row['parentRatingKey']?.toString() ??
        (row['librarySectionID'] == null
            ? null
            : 'section:${row['librarySectionID']}'),
    indexNumber: plexInt(row['index']),
    parentIndexNumber: plexInt(row['parentIndex']),
    primaryImageTag: row['thumb'] as String?,
    thumbImageTag: row['thumb'] as String?,
    backdropImageTag: row['art'] as String?,
    seriesPrimaryImageTag: row['grandparentThumb'] as String?,
    parentBackdropItemId: row['grandparentRatingKey']?.toString(),
    parentBackdropImageTag: row['grandparentArt'] as String?,
    communityRating: (row['rating'] as num?)?.toDouble(),
    providerIds: providers,
    genres: plexList(row['Genre']).map((v) => plexString(v['tag'])).toList(),
    chapters: chapters,
    people: [
      for (final kind in ['Role', 'Director', 'Writer'])
        for (final person in plexList(row[kind]))
          ItemPerson(
            name: plexString(person['tag']),
            id: person['id']?.toString(),
            type: kind == 'Role' ? 'Actor' : kind,
            role: person['role'] as String?,
            primaryImageTag: person['thumb'] as String?,
          ),
    ],
    mediaSources: [
      for (final m in media)
        ItemMediaSource(
          id: plexString(m['id']),
          name: plexString(m['videoResolution']),
          container: m['container'] as String?,
          bitrate: plexInt(m['bitrate']) == null
              ? null
              : plexInt(m['bitrate'])! * 1000,
          width: plexInt(m['width']),
          height: plexInt(m['height']),
          runtime: plexDuration(m['duration'] ?? row['duration']),
          size: plexList(
            m['Part'],
          ).fold<int>(0, (n, p) => n + (plexInt(p['size']) ?? 0)),
          streams: [
            for (final s in plexStreams(m))
              ItemMediaStream(
                index: plexInt(s['id']) ?? 0,
                type: plexStreamType(s['streamType']),
                codec: s['codec'] as String?,
                language: s['languageCode'] as String?,
                label: (s['displayTitle'] ?? s['title']) as String?,
                channels: plexInt(s['channels']),
                width: plexInt(s['width']),
                height: plexInt(s['height']),
                isDefault: s['selected'] == true || s['selected'] == 1,
                isExternal: s['key'] != null,
              ),
          ],
        ),
    ],
    userData: MediaUserData(
      played: (plexInt(row['viewCount']) ?? 0) > 0,
      playbackPosition: plexDuration(row['viewOffset']) ?? Duration.zero,
      lastPlayedDate: epoch(row['lastViewedAt']),
    ),
  );
}

MediaStreamInfo plexPlaybackStream(Map<String, dynamic> row) => MediaStreamInfo(
  index: plexInt(row['id']) ?? 0,
  type: plexStreamType(row['streamType']),
  codec: row['codec'] as String?,
  language: row['languageCode'] as String?,
  displayTitle: (row['displayTitle'] ?? row['title']) as String?,
  isDefault: row['selected'] == 1 || row['selected'] == true,
  isExternal: row['key'] != null,
  deliveryUrl: row['key'] as String?,
  deliveryMethod: row['key'] != null ? 'External' : null,
  channels: plexInt(row['channels']),
  width: plexInt(row['width']),
  height: plexInt(row['height']),
  bitRate: plexInt(row['bitrate']) == null
      ? null
      : plexInt(row['bitrate'])! * 1000,
);

/// [index] is the source Plex Stream ID used for server selection. A decision
/// can produce a different stream index in the actual playback container.
class PlexNegotiatedStream extends MediaStreamInfo {
  const PlexNegotiatedStream({
    required super.index,
    required super.type,
    super.codec,
    super.language,
    super.displayTitle,
    super.isDefault,
    super.isExternal,
    super.deliveryUrl,
    super.deliveryMethod,
    super.channels,
    super.width,
    super.height,
    super.bitRate,
    required this.playbackIndex,
    required this.decision,
    required this.location,
  });
  final int? playbackIndex;
  final String decision, location;
}

List<MediaStreamInfo> plexNegotiatedStreams(
  List<Map<String, dynamic>> original,
  List<Map<String, dynamic>> negotiated, {
  required int? audioId,
  required int? subtitleId,
  required String Function(String) resolveUrl,
  required String sidecarUrl,
}) {
  return original.map((source) {
    final id = plexInt(source['id']);
    final type = plexInt(source['streamType']);
    final selected =
        type == 1 ||
        type == 2 && id == audioId ||
        type == 3 && id == subtitleId;
    final matches = negotiated
        .where(
          (stream) =>
              plexInt(stream['id']) == id &&
              plexInt(stream['streamType']) == type,
        )
        .toList();
    // Missing IDs cannot safely associate one of several source tracks.
    final output = matches.length == 1 ? matches.single : null;
    if (selected && output == null) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidResponse,
        detail: '协商结果缺少所选轨道',
      );
    }
    if (output == null) return plexPlaybackStream(source);
    final decision = plexString(output['decision']);
    final location = plexString(output['location']);
    final unavailable = ['unavailable', 'ignore', 'none'].contains(decision);
    if (selected && unavailable) {
      throw const MediaServerException(
        MediaServerFailureKind.forbidden,
        detail: '服务器无法交付所选轨道',
      );
    }
    final delivery = unavailable
        ? 'Unavailable'
        : decision == 'burn'
        ? 'Encode'
        : switch (location) {
            'sidecar' || 'sidecar-subs' => 'External',
            'segments-subs' => 'Hls',
            'embedded' => 'Embed',
            'direct' =>
              output['key'] != null || source['key'] != null
                  ? 'External'
                  : 'Embed',
            _ => null,
          };
    if (selected && type == 3 && delivery == null) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidResponse,
        detail: '字幕协商缺少交付方式',
      );
    }
    String? key;
    if (delivery == 'External') {
      key = output['key'] is String
          ? resolveUrl(output['key'] as String)
          : location == 'direct' && source['key'] is String
          ? resolveUrl(source['key'] as String)
          : sidecarUrl;
    } else if (delivery == 'Hls' && output['key'] is String) {
      key = resolveUrl(output['key'] as String);
    }
    return PlexNegotiatedStream(
      index: id!,
      type: plexStreamType(type),
      codec: (output['codec'] ?? source['codec']) as String?,
      language: source['languageCode'] as String?,
      displayTitle: (source['displayTitle'] ?? source['title']) as String?,
      isDefault: selected,
      isExternal: delivery == 'External',
      deliveryMethod: delivery,
      deliveryUrl: key,
      channels: plexInt(output['channels'] ?? source['channels']),
      width: plexInt(output['width'] ?? source['width']),
      height: plexInt(output['height'] ?? source['height']),
      playbackIndex: plexInt(output['index']),
      decision: decision,
      location: location,
    );
  }).toList();
}
