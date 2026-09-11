import 'package:rillight/emby/emby_errors.dart';

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
  });

  final String name;
  final int startPositionTicks;
  final String? imageTag;

  factory ItemChapter.fromJson(Map<String, dynamic> json) {
    return ItemChapter(
      name: json['Name']?.toString() ?? '',
      startPositionTicks: _asInt(json['StartPositionTicks']) ?? 0,
      imageTag: json['ImageTag']?.toString(),
    );
  }
}

class ItemMediaStream {
  const ItemMediaStream({required this.index, required this.type, this.label});

  final int index;
  final String type;
  final String? label;

  bool get isAudio => type == 'Audio';
  bool get isSubtitle => type == 'Subtitle';

  factory ItemMediaStream.fromJson(Map<String, dynamic> json) {
    final title = json['DisplayTitle']?.toString().trim();
    final language = json['Language']?.toString().trim();
    final codec = json['Codec']?.toString().trim();
    return ItemMediaStream(
      index: _asInt(json['Index']) ?? 0,
      type: json['Type']?.toString() ?? '',
      label: (title != null && title.isNotEmpty)
          ? title
          : (language != null && language.isNotEmpty)
          ? language
          : codec,
    );
  }
}

class ItemMediaSource {
  const ItemMediaSource({required this.id, this.name, this.streams = const []});

  final String id;
  final String? name;
  final List<ItemMediaStream> streams;

  String get label {
    final title = name?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }
    return id;
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
    this.backdropImageTag,
    this.communityRating,
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
  final String? backdropImageTag;
  final double? communityRating;
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
    String? primaryTag;
    final tags = json['ImageTags'];
    if (tags is Map && tags['Primary'] != null) {
      final tag = tags['Primary'].toString().trim();
      if (tag.isNotEmpty) {
        primaryTag = tag;
      }
    }
    String? backdropTag;
    final backdrops = json['BackdropImageTags'];
    if (backdrops is List && backdrops.isNotEmpty) {
      final tag = backdrops.first.toString().trim();
      if (tag.isNotEmpty) {
        backdropTag = tag;
      }
    }
    final rawSources = json['MediaSources'];
    final rawChapters = json['Chapters'];
    return EmbyItem(
      id: id,
      name: json['Name']?.toString() ?? '',
      type: json['Type']?.toString() ?? '',
      collectionType: json['CollectionType']?.toString(),
      overview: json['Overview']?.toString(),
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
      backdropImageTag: backdropTag,
      communityRating: _asDouble(json['CommunityRating']),
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
      backdropImageTag: backdropImageTag,
      communityRating: communityRating,
      mediaSources: mediaSources,
      chapters: chapters,
      userData: userData ?? this.userData,
    );
  }
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
