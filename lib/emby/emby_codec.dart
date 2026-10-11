import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/errors.dart';

PublicServerInfo decodeEmbyPublicServerInfo(
  Map<String, dynamic> json, {
  String? fallbackName,
}) {
  final id = json['Id']?.toString().trim() ?? '';
  if (id.isEmpty) {
    throw const MediaServerException(MediaServerFailureKind.incompatibleServer);
  }
  final name = json['ServerName']?.toString().trim() ?? '';
  return PublicServerInfo(
    id: id,
    serverName: name.isEmpty ? (fallbackName ?? id) : name,
    version: json['Version']?.toString(),
  );
}

MediaUser decodeEmbyMediaUser(Map<String, dynamic> json) {
  final id = json['Id']?.toString() ?? '';
  if (id.isEmpty) {
    throw const MediaServerException(MediaServerFailureKind.unknown);
  }
  var autoPlay = true;
  var rewind = 0;
  final configuration = json['Configuration'];
  if (configuration is Map) {
    final map = Map<String, dynamic>.from(configuration);
    autoPlay = map['EnableNextEpisodeAutoPlay'] != false;
    rewind = _asInt(map['ResumeRewindSeconds']) ?? 0;
  }
  return MediaUser(
    id: id,
    name: json['Name']?.toString() ?? '',
    enableNextEpisodeAutoPlay: autoPlay,
    resumeRewindSeconds: rewind,
  );
}

AuthenticationResult decodeEmbyAuthenticationResult(
  Map<String, dynamic> json, {
  required String fallbackServerId,
}) {
  final token = json['AccessToken']?.toString() ?? '';
  if (token.isEmpty) {
    throw const MediaServerException(MediaServerFailureKind.unknown);
  }
  final userJson = json['User'];
  if (userJson is! Map) {
    throw const MediaServerException(MediaServerFailureKind.unknown);
  }
  final serverId = json['ServerId']?.toString().trim();
  return AuthenticationResult(
    accessToken: token,
    serverId: (serverId == null || serverId.isEmpty)
        ? fallbackServerId
        : serverId,
    user: decodeEmbyMediaUser(Map<String, dynamic>.from(userJson)),
  );
}

MediaUserData decodeEmbyMediaUserData(dynamic json) {
  if (json is! Map) {
    return const MediaUserData();
  }
  final map = Map<String, dynamic>.from(json);
  return MediaUserData(
    played: map['Played'] == true,
    playbackPosition: Duration(
      microseconds: (_asInt(map['PlaybackPositionTicks']) ?? 0) ~/ 10,
    ),
    playedPercentage: _asDouble(map['PlayedPercentage']),
    lastPlayedDate: _asDateTime(map['LastPlayedDate']),
  );
}

ItemChapter decodeEmbyItemChapter(Map<String, dynamic> json) {
  final tag = json['ImageTag']?.toString().trim();
  final marker = json['MarkerType']?.toString().trim();
  return ItemChapter(
    name: json['Name']?.toString() ?? '',
    startPosition: Duration(
      microseconds: (_asInt(json['StartPositionTicks']) ?? 0) ~/ 10,
    ),
    imageTag: (tag == null || tag.isEmpty) ? null : tag,
    imageIndex: _asInt(json['ImageIndex']),
    markerType: (marker == null || marker.isEmpty) ? null : marker,
  );
}

ItemMediaStream decodeEmbyItemMediaStream(Map<String, dynamic> json) {
  final title = json['DisplayTitle']?.toString().trim();
  final language = json['Language']?.toString().trim();
  final codec = json['Codec']?.toString().trim();
  return ItemMediaStream(
    index: _asInt(json['Index']) ?? 0,
    type: json['Type']?.toString() ?? '',
    codec: codec,
    language: _stringTag(json['Language']),
    isDefault: json['IsDefault'] is bool ? json['IsDefault'] as bool : null,
    isForced: json['IsForced'] is bool ? json['IsForced'] as bool : null,
    isExternal: json['IsExternal'] is bool ? json['IsExternal'] as bool : null,
    profile: _stringTag(json['Profile']),
    averageFrameRate: _asDouble(json['AverageFrameRate']),
    sampleRate: _asInt(json['SampleRate']),
    channelLayout: _stringTag(json['ChannelLayout']),
    channels: _asInt(json['Channels']),
    width: _asInt(json['Width']),
    height: _asInt(json['Height']),
    bitRate: _asInt(json['BitRate']),
    videoRange: json['VideoRange']?.toString(),
    videoRangeType: json['VideoRangeType']?.toString(),
    label: (title != null && title.isNotEmpty)
        ? title
        : (language != null && language.isNotEmpty)
        ? language
        : codec,
  );
}

ItemMediaSource decodeEmbyItemMediaSource(Map<String, dynamic> json) {
  final raw = json['MediaStreams'];
  return ItemMediaSource(
    id: json['Id']?.toString() ?? '',
    name: json['Name']?.toString() ?? json['Path']?.toString(),
    container: json['Container']?.toString(),
    size: _asInt(json['Size']),
    bitrate: _asInt(json['Bitrate']),
    runtime: _asInt(json['RunTimeTicks']) == null
        ? null
        : Duration(microseconds: _asInt(json['RunTimeTicks'])! ~/ 10),
    width: _asInt(json['Width']),
    height: _asInt(json['Height']),
    streams: [
      if (raw is List)
        for (final stream in raw)
          if (stream is Map)
            decodeEmbyItemMediaStream(Map<String, dynamic>.from(stream)),
    ],
  );
}

ItemPerson decodeEmbyItemPerson(Map<String, dynamic> json) {
  return ItemPerson(
    name: json['Name']?.toString() ?? '',
    id: _stringTag(json['Id']),
    type: _stringTag(json['Type']),
    role: _stringTag(json['Role']),
    primaryImageTag: _stringTag(json['PrimaryImageTag']),
  );
}

MediaItem decodeEmbyMediaItem(Map<String, dynamic> json) {
  final id = json['Id']?.toString().trim() ?? '';
  if (id.isEmpty) {
    throw const MediaServerException(MediaServerFailureKind.unknown);
  }
  final tags = json['ImageTags'];
  final tagMap = tags is Map ? Map<dynamic, dynamic>.from(tags) : const {};
  final primaryTag =
      _mapImageTag(tagMap, 'Primary') ?? _stringTag(json['PrimaryImageTag']);
  final thumbTag = _mapImageTag(tagMap, 'Thumb');
  final logoTag = _mapImageTag(tagMap, 'Logo');
  final backdropTags = _listTags(json['BackdropImageTags']);
  final parentBackdropTags = _listTags(json['ParentBackdropImageTags']);
  final backdropTag =
      backdropTags.firstOrNull ?? _mapImageTag(tagMap, 'Backdrop');
  final parentBackdropTag = parentBackdropTags.firstOrNull;
  final rawSources = json['MediaSources'];
  final rawChapters = json['Chapters'];
  final rawGenres = json['Genres'];
  final rawLinks = json['ExternalUrls'];
  final rawPeople = json['People'];
  return MediaItem(
    id: id,
    name: json['Name']?.toString() ?? '',
    type: json['Type']?.toString() ?? '',
    collectionType: json['CollectionType']?.toString(),
    overview: _plotFromJson(json),
    productionYear: _asInt(json['ProductionYear']),
    premiereDate: _asDateTime(json['PremiereDate']),
    dateCreated: _asDateTime(json['DateCreated']),
    runtime: _asInt(json['RunTimeTicks']) == null
        ? null
        : Duration(microseconds: _asInt(json['RunTimeTicks'])! ~/ 10),
    childCount: _asInt(json['ChildCount']),
    seriesName: json['SeriesName']?.toString(),
    seriesId: json['SeriesId']?.toString(),
    seasonId: json['SeasonId']?.toString(),
    parentId: json['ParentId']?.toString(),
    indexNumber: _asInt(json['IndexNumber']),
    indexNumberEnd: _asInt(json['IndexNumberEnd']),
    parentIndexNumber: _asInt(json['ParentIndexNumber']),
    primaryImageTag: primaryTag,
    thumbImageTag: thumbTag,
    logoImageTag: logoTag,
    backdropImageTag: backdropTag,
    backdropImageTags: backdropTags,
    parentBackdropImageTags: parentBackdropTags,
    seriesPrimaryImageTag: _stringTag(json['SeriesPrimaryImageTag']),
    parentThumbItemId: _stringTag(json['ParentThumbItemId']),
    parentThumbImageTag: _stringTag(json['ParentThumbImageTag']),
    parentBackdropItemId: _stringTag(json['ParentBackdropItemId']),
    parentBackdropImageTag: parentBackdropTag,
    communityRating: _asDouble(json['CommunityRating']),
    genres: [
      if (rawGenres is List)
        for (final genre in rawGenres)
          if (genre != null) genre.toString(),
    ],
    providerIds: {
      if (json['ProviderIds'] is Map)
        for (final entry in (json['ProviderIds'] as Map).entries)
          if (entry.value != null && entry.value.toString().trim().isNotEmpty)
            entry.key.toString(): entry.value.toString().trim(),
    },
    externalUrls: [
      if (rawLinks is List)
        for (final link in rawLinks)
          if (link is Map)
            decodeEmbyItemExternalUrl(Map<String, dynamic>.from(link)),
    ].where((link) => link.url.isNotEmpty).toList(),
    mediaSources: [
      if (rawSources is List)
        for (final source in rawSources)
          if (source is Map)
            decodeEmbyItemMediaSource(Map<String, dynamic>.from(source)),
    ],
    chapters: [
      if (rawChapters is List)
        for (final chapter in rawChapters)
          if (chapter is Map)
            decodeEmbyItemChapter(Map<String, dynamic>.from(chapter)),
    ],
    people: [
      if (rawPeople is List)
        for (final person in rawPeople)
          if (person is Map)
            decodeEmbyItemPerson(Map<String, dynamic>.from(person)),
    ],
    userData: decodeEmbyMediaUserData(json['UserData']),
  );
}

List<MediaItem> parseEmbyItemList(dynamic data) {
  if (data == null) {
    return const [];
  }
  if (data is List) {
    return [
      for (final item in data)
        if (item is Map) decodeEmbyMediaItem(Map<String, dynamic>.from(item)),
    ];
  }
  if (data is Map) {
    final items = data['Items'];
    if (items == null) {
      return const [];
    }
    if (items is List) {
      return [
        for (final item in items)
          if (item is Map) decodeEmbyMediaItem(Map<String, dynamic>.from(item)),
      ];
    }
  }
  throw const MediaServerException(MediaServerFailureKind.unknown);
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }
  return null;
}

double? _asDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

LibraryCounts decodeEmbyLibraryCounts(Map<String, dynamic> json) {
  int? movie, series, episode;
  final others = <LibraryCountEntry>[];
  for (final entry in json.entries) {
    final value = entry.value;
    if (value is! num || !entry.key.endsWith('Count')) {
      continue;
    }
    final type = entry.key.substring(0, entry.key.length - 'Count'.length);
    if (type.isEmpty) {
      continue;
    }
    final count = value.toInt();
    switch (type) {
      case 'Movie':
        movie = count;
      case 'Series':
        series = count;
      case 'Episode':
        episode = count;
      default:
        others.add(LibraryCountEntry(type: type, count: count));
    }
  }
  return LibraryCounts(
    movie: movie,
    series: series,
    episode: episode,
    others: others,
  );
}

int? parseEmbyTotalCount(dynamic data) {
  if (data is! Map) {
    return null;
  }
  final raw = data['TotalRecordCount'];
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw);
  }
  return null;
}

String? _stringTag(dynamic value) {
  final tag = value?.toString().trim();
  if (tag == null || tag.isEmpty) {
    return null;
  }
  return tag;
}

String? _mapImageTag(Map<dynamic, dynamic> tags, String key) {
  final direct = tags[key] ?? tags[key.toLowerCase()];
  if (direct != null) {
    return _imageTagValue(direct);
  }
  final wanted = key.toLowerCase();
  for (final entry in tags.entries) {
    if (entry.key.toString().toLowerCase() == wanted) {
      return _imageTagValue(entry.value);
    }
  }
  return null;
}

String? _imageTagValue(dynamic value) {
  if (value is Map) {
    return _stringTag(value['Tag'] ?? value['tag']);
  }
  return _stringTag(value);
}

List<String> _listTags(dynamic value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final entry in value)
      if (_stringTag(entry) != null) _stringTag(entry)!,
  ];
}

/// 条目剧情:优先 Overview,部分 Emby/刮削只填 ShortOverview 或 Taglines。
String? _plotFromJson(Map<String, dynamic> json) {
  final overview = _nonEmptyText(json['Overview']);
  if (overview != null) {
    return overview;
  }
  final shortOverview = _nonEmptyText(json['ShortOverview']);
  if (shortOverview != null) {
    return shortOverview;
  }
  final taglines = json['Taglines'];
  if (taglines is List) {
    for (final tagline in taglines) {
      final text = _nonEmptyText(tagline);
      if (text != null) {
        return text;
      }
    }
  }
  return null;
}

String? _nonEmptyText(dynamic value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}

/// Emby 日期是 ISO8601 字符串(小数秒可达 7 位 ticks,DateTime.parse 截断处理);
/// 缺失或非法值一律置 null,由 UI 省略对应展示项。
DateTime? _asDateTime(dynamic value) {
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}

MediaStreamInfo decodeEmbyMediaStreamInfo(Map<String, dynamic> json) {
  return MediaStreamInfo(
    index: _asInt(json['Index']) ?? 0,
    type: json['Type']?.toString() ?? '',
    codec: json['Codec']?.toString(),
    language: json['Language']?.toString(),
    displayTitle: json['DisplayTitle']?.toString(),
    isDefault: json['IsDefault'] == true,
    isExternal: json['IsExternal'] == true,
    deliveryMethod: json['DeliveryMethod']?.toString(),
    deliveryUrl: json['DeliveryUrl']?.toString(),
    isTextSubtitleStream: json['IsTextSubtitleStream'] is bool
        ? json['IsTextSubtitleStream'] as bool
        : null,
    channels: _asInt(json['Channels']),
    width: _asInt(json['Width']),
    height: _asInt(json['Height']),
    bitRate: _asInt(json['BitRate']),
    videoRange: json['VideoRange']?.toString(),
    videoRangeType: json['VideoRangeType']?.toString(),
  );
}

PlaybackMediaSource decodeEmbyPlaybackMediaSource(Map<String, dynamic> json) {
  final streams = <MediaStreamInfo>[];
  final raw = json['MediaStreams'];
  if (raw is List) {
    for (final item in raw) {
      if (item is Map) {
        streams.add(decodeEmbyMediaStreamInfo(Map<String, dynamic>.from(item)));
      }
    }
  }
  return PlaybackMediaSource(
    id: json['Id']?.toString() ?? '',
    name: json['Name']?.toString(),
    container: json['Container']?.toString(),
    protocol: json['Protocol']?.toString(),
    path: json['Path']?.toString(),
    supportsDirectPlay: json['SupportsDirectPlay'] == true,
    supportsDirectStream: json['SupportsDirectStream'] == true,
    supportsTranscoding: json['SupportsTranscoding'] == true,
    isInfiniteStream: json['IsInfiniteStream'] == true,
    directStreamUrl: json['DirectStreamUrl']?.toString(),
    transcodingUrl: json['TranscodingUrl']?.toString(),
    runtime: _asInt(json['RunTimeTicks']) == null
        ? null
        : Duration(microseconds: _asInt(json['RunTimeTicks'])! ~/ 10),
    defaultAudioStreamIndex: _asInt(json['DefaultAudioStreamIndex']),
    defaultSubtitleStreamIndex: _asInt(json['DefaultSubtitleStreamIndex']),
    size: _asInt(json['Size']),
    bitrate: _asInt(json['Bitrate']),
    width: _asInt(json['Width']),
    height: _asInt(json['Height']),
    mediaStreams: streams,
  );
}

PlaybackInfo decodeEmbyPlaybackInfo(Map<String, dynamic> json) {
  final sources = <PlaybackMediaSource>[];
  final raw = json['MediaSources'];
  if (raw is List) {
    for (final item in raw) {
      if (item is Map) {
        sources.add(
          decodeEmbyPlaybackMediaSource(Map<String, dynamic>.from(item)),
        );
      }
    }
  }
  return PlaybackInfo(
    playSessionId: json['PlaySessionId']?.toString() ?? '',
    mediaSources: sources,
  );
}

Map<String, dynamic> encodeEmbyPlaybackReport(PlaybackReport report) {
  return {
    'ItemId': report.itemId,
    'MediaSourceId': report.mediaSourceId,
    'PlaySessionId': report.playSessionId,
    'PlayMethod': switch (report.playMethod) {
      PlayMethod.directPlay => 'DirectPlay',
      PlayMethod.directStream => 'DirectStream',
      PlayMethod.transcode => 'Transcode',
    },
    'PositionTicks': report.position.inMicroseconds * 10,
    'IsPaused': report.isPaused,
    'IsMuted': report.volumeLevel <= 0,
    'VolumeLevel': report.volumeLevel,
    'CanSeek': report.canSeek,
    'RepeatMode': 'RepeatNone',
    if (report.audioStreamIndex != null)
      'AudioStreamIndex': report.audioStreamIndex,
    if (report.subtitleStreamIndex != null)
      'SubtitleStreamIndex': report.subtitleStreamIndex,
    if (report.eventName != null) 'EventName': report.eventName,
  };
}

ItemExternalUrl decodeEmbyItemExternalUrl(Map<String, dynamic> json) {
  return ItemExternalUrl(
    name: json['Name']?.toString() ?? '',
    url: json['Url']?.toString() ?? '',
  );
}
