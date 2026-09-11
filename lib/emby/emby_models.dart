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
