import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/media_source_format.dart';

class PublicServerInfo {
  const PublicServerInfo({
    required this.id,
    required this.serverName,
    this.version,
  });

  final String id;
  final String serverName;
  final String? version;

  factory PublicServerInfo.fromJson(
    Map<String, dynamic> json, {
    String? fallbackName,
  }) {
    final id = json['Id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const EmbyException(EmbyFailureKind.notEmby);
    }
    final name = json['ServerName']?.toString().trim() ?? '';
    return PublicServerInfo(
      id: id,
      serverName: name.isEmpty ? (fallbackName ?? id) : name,
      version: json['Version']?.toString(),
    );
  }
}

class EmbyUser {
  const EmbyUser({
    required this.id,
    required this.name,
    this.enableNextEpisodeAutoPlay = true,
    this.resumeRewindSeconds = 0,
  });

  final String id;
  final String name;
  final bool enableNextEpisodeAutoPlay;
  final int resumeRewindSeconds;

  factory EmbyUser.fromJson(Map<String, dynamic> json) {
    final id = json['Id']?.toString() ?? '';
    if (id.isEmpty) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    var autoPlay = true;
    var rewind = 0;
    final configuration = json['Configuration'];
    if (configuration is Map) {
      final map = Map<String, dynamic>.from(configuration);
      autoPlay = map['EnableNextEpisodeAutoPlay'] != false;
      rewind = _asInt(map['ResumeRewindSeconds']) ?? 0;
    }
    return EmbyUser(
      id: id,
      name: json['Name']?.toString() ?? '',
      enableNextEpisodeAutoPlay: autoPlay,
      resumeRewindSeconds: rewind,
    );
  }
}

class AuthenticationResult {
  const AuthenticationResult({
    required this.accessToken,
    required this.serverId,
    required this.user,
  });

  final String accessToken;
  final String serverId;
  final EmbyUser user;

  factory AuthenticationResult.fromJson(
    Map<String, dynamic> json, {
    required String fallbackServerId,
  }) {
    final token = json['AccessToken']?.toString() ?? '';
    if (token.isEmpty) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final userJson = json['User'];
    if (userJson is! Map) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final serverId = json['ServerId']?.toString().trim();
    return AuthenticationResult(
      accessToken: token,
      serverId: (serverId == null || serverId.isEmpty)
          ? fallbackServerId
          : serverId,
      user: EmbyUser.fromJson(Map<String, dynamic>.from(userJson)),
    );
  }
}

class EmbyUserData {
  const EmbyUserData({
    this.played = false,
    this.playbackPositionTicks = 0,
    this.playedPercentage,
  });

  final bool played;
  final int playbackPositionTicks;
  final double? playedPercentage;

  factory EmbyUserData.fromJson(dynamic json) {
    if (json is! Map) {
      return const EmbyUserData();
    }
    final map = Map<String, dynamic>.from(json);
    return EmbyUserData(
      played: map['Played'] == true,
      playbackPositionTicks: _asInt(map['PlaybackPositionTicks']) ?? 0,
      playedPercentage: _asDouble(map['PlayedPercentage']),
    );
  }

  EmbyUserData copyWith({
    bool? played,
    int? playbackPositionTicks,
    double? playedPercentage,
  }) {
    return EmbyUserData(
      played: played ?? this.played,
      playbackPositionTicks:
          playbackPositionTicks ?? this.playbackPositionTicks,
      playedPercentage: playedPercentage ?? this.playedPercentage,
    );
  }
}

class ItemChapter {
  const ItemChapter({
    required this.name,
    required this.startPositionTicks,
    this.imageTag,
    this.imageIndex,
    this.markerType,
  });

  final String name;
  final int startPositionTicks;
  final String? imageTag;
  final int? imageIndex;

  /// Emby/Jellyfin 扫描标记:`IntroStart` / `IntroEnd` / `CreditsStart` 等。
  final String? markerType;

  factory ItemChapter.fromJson(Map<String, dynamic> json) {
    final tag = json['ImageTag']?.toString().trim();
    final marker = json['MarkerType']?.toString().trim();
    return ItemChapter(
      name: json['Name']?.toString() ?? '',
      startPositionTicks: _asInt(json['StartPositionTicks']) ?? 0,
      imageTag: (tag == null || tag.isEmpty) ? null : tag,
      imageIndex: _asInt(json['ImageIndex']),
      markerType: (marker == null || marker.isEmpty) ? null : marker,
    );
  }
}

class ItemMediaStream {
  const ItemMediaStream({
    required this.index,
    required this.type,
    this.label,
    this.codec,
    this.channels,
    this.width,
    this.height,
    this.bitRate,
    this.videoRange,
    this.videoRangeType,
  });

  final int index;
  final String type;
  final String? label;
  final String? codec;
  final int? channels;
  final int? width;
  final int? height;
  final int? bitRate;
  final String? videoRange;
  final String? videoRangeType;

  bool get isAudio => type == 'Audio';
  bool get isSubtitle => type == 'Subtitle';
  bool get isVideo => type == 'Video';

  factory ItemMediaStream.fromJson(Map<String, dynamic> json) {
    final title = json['DisplayTitle']?.toString().trim();
    final language = json['Language']?.toString().trim();
    final codec = json['Codec']?.toString().trim();
    return ItemMediaStream(
      index: _asInt(json['Index']) ?? 0,
      type: json['Type']?.toString() ?? '',
      codec: codec,
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
}

class ItemMediaSource {
  const ItemMediaSource({
    required this.id,
    this.name,
    this.container,
    this.size,
    this.bitrate,
    this.width,
    this.height,
    this.streams = const [],
  });

  final String id;
  final String? name;
  final String? container;
  final int? size;
  final int? bitrate;
  final int? width;
  final int? height;
  final List<ItemMediaStream> streams;

  String get label {
    final title = name?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }
    return id;
  }

  MediaSourceView get presentation {
    ItemMediaStream? video;
    ItemMediaStream? audio;
    for (final stream in streams) {
      if (video == null && stream.isVideo) {
        video = stream;
      }
      if (audio == null && stream.isAudio) {
        audio = stream;
      }
    }
    return formatMediaSource(
      name: name,
      container: container,
      sizeBytes: size,
      bitrate: bitrate ?? video?.bitRate,
      width: width ?? video?.width,
      height: height ?? video?.height,
      videoCodec: video?.codec,
      videoRange: video?.videoRange,
      videoRangeType: video?.videoRangeType,
      audioCodec: audio?.codec,
      audioChannels: audio?.channels,
      audioTitle: audio?.label,
    );
  }

  List<ItemMediaStream> get audioStreams => [
    for (final stream in streams)
      if (stream.isAudio) stream,
  ];

  List<ItemMediaStream> get subtitleStreams => [
    for (final stream in streams)
      if (stream.isSubtitle) stream,
  ];

  factory ItemMediaSource.fromJson(Map<String, dynamic> json) {
    final raw = json['MediaStreams'];
    return ItemMediaSource(
      id: json['Id']?.toString() ?? '',
      name: json['Name']?.toString() ?? json['Path']?.toString(),
      container: json['Container']?.toString(),
      size: _asInt(json['Size']),
      bitrate: _asInt(json['Bitrate']),
      width: _asInt(json['Width']),
      height: _asInt(json['Height']),
      streams: [
        if (raw is List)
          for (final stream in raw)
            if (stream is Map)
              ItemMediaStream.fromJson(Map<String, dynamic>.from(stream)),
      ],
    );
  }
}

class EmbyItem {
  const EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    this.collectionType,
    this.overview,
    this.productionYear,
    this.runTimeTicks,
    this.childCount,
    this.seriesName,
    this.seriesId,
    this.seasonId,
    this.parentId,
    this.indexNumber,
    this.parentIndexNumber,
    this.primaryImageTag,
    this.thumbImageTag,
    this.backdropImageTag,
    this.seriesPrimaryImageTag,
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentBackdropItemId,
    this.parentBackdropImageTag,
    this.communityRating,
    this.genres = const [],
    this.mediaSources = const [],
    this.chapters = const [],
    this.userData = const EmbyUserData(),
  });

  final String id;
  final String name;
  final String type;
  final String? collectionType;
  final String? overview;
  final int? productionYear;
  final int? runTimeTicks;
  final int? childCount;
  final String? seriesName;
  final String? seriesId;
  final String? seasonId;
  final String? parentId;
  final int? indexNumber;
  final int? parentIndexNumber;
  final String? primaryImageTag;
  final String? thumbImageTag;
  final String? backdropImageTag;
  final String? seriesPrimaryImageTag;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentBackdropItemId;
  final String? parentBackdropImageTag;
  final double? communityRating;

  /// 条目流派(服务端 /Items 默认返回的 Genres 数组),供片库流派筛选聚合取值。
  final List<String> genres;
  final List<ItemMediaSource> mediaSources;
  final List<ItemChapter> chapters;
  final EmbyUserData userData;

  bool get isMovie => type == 'Movie';
  bool get isSeries => type == 'Series';
  bool get isSeason => type == 'Season';
  bool get isEpisode => type == 'Episode';
  bool get isPlayable => isMovie || isEpisode;
  bool get isMovieOrSeries => isMovie || isSeries;
  bool get isResumeMedia => isMovie || isEpisode;

  String get collectionTypeNormalized =>
      collectionType?.trim().toLowerCase() ?? '';

  bool get isMovieOrTvCollection =>
      collectionTypeNormalized == 'movies' ||
      collectionTypeNormalized == 'tvshows';

  bool get isUntypedCollection => collectionTypeNormalized.isEmpty;

  bool get isExcludedCollection {
    const excluded = {
      'music',
      'musicalbums',
      'musicartists',
      'musicvideos',
      'livetv',
      'photos',
      'books',
      'games',
      'playlists',
      'homevideos',
      'channels',
      'boxsets',
    };
    return excluded.contains(collectionTypeNormalized);
  }

  String get displayName {
    if (isEpisode && seriesName != null && seriesName!.isNotEmpty) {
      return '$seriesName · $name';
    }
    return name;
  }

  bool get canResume => !userData.played && userData.playbackPositionTicks > 0;

  /// 海报/剧照候选:横图优先本集 Thumb;剧海报与本集 Primary 相同时跳过,避免一排同一张剧图。
  List<ItemImageRef> imageCandidates({
    bool preferBackdrop = false,
    bool preferThumb = false,
  }) {
    final landscape = preferBackdrop || preferThumb || isEpisode;
    final refs = <ItemImageRef>[];
    void add(
      String itemId,
      String type,
      String? tag, {
      bool requireTag = true,
    }) {
      if (requireTag && (tag == null || tag.isEmpty)) {
        return;
      }
      final exists = refs.any(
        (ref) => ref.itemId == itemId && ref.type == type,
      );
      if (exists) {
        return;
      }
      refs.add(ItemImageRef(itemId: itemId, type: type, tag: tag));
    }

    if (preferBackdrop) {
      add(id, 'Backdrop', backdropImageTag);
      if (!isEpisode) {
        final parentBackdrop = parentBackdropItemId;
        if (parentBackdrop != null) {
          add(parentBackdrop, 'Backdrop', parentBackdropImageTag);
        }
      }
    }
    if (landscape) {
      add(id, 'Thumb', thumbImageTag);
    }
    final seriesPoster =
        isEpisode &&
        primaryImageTag != null &&
        seriesPrimaryImageTag != null &&
        primaryImageTag == seriesPrimaryImageTag;
    if (!seriesPoster) {
      add(id, 'Primary', primaryImageTag);
    }
    if (refs.isEmpty && !isEpisode) {
      add(id, 'Primary', primaryImageTag, requireTag: false);
    }
    if (landscape && !isEpisode) {
      add(id, 'Thumb', thumbImageTag);
      final parentThumb = parentThumbItemId;
      if (parentThumb != null) {
        add(parentThumb, 'Thumb', parentThumbImageTag);
      }
      final parentBackdrop = parentBackdropItemId;
      if (parentBackdrop != null) {
        add(parentBackdrop, 'Backdrop', parentBackdropImageTag);
      }
      final series = seriesId;
      if (series != null) {
        add(series, 'Primary', seriesPrimaryImageTag);
      }
    }
    if (isEpisode) {
      final parentThumb = parentThumbItemId;
      if (parentThumb != null) {
        add(parentThumb, 'Thumb', parentThumbImageTag);
      }
      final parentBackdrop = parentBackdropItemId;
      if (parentBackdrop != null) {
        add(parentBackdrop, 'Backdrop', parentBackdropImageTag);
      }
    }
    return refs;
  }

  double get playbackProgress {
    final percent = userData.playedPercentage;
    if (percent != null) {
      return (percent / 100).clamp(0.0, 1.0);
    }
    final runtime = runTimeTicks ?? 0;
    if (runtime <= 0) {
      return 0;
    }
    return (userData.playbackPositionTicks / runtime).clamp(0.0, 1.0);
  }

  factory EmbyItem.fromJson(Map<String, dynamic> json) {
    final id = json['Id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final tags = json['ImageTags'];
    final tagMap = tags is Map ? Map<dynamic, dynamic>.from(tags) : const {};
    final primaryTag =
        _mapImageTag(tagMap, 'Primary') ?? _stringTag(json['PrimaryImageTag']);
    final thumbTag = _mapImageTag(tagMap, 'Thumb');
    final backdropTag =
        _firstListTag(json['BackdropImageTags']) ??
        _mapImageTag(tagMap, 'Backdrop');
    final parentBackdropTag = _firstListTag(json['ParentBackdropImageTags']);
    final rawSources = json['MediaSources'];
    final rawChapters = json['Chapters'];
    final rawGenres = json['Genres'];
    return EmbyItem(
      id: id,
      name: json['Name']?.toString() ?? '',
      type: json['Type']?.toString() ?? '',
      collectionType: json['CollectionType']?.toString(),
      overview: _plotFromJson(json),
      productionYear: _asInt(json['ProductionYear']),
      runTimeTicks: _asInt(json['RunTimeTicks']),
      childCount: _asInt(json['ChildCount']),
      seriesName: json['SeriesName']?.toString(),
      seriesId: json['SeriesId']?.toString(),
      seasonId: json['SeasonId']?.toString(),
      parentId: json['ParentId']?.toString(),
      indexNumber: _asInt(json['IndexNumber']),
      parentIndexNumber: _asInt(json['ParentIndexNumber']),
      primaryImageTag: primaryTag,
      thumbImageTag: thumbTag,
      backdropImageTag: backdropTag,
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
      mediaSources: [
        if (rawSources is List)
          for (final source in rawSources)
            if (source is Map)
              ItemMediaSource.fromJson(Map<String, dynamic>.from(source)),
      ],
      chapters: [
        if (rawChapters is List)
          for (final chapter in rawChapters)
            if (chapter is Map)
              ItemChapter.fromJson(Map<String, dynamic>.from(chapter)),
      ],
      userData: EmbyUserData.fromJson(json['UserData']),
    );
  }

  EmbyItem copyWith({EmbyUserData? userData}) {
    return EmbyItem(
      id: id,
      name: name,
      type: type,
      collectionType: collectionType,
      overview: overview,
      productionYear: productionYear,
      runTimeTicks: runTimeTicks,
      childCount: childCount,
      seriesName: seriesName,
      seriesId: seriesId,
      seasonId: seasonId,
      parentId: parentId,
      indexNumber: indexNumber,
      parentIndexNumber: parentIndexNumber,
      primaryImageTag: primaryImageTag,
      thumbImageTag: thumbImageTag,
      backdropImageTag: backdropImageTag,
      seriesPrimaryImageTag: seriesPrimaryImageTag,
      parentThumbItemId: parentThumbItemId,
      parentThumbImageTag: parentThumbImageTag,
      parentBackdropItemId: parentBackdropItemId,
      parentBackdropImageTag: parentBackdropImageTag,
      communityRating: communityRating,
      genres: genres,
      mediaSources: mediaSources,
      chapters: chapters,
      userData: userData ?? this.userData,
    );
  }
}

class EmbyItemPage {
  const EmbyItemPage({required this.items, this.totalRecordCount});

  final List<EmbyItem> items;
  final int? totalRecordCount;

  bool hasMore({required int fetched, required int pageSize}) {
    if (items.isEmpty) {
      return false;
    }
    final total = totalRecordCount;
    if (total != null) {
      return fetched < total;
    }
    return items.length >= pageSize;
  }
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

List<EmbyItem> parseEmbyItemList(dynamic data) {
  if (data == null) {
    return const [];
  }
  if (data is List) {
    return [
      for (final item in data)
        if (item is Map) EmbyItem.fromJson(Map<String, dynamic>.from(item)),
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
          if (item is Map) EmbyItem.fromJson(Map<String, dynamic>.from(item)),
      ];
    }
  }
  throw const EmbyException(EmbyFailureKind.unknown);
}

class ItemImageRef {
  const ItemImageRef({required this.itemId, required this.type, this.tag});

  final String itemId;
  final String type;
  final String? tag;
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

String? _firstListTag(dynamic value) {
  if (value is! List || value.isEmpty) {
    return null;
  }
  return _stringTag(value.first);
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

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
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
