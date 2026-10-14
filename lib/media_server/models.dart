import 'capabilities.dart';

import 'package:rillight/media_server/media_source_format.dart';

class PublicServerInfo {
  const PublicServerInfo({
    required this.id,
    required this.serverName,
    this.version,
  });

  final String id;
  final String serverName;
  final String? version;
}

class MediaUser {
  const MediaUser({
    required this.id,
    required this.name,
    this.enableNextEpisodeAutoPlay = true,
    this.resumeRewindSeconds = 0,
  });

  final String id;
  final String name;
  final bool enableNextEpisodeAutoPlay;
  final int resumeRewindSeconds;
}

class AuthenticationResult {
  const AuthenticationResult({
    required this.accessToken,
    required this.serverId,
    required this.user,
  });

  final String accessToken;
  final String serverId;
  final MediaUser user;
}

class MediaUserData {
  const MediaUserData({
    this.played = false,
    this.playbackPosition = Duration.zero,
    this.playedPercentage,
    this.lastPlayedDate,
  });

  final bool played;
  final Duration playbackPosition;
  final double? playedPercentage;

  /// Unknown when absent or invalid; never inferred from response order.
  final DateTime? lastPlayedDate;

  MediaUserData copyWith({
    bool? played,
    Duration? playbackPosition,
    double? playedPercentage,
    DateTime? lastPlayedDate,
  }) {
    return MediaUserData(
      played: played ?? this.played,
      playbackPosition: playbackPosition ?? this.playbackPosition,
      playedPercentage: playedPercentage ?? this.playedPercentage,
      lastPlayedDate: lastPlayedDate ?? this.lastPlayedDate,
    );
  }
}

class ItemChapter {
  const ItemChapter({
    required this.name,
    required this.startPosition,
    this.imageTag,
    this.imageIndex,
    this.markerType,
  });

  final String name;
  final Duration startPosition;
  final String? imageTag;
  final int? imageIndex;

  /// Emby/Jellyfin 扫描标记:`IntroStart` / `IntroEnd` / `CreditsStart` 等。
  final String? markerType;
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
    this.language,
    this.isDefault,
    this.isForced,
    this.isExternal,
    this.profile,
    this.averageFrameRate,
    this.sampleRate,
    this.channelLayout,
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
  final String? language;
  final bool? isDefault;
  final bool? isForced;
  final bool? isExternal;
  final String? profile;
  final double? averageFrameRate;
  final int? sampleRate;
  final String? channelLayout;

  bool get isAudio => type == 'Audio';
  bool get isSubtitle => type == 'Subtitle';
  bool get isVideo => type == 'Video';
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
    this.runtime,
  });

  final String id;
  final String? name;
  final String? container;
  final int? size;
  final int? bitrate;
  final int? width;
  final int? height;
  final List<ItemMediaStream> streams;
  final Duration? runtime;

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
}

/// 详情 People 数组中的演职员/制作人员条目。
class ItemPerson {
  const ItemPerson({
    required this.name,
    this.id,
    this.type,
    this.role,
    this.primaryImageTag,
  });

  final String name;

  /// 人物条目的不透明 Id；头像由服务图片接口取得,
  /// 缺失时 UI 只能做文字兜底。
  final String? id;

  /// 人物类型:`Actor` / `Director` / `Writer` 等。
  final String? type;

  /// 演员饰演的角色名;非演员条目通常为 null。
  final String? role;

  /// 头像 Primary 图 tag,缺失时由 UI 做文字兜底。
  final String? primaryImageTag;
}

/// 进度达到该比例视为看完(对齐 Jellyfin/Emby MaxResumePct 默认 90%)。
const double kPlaybackCompleteProgress = 0.9;

class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.collectionType,
    this.overview,
    this.productionYear,
    this.premiereDate,
    this.dateCreated,
    this.runtime,
    this.childCount,
    this.seriesName,
    this.seriesId,
    this.seasonId,
    this.parentId,
    this.indexNumber,
    this.indexNumberEnd,
    this.parentIndexNumber,
    this.primaryImageTag,
    this.thumbImageTag,
    this.logoImageTag,
    this.backdropImageTag,
    this.backdropImageTags = const [],
    this.parentBackdropImageTags = const [],
    this.seriesPrimaryImageTag,
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentBackdropItemId,
    this.parentBackdropImageTag,
    this.communityRating,
    this.genres = const [],
    this.externalUrls = const [],
    this.providerIds = const {},
    this.mediaSources = const [],
    this.chapters = const [],
    this.people = const [],
    this.userData = const MediaUserData(),
  });

  final String id;
  final String name;
  final String type;
  final String? collectionType;
  final String? overview;
  final int? productionYear;

  /// 播出日期(Emby `PremiereDate`);ISO8601 解析失败或缺失时为 null。
  final DateTime? premiereDate;

  /// 入库日期(Emby `DateCreated`);ISO8601 解析失败或缺失时为 null。
  final DateTime? dateCreated;

  final Duration? runtime;
  final int? childCount;
  final String? seriesName;
  final String? seriesId;
  final String? seasonId;
  final String? parentId;
  final int? indexNumber;
  final int? indexNumberEnd;
  final int? parentIndexNumber;
  final String? primaryImageTag;
  final String? thumbImageTag;

  /// Transparent title artwork (`ImageTags.Logo`). Only requested for the
  /// featured carousel rows; other lists leave it null.
  final String? logoImageTag;
  final String? backdropImageTag;
  final List<String> backdropImageTags;
  final List<String> parentBackdropImageTags;
  final String? seriesPrimaryImageTag;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentBackdropItemId;
  final String? parentBackdropImageTag;
  final double? communityRating;

  /// 条目流派(服务端 /Items 默认返回的 Genres 数组),供片库流派筛选聚合取值。
  final List<String> genres;

  /// Emby `ExternalUrls`：IMDb、官网等站外链接。
  final List<ItemExternalUrl> externalUrls;

  /// Reliable identity facts only; ExternalUrls are not identity evidence.
  final Map<String, String> providerIds;
  final List<ItemMediaSource> mediaSources;
  final List<ItemChapter> chapters;

  /// 演职员与制作人员;仅详情路径请求 People 字段后才有值。
  final List<ItemPerson> people;
  final MediaUserData userData;

  bool get isMovie => type == 'Movie';
  bool get isSeries => type == 'Series';
  bool get isSeason => type == 'Season';
  bool get isEpisode => type == 'Episode';

  /// Some Emby responses omit ParentId for episodes/seasons but include the
  /// concrete series hierarchy. Callers must still verify the library ancestor.
  String? get hierarchyParentId {
    for (final id in [
      parentId,
      if (isEpisode) seasonId,
      if (isEpisode || isSeason) seriesId,
    ]) {
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  bool get isPhoto => type == 'Photo';
  bool get isPhotoAlbum => type == 'PhotoAlbum';
  bool get isPlayable => isMovie || isEpisode;
  bool get isMovieOrSeries => isMovie || isSeries;
  bool get isResumeMedia => isMovie || isEpisode;

  String get collectionTypeNormalized =>
      collectionType?.trim().toLowerCase() ?? '';

  bool get isMovieOrTvCollection =>
      collectionTypeNormalized == 'movies' ||
      collectionTypeNormalized == 'tvshows';

  bool get isPhotoCollection => collectionTypeNormalized == 'photos';

  bool get isUntypedCollection => collectionTypeNormalized.isEmpty;

  bool get isExcludedCollection {
    const excluded = {
      'music',
      'musicalbums',
      'musicartists',
      'musicvideos',
      'livetv',
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

  /// 未看完才续播。已标记已看、或进度达到片尾阈值(Emby/Jellyfin
  /// MaxResumePct 默认 90%)时从头播放,也不再展示「已看 x%」。
  bool get canResume {
    if (userData.played) {
      return false;
    }
    final progress = playbackProgress;
    if (progress > kPlaybackCompleteProgress) {
      return false;
    }
    if (progress > 0) {
      return true;
    }
    return userData.playbackPosition > Duration.zero;
  }

  /// 续播起点。只有百分比时按片长换算,供播放器 seek。
  Duration get resumePosition {
    final ticks = userData.playbackPosition;
    if (ticks > Duration.zero) {
      return ticks;
    }
    final percent = userData.playedPercentage;
    final total = runtime ?? Duration.zero;
    if (percent == null || percent <= 0 || total <= Duration.zero) {
      return Duration.zero;
    }
    return total * (percent / 100);
  }

  /// 海报/剧照候选:横图优先本集 Thumb;剧海报与本集 Primary 相同时跳过,避免一排同一张剧图。
  ///
  /// [preferParentBackdrop] 用于单集 hero 底图:先取所属剧集的 Backdrop,
  /// 与前景的本集剧照形成两张不同的图;无剧集 backdrop 时才退回本集横图。
  List<ItemImageRef> imageCandidates({
    bool preferBackdrop = false,
    bool preferThumb = false,
    bool preferParentBackdrop = false,
  }) {
    final landscape =
        preferBackdrop || preferThumb || preferParentBackdrop || isEpisode;
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

    if (preferParentBackdrop) {
      final parentBackdrop = parentBackdropItemId;
      if (parentBackdrop != null) {
        add(parentBackdrop, 'Backdrop', parentBackdropImageTag);
      }
      add(id, 'Backdrop', backdropImageTag);
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
        (isEpisode || isSeason) &&
        primaryImageTag != null &&
        seriesPrimaryImageTag != null &&
        primaryImageTag == seriesPrimaryImageTag;
    if (!seriesPoster) {
      add(id, 'Primary', primaryImageTag);
    }
    // A season often has no separate poster. Its inherited tag belongs to the
    // series endpoint, and is also the fallback when a season poster is stale.
    if (isSeason && !landscape && seriesId?.isNotEmpty == true) {
      add(seriesId!, 'Primary', seriesPrimaryImageTag);
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
    final total = runtime ?? Duration.zero;
    if (total <= Duration.zero) {
      return 0;
    }
    return (userData.playbackPosition.inMicroseconds / total.inMicroseconds)
        .clamp(0.0, 1.0);
  }

  MediaItem copyWith({MediaUserData? userData}) {
    return MediaItem(
      id: id,
      name: name,
      type: type,
      collectionType: collectionType,
      overview: overview,
      productionYear: productionYear,
      premiereDate: premiereDate,
      dateCreated: dateCreated,
      runtime: runtime,
      childCount: childCount,
      seriesName: seriesName,
      seriesId: seriesId,
      seasonId: seasonId,
      parentId: parentId,
      indexNumber: indexNumber,
      indexNumberEnd: indexNumberEnd,
      parentIndexNumber: parentIndexNumber,
      primaryImageTag: primaryImageTag,
      thumbImageTag: thumbImageTag,
      logoImageTag: logoImageTag,
      backdropImageTag: backdropImageTag,
      backdropImageTags: backdropImageTags,
      parentBackdropImageTags: parentBackdropImageTags,
      seriesPrimaryImageTag: seriesPrimaryImageTag,
      parentThumbItemId: parentThumbItemId,
      parentThumbImageTag: parentThumbImageTag,
      parentBackdropItemId: parentBackdropItemId,
      parentBackdropImageTag: parentBackdropImageTag,
      communityRating: communityRating,
      genres: genres,
      externalUrls: externalUrls,
      providerIds: providerIds,
      mediaSources: mediaSources,
      chapters: chapters,
      people: people,
      userData: userData ?? this.userData,
    );
  }
}

class ItemExternalUrl {
  const ItemExternalUrl({required this.name, required this.url});

  final String name;
  final String url;
}

class MediaItemPage {
  const MediaItemPage({
    required this.items,
    this.totalRecordCount,
    this.offset = 0,
    this.pagination = const CapabilityStatus(
      CapabilityAvailability.unknown,
      reason: '尚未核实分页能力',
    ),
  });

  final List<MediaItem> items;
  final int? totalRecordCount;
  final int offset;
  final CapabilityStatus pagination;

  bool hasMore({required int fetched, required int pageSize}) {
    if (items.isEmpty ||
        pagination.availability == CapabilityAvailability.unsupported) {
      return false;
    }
    final total = totalRecordCount;
    if (total != null) {
      return fetched < total;
    }
    return items.length >= pageSize;
  }
}

class ItemImageRef {
  const ItemImageRef({required this.itemId, required this.type, this.tag});

  final String itemId;
  final String type;
  final String? tag;
}

/// `/Items/Counts` 返回中除电影/剧集/单集外的一类条目数量。
class LibraryCountEntry {
  const LibraryCountEntry({required this.type, required this.count});

  /// 服务器返回的类型名(字段名去掉 `Count` 后缀),如 `MusicAlbum`、`Photo`。
  final String type;

  /// 该类型的条目数量;为 0 也保留,由界面照常展示。
  final int count;
}

/// 当前登录用户可见的库规模,来自 `GET /Items/Counts`。
///
/// 电影/剧集/单集固定成员,响应缺失时按 0 处理;其余类型仅收录服务器
/// 实际返回的字段(0 也收录),顺序与响应一致。
class LibraryCounts {
  const LibraryCounts({
    required this.movie,
    required this.series,
    required this.episode,
    required this.others,
  });

  final int? movie;
  final int? series;
  final int? episode;
  final List<LibraryCountEntry> others;
}
