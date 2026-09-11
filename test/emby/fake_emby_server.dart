import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeEmbyUser {
  const FakeEmbyUser({
    required this.username,
    required this.password,
    required this.userId,
    this.enableNextEpisodeAutoPlay = true,
    this.resumeRewindSeconds = 0,
  });

  final String username;
  final String password;
  final String userId;
  final bool enableNextEpisodeAutoPlay;
  final int resumeRewindSeconds;
}

class FakeMediaStream {
  const FakeMediaStream({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.displayTitle,
    this.isDefault = false,
    this.isTextSubtitleStream,
    this.channels,
  });

  final int index;
  final String type;
  final String? codec;
  final String? language;
  final String? displayTitle;
  final bool isDefault;
  final bool? isTextSubtitleStream;
  final int? channels;

  Map<String, dynamic> toJson() {
    return {
      'Index': index,
      'Type': type,
      if (codec != null) 'Codec': codec,
      if (language != null) 'Language': language,
      if (displayTitle != null) 'DisplayTitle': displayTitle,
      'IsDefault': isDefault,
      if (isTextSubtitleStream != null)
        'IsTextSubtitleStream': isTextSubtitleStream,
      if (channels != null) 'Channels': channels,
    };
  }
}

class FakePlaybackEvent {
  FakePlaybackEvent({required this.kind, required this.body});

  final String kind;
  final Map<String, dynamic> body;
}

class FakeChapter {
  const FakeChapter({
    required this.name,
    required this.startPositionTicks,
    this.imageTag,
  });

  final String name;
  final int startPositionTicks;
  final String? imageTag;

  Map<String, dynamic> toJson() {
    return {
      'Name': name,
      'StartPositionTicks': startPositionTicks,
      if (imageTag != null) 'ImageTag': imageTag,
    };
  }
}

class FakeEmbyItem {
  FakeEmbyItem({
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
    this.played = false,
    this.playbackPositionTicks = 0,
    this.playedPercentage,
    this.nextUp = false,
    DateTime? dateCreated,
    DateTime? premiereDate,
    this.communityRating,
    this.container = 'mkv',
    this.forceTranscode = false,
    this.supportsDirectPlay = true,
    this.supportsDirectStream = true,
    this.mediaStreams = const [],
    this.chapters = const [],
  }) : dateCreated = dateCreated ?? DateTime.utc(2024, 1, 1),
       premiereDate =
           premiereDate ??
           (productionYear != null ? DateTime.utc(productionYear, 1, 1) : null);

  final String id;
  String name;
  String type;
  String? collectionType;
  String? overview;
  int? productionYear;
  int? runTimeTicks;
  int? childCount;
  String? seriesName;
  String? seriesId;
  String? seasonId;
  String? parentId;
  int? indexNumber;
  int? parentIndexNumber;
  String? primaryImageTag;
  bool played;
  int playbackPositionTicks;
  double? playedPercentage;
  bool nextUp;
  DateTime dateCreated;
  DateTime? premiereDate;
  double? communityRating;
  String container;
  bool forceTranscode;
  bool supportsDirectPlay;
  bool supportsDirectStream;
  List<FakeMediaStream> mediaStreams;
  List<FakeChapter> chapters;

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      'Type': type,
      if (collectionType != null) 'CollectionType': collectionType,
      if (overview != null) 'Overview': overview,
      if (productionYear != null) 'ProductionYear': productionYear,
      if (runTimeTicks != null) 'RunTimeTicks': runTimeTicks,
      if (childCount != null) 'ChildCount': childCount,
      if (seriesName != null) 'SeriesName': seriesName,
      if (seriesId != null) 'SeriesId': seriesId,
      if (seasonId != null) 'SeasonId': seasonId,
      if (parentId != null) 'ParentId': parentId,
      if (indexNumber != null) 'IndexNumber': indexNumber,
      if (parentIndexNumber != null) 'ParentIndexNumber': parentIndexNumber,
      if (primaryImageTag != null) 'ImageTags': {'Primary': primaryImageTag},
      'DateCreated': dateCreated.toIso8601String(),
      if (premiereDate != null) 'PremiereDate': premiereDate!.toIso8601String(),
      if (communityRating != null) 'CommunityRating': communityRating,
      if (mediaStreams.isNotEmpty)
        'MediaSources': [
          {
            'Id': id,
            'Name': name,
            'MediaStreams': [for (final stream in mediaStreams) stream.toJson()],
          },
        ],
      if (chapters.isNotEmpty)
        'Chapters': [for (final chapter in chapters) chapter.toJson()],
      'UserData': {
        'Played': played,
        'PlaybackPositionTicks': playbackPositionTicks,
        if (playedPercentage != null) 'PlayedPercentage': playedPercentage,
      },
    };
  }
}

final Uint8List kTinyPng = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

class FakeEmbyServer {
  FakeEmbyServer({
    this.serverId = 'server-id-1',
    this.serverName = '灯川测试',
    this.version = '4.8.0.0',
    Uri? baseUrl,
    List<FakeEmbyUser>? users,
    List<FakeEmbyItem>? views,
    List<FakeEmbyItem>? items,
  }) : baseUrl = baseUrl ?? Uri.parse('http://emby.test:8096'),
       users =
           users ??
           const [
             FakeEmbyUser(
               username: 'alice',
               password: 'correct-horse',
               userId: 'user-alice',
             ),
           ],
       views = views ?? defaultCatalogViews(),
       items = items ?? defaultCatalogItems();

  final List<FakeEmbyUser> users;
  final Uri baseUrl;
  String serverId;
  String serverName;
  String version;
  List<FakeEmbyItem> views;
  List<FakeEmbyItem> items;

  bool hangPublicInfo = false;
  bool publicInfoHtml = false;
  int? publicInfoStatus;
  String? publicInfoRawBody;
  bool expireAuthenticatedRequests = false;
  int? nextUpStatus;
  int? resumeStatus;
  int? viewsStatus;
  int? latestMovieStatus;
  int? latestEpisodeStatus;
  int? itemsStatus;
  int? searchStatus;
  int? itemStatus;
  int? similarStatus;
  bool similarEmpty = false;
  final Set<String> failingImageIds = {'movie-broken'};

  final List<String> requests = [];
  final List<String?> requestUserAgents = [];
  String? lastUserAgent;
  String? lastAuthorization;
  final List<FakePlaybackEvent> playbackEvents = [];
  Map<String, dynamic>? lastDeviceProfile;
  Map<String, dynamic>? lastPlaybackInfoBody;
  int? progressStatus;
  final Set<String> issuedTokens = {};
  final Set<String> loggedOutTokens = {};
  int _tokenSeq = 0;
  int _playSeq = 0;

  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final path = options.uri.path;
    final method = options.method.toUpperCase();
    final segments = options.uri.pathSegments;
    final query = options.uri.query;
    requests.add(query.isEmpty ? '$method $path' : '$method $path?$query');
    lastUserAgent = _headerValue(options, 'user-agent');
    lastAuthorization =
        _headerValue(options, 'authorization') ??
        _headerValue(options, 'x-emby-authorization');
    requestUserAgents.add(lastUserAgent);

    if (hangPublicInfo && path.endsWith('/System/Info/Public')) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    if (path.endsWith('/System/Info/Public') && method == 'GET') {
      return _handlePublicInfo();
    }
    if (path.endsWith('/Users/AuthenticateByName') && method == 'POST') {
      return _handleAuthenticate(await _readBody(options, requestStream));
    }

    final token = _tokenOf(options);
    if (expireAuthenticatedRequests ||
        token == null ||
        !issuedTokens.contains(token) ||
        loggedOutTokens.contains(token)) {
      return _json(401, {'error': 'unauthorized'});
    }

    if (path.endsWith('/Sessions/Logout') && method == 'POST') {
      loggedOutTokens.add(token);
      issuedTokens.remove(token);
      return _json(200, {});
    }

    if (path.endsWith('/System/Info') && method == 'GET') {
      return _json(200, {
        'Id': serverId,
        'ServerName': serverName,
        'Version': version,
      });
    }

    final playback = await _handlePlayback(
      options,
      method,
      segments,
      requestStream,
    );
    if (playback != null) {
      return playback;
    }

    final catalog = _handleCatalog(options, method, segments);
    if (catalog != null) {
      return catalog;
    }

    return _json(404, {'error': 'not found'});
  }

  Future<ResponseBody?> _handlePlayback(
    RequestOptions options,
    String method,
    List<String> segments,
    Stream<Uint8List>? requestStream,
  ) async {
    if (segments.length == 2 && segments[0] == 'Users' && method == 'GET') {
      return _handleUser(segments[1]);
    }
    if (segments.length == 3 &&
        segments[0] == 'Items' &&
        segments[2] == 'PlaybackInfo' &&
        method == 'POST') {
      return _handlePlaybackInfo(
        segments[1],
        await _readBody(options, requestStream),
      );
    }
    if (segments.isNotEmpty && segments[0] == 'Sessions' && method == 'POST') {
      return _handlePlaybackReport(
        segments,
        await _readBody(options, requestStream),
      );
    }
    if (segments.length >= 3 &&
        (segments[0] == 'Videos' || segments[0] == 'videos')) {
      return _handleVideoResource(segments);
    }
    return null;
  }

  ResponseBody _handleUser(String userId) {
    FakeEmbyUser? user;
    for (final item in users) {
      if (item.userId == userId) {
        user = item;
        break;
      }
    }
    if (user == null) {
      return _json(404, {'error': 'not found'});
    }
    return _json(200, {
      'Id': user.userId,
      'Name': user.username,
      'Configuration': {
        'EnableNextEpisodeAutoPlay': user.enableNextEpisodeAutoPlay,
        'ResumeRewindSeconds': user.resumeRewindSeconds,
      },
    });
  }

  ResponseBody _handlePlaybackInfo(String itemId, String raw) {
    final item = _itemById(itemId);
    if (item == null || (item.type != 'Movie' && item.type != 'Episode')) {
      return _json(404, {'error': 'not found'});
    }
    Map<String, dynamic> body = const {};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
    }
    lastPlaybackInfoBody = body;
    final profile = body['DeviceProfile'];
    lastDeviceProfile = profile is Map
        ? Map<String, dynamic>.from(profile)
        : null;

    final maxBitrate = body['MaxStreamingBitrate'] is num
        ? (body['MaxStreamingBitrate'] as num).toInt()
        : null;
    final subtitleIndex = body['SubtitleStreamIndex'] is num
        ? (body['SubtitleStreamIndex'] as num).toInt()
        : null;
    final startTicks = body['StartTimeTicks'] is num
        ? (body['StartTimeTicks'] as num).toInt()
        : 0;
    final playSessionId = 'play-${++_playSeq}';
    final streams = item.mediaStreams.isNotEmpty
        ? item.mediaStreams
        : _defaultStreams();

    var burnIn = false;
    if (subtitleIndex != null) {
      for (final stream in streams) {
        if (stream.index == subtitleIndex &&
            stream.type == 'Subtitle' &&
            stream.isTextSubtitleStream != true) {
          burnIn = true;
        }
      }
    }
    final transcode =
        item.forceTranscode ||
        burnIn ||
        (maxBitrate != null && maxBitrate <= 8000000);

    int? defaultAudio;
    int? defaultSubtitle;
    for (final stream in streams) {
      if (stream.type == 'Audio' && defaultAudio == null) {
        defaultAudio = stream.index;
      }
      if (stream.type == 'Subtitle' && stream.isDefault) {
        defaultSubtitle = stream.index;
      }
    }

    final source = <String, dynamic>{
      'Id': item.id,
      'Container': transcode ? 'ts' : item.container,
      'SupportsDirectPlay': !transcode && item.supportsDirectPlay,
      'SupportsDirectStream': !transcode && item.supportsDirectStream,
      'SupportsTranscoding': true,
      'RunTimeTicks': item.runTimeTicks ?? 0,
      'DefaultAudioStreamIndex': ?defaultAudio,
      'DefaultSubtitleStreamIndex': ?defaultSubtitle,
      'MediaStreams': [for (final stream in streams) stream.toJson()],
    };
    if (transcode) {
      var transcoding =
          '/videos/${item.id}/master.m3u8?MediaSourceId=${item.id}'
          '&PlaySessionId=$playSessionId'
          '&MaxStreamingBitrate=${maxBitrate ?? 8000000}';
      if (startTicks > 0) {
        transcoding += '&StartTimeTicks=$startTicks';
      }
      if (subtitleIndex != null) {
        transcoding += '&SubtitleStreamIndex=$subtitleIndex';
      }
      source['TranscodingUrl'] = transcoding;
      source['TranscodingSubProtocol'] = 'hls';
      source['TranscodingContainer'] = 'ts';
    } else {
      source['DirectStreamUrl'] =
          '/Videos/${item.id}/stream.${item.container}?static=true'
          '&MediaSourceId=${item.id}&PlaySessionId=$playSessionId';
    }
    return _json(200, {
      'MediaSources': [source],
      'PlaySessionId': playSessionId,
    });
  }

  ResponseBody _handlePlaybackReport(List<String> segments, String raw) {
    Map<String, dynamic> body = const {};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
    }
    var kind = 'Playing';
    if (segments.length >= 3 && segments[2] == 'Progress') {
      kind = 'Progress';
    } else if (segments.length >= 3 && segments[2] == 'Stopped') {
      kind = 'Stopped';
    }
    playbackEvents.add(FakePlaybackEvent(kind: kind, body: body));
    if (kind == 'Progress' && progressStatus != null) {
      return _json(progressStatus!, {'error': 'progress failed'});
    }
    final itemId = body['ItemId']?.toString();
    final ticks = body['PositionTicks'];
    if (itemId != null && ticks is num) {
      final item = _itemById(itemId);
      if (item != null) {
        item.playbackPositionTicks = ticks.toInt();
      }
    }
    return _json(200, {});
  }

  ResponseBody _handleVideoResource(List<String> segments) {
    if (segments.length >= 6 &&
        segments[2] != 'Subtitles' &&
        segments[3] == 'Subtitles') {
      return ResponseBody.fromString(
        '1\n00:00:00,000 --> 00:00:02,000\nhello\n',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    if (segments.last.startsWith('master.m3u8')) {
      return ResponseBody.fromString(
        '#EXTM3U\n',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/vnd.apple.mpegurl'],
        },
      );
    }
    return ResponseBody.fromBytes(
      Uint8List(32),
      200,
      headers: {
        Headers.contentTypeHeader: ['video/x-matroska'],
      },
    );
  }

  List<FakeMediaStream> _defaultStreams() {
    return const [
      FakeMediaStream(
        index: 0,
        type: 'Video',
        codec: 'h264',
        displayTitle: '1080p',
      ),
      FakeMediaStream(
        index: 1,
        type: 'Audio',
        codec: 'ac3',
        language: 'eng',
        displayTitle: 'English',
        isDefault: true,
        channels: 6,
      ),
    ];
  }

  ResponseBody? _handleCatalog(
    RequestOptions options,
    String method,
    List<String> segments,
  ) {
    if (segments.length >= 3 &&
        segments[0] == 'Items' &&
        segments[2] == 'Images' &&
        segments.length >= 4 &&
        segments[3] == 'Primary' &&
        method == 'GET') {
      return _handlePrimaryImage(segments[1]);
    }
    if (segments.length >= 5 &&
        segments[0] == 'Items' &&
        segments[2] == 'Images' &&
        segments[3] == 'Chapter' &&
        method == 'GET') {
      return ResponseBody.fromBytes(kTinyPng, 200, headers: {
        Headers.contentTypeHeader: ['image/png'],
      });
    }
    if (segments.length == 3 &&
        segments[0] == 'Items' &&
        segments[2] == 'Similar' &&
        method == 'GET') {
      return _handleSimilar(options, segments[1]);
    }

    if (segments.length >= 2 &&
        segments[0] == 'Shows' &&
        segments[1] == 'NextUp' &&
        method == 'GET') {
      if (nextUpStatus != null) {
        return _json(nextUpStatus!, {'error': 'nextup unavailable'});
      }
      return _queryResult(
        _sortAndLimit(items.where((item) => item.nextUp).toList(), options),
      );
    }

    if (segments.length < 3 || segments[0] != 'Users') {
      return null;
    }
    final rest = segments.sublist(2);
    if (rest.length == 1 && rest[0] == 'Views' && method == 'GET') {
      if (viewsStatus != null) {
        return _json(viewsStatus!, {'error': 'views failed'});
      }
      return _queryResult(views);
    }
    if (rest.length == 2 &&
        rest[0] == 'Items' &&
        rest[1] == 'Resume' &&
        method == 'GET') {
      if (resumeStatus != null) {
        return _json(resumeStatus!, {'error': 'resume failed'});
      }
      return _queryResult(
        _sortAndLimit(
          items
              .where(
                (item) =>
                    (item.type == 'Movie' || item.type == 'Episode') &&
                    !item.played &&
                    item.playbackPositionTicks > 0,
              )
              .toList(),
          options,
        ),
      );
    }
    if (rest.length == 2 &&
        rest[0] == 'Items' &&
        rest[1] == 'Latest' &&
        method == 'GET') {
      return _handleLatest(options);
    }
    if (rest.length == 1 && rest[0] == 'Items' && method == 'GET') {
      return _handleItems(options);
    }
    if (rest.length == 2 && rest[0] == 'Items' && method == 'GET') {
      if (itemStatus != null) {
        return _json(itemStatus!, {'error': 'item failed'});
      }
      final item = _itemById(rest[1]);
      if (item == null) {
        return _json(404, {'error': 'not found'});
      }
      return _json(200, item.toJson());
    }
    if (rest.length == 2 && rest[0] == 'PlayedItems') {
      final item = _itemById(rest[1]);
      if (item == null) {
        return _json(404, {'error': 'not found'});
      }
      if (method == 'POST') {
        item.played = true;
        item.playbackPositionTicks = 0;
        item.playedPercentage = 100;
        item.nextUp = false;
        return _json(200, item.toJson()['UserData'] as Map<String, dynamic>);
      }
      if (method == 'DELETE') {
        item.played = false;
        item.playedPercentage = 0;
        return _json(200, item.toJson()['UserData'] as Map<String, dynamic>);
      }
    }
    return null;
  }

  ResponseBody _handlePrimaryImage(String itemId) {
    if (failingImageIds.contains(itemId)) {
      return _json(404, {'error': 'image missing'});
    }
    final item = _itemById(itemId);
    if (item == null || item.primaryImageTag == null) {
      return _json(404, {'error': 'image missing'});
    }
    return ResponseBody.fromBytes(
      kTinyPng,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  ResponseBody _handleLatest(RequestOptions options) {
    final types = options.uri.queryParameters['IncludeItemTypes'] ?? '';
    final groupItems =
        (options.uri.queryParameters['GroupItems'] ?? 'true').toLowerCase() !=
        'false';
    if (types.contains('Movie') && latestMovieStatus != null) {
      return _json(latestMovieStatus!, {'error': 'latest movies failed'});
    }
    if (types.contains('Episode') && latestEpisodeStatus != null) {
      return _json(latestEpisodeStatus!, {'error': 'latest series failed'});
    }
    final limit =
        int.tryParse(options.uri.queryParameters['Limit'] ?? '') ?? 24;
    if (types.contains('Movie')) {
      final movies = items.where((item) => item.type == 'Movie').toList()
        ..sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
      return _json(200, [for (final item in movies.take(limit)) item.toJson()]);
    }
    if (types.contains('Episode')) {
      final episodes = items.where((item) => item.type == 'Episode').toList()
        ..sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
      if (!groupItems) {
        return _json(200, [
          for (final item in episodes.take(limit)) item.toJson(),
        ]);
      }
      final seen = <String>{};
      final grouped = <FakeEmbyItem>[];
      for (final episode in episodes) {
        final seriesId = episode.seriesId;
        if (seriesId == null || !seen.add(seriesId)) {
          continue;
        }
        grouped.add(_itemById(seriesId) ?? episode);
        if (grouped.length >= limit) {
          break;
        }
      }
      return _json(200, [for (final item in grouped) item.toJson()]);
    }
    return _json(200, <Map<String, dynamic>>[]);
  }

  ResponseBody _handleItems(RequestOptions options) {
    final search = options.uri.queryParameters['SearchTerm'];
    if (search != null) {
      if (searchStatus != null) {
        return _json(searchStatus!, {'error': 'search failed'});
      }
      return _queryResult(_filterItems(options, searchTerm: search));
    }
    if (itemsStatus != null) {
      return _json(itemsStatus!, {'error': 'items failed'});
    }
    return _queryResult(_filterItems(options));
  }

  List<FakeEmbyItem> _filterItems(
    RequestOptions options, {
    String? searchTerm,
  }) {
    final parentId = options.uri.queryParameters['ParentId'];
    final recursive =
        (options.uri.queryParameters['Recursive'] ?? 'false').toLowerCase() ==
        'true';
    final typeFilter = (options.uri.queryParameters['IncludeItemTypes'] ?? '')
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    var matched = items.where((item) {
      if (searchTerm != null &&
          !item.name.toLowerCase().contains(searchTerm.toLowerCase())) {
        return false;
      }
      if (typeFilter.isNotEmpty && !typeFilter.contains(item.type)) {
        return false;
      }
      if (parentId != null && parentId.isNotEmpty) {
        if (!_belongsTo(item, parentId, recursive: recursive)) {
          return false;
        }
      }
      return true;
    }).toList();
    return _sortAndLimit(matched, options);
  }

  List<FakeEmbyItem> _sortAndLimit(
    List<FakeEmbyItem> matched,
    RequestOptions options,
  ) {
    final sortBy = options.uri.queryParameters['SortBy'];
    final descending =
        (options.uri.queryParameters['SortOrder'] ?? '').toLowerCase() ==
        'descending';
    if (sortBy != null && sortBy.isNotEmpty) {
      matched.sort((a, b) {
        final compared = _compareBy(a, b, sortBy);
        return descending ? -compared : compared;
      });
    }
    final limit = int.tryParse(options.uri.queryParameters['Limit'] ?? '');
    if (limit != null && limit >= 0) {
      return matched.take(limit).toList();
    }
    return matched;
  }

  int _compareBy(FakeEmbyItem a, FakeEmbyItem b, String sortBy) {
    switch (sortBy) {
      case 'DateCreated':
        return a.dateCreated.compareTo(b.dateCreated);
      case 'PremiereDate':
        return _premiereOf(a).compareTo(_premiereOf(b));
      case 'CommunityRating':
        return (a.communityRating ?? 0).compareTo(b.communityRating ?? 0);
      case 'IndexNumber':
        final season = (a.parentIndexNumber ?? 0).compareTo(
          b.parentIndexNumber ?? 0,
        );
        if (season != 0) {
          return season;
        }
        return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
      case 'SortName':
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      default:
        return 0;
    }
  }

  DateTime _premiereOf(FakeEmbyItem item) {
    return item.premiereDate ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  ResponseBody _handleSimilar(RequestOptions options, String itemId) {
    if (similarStatus != null) {
      return _json(similarStatus!, {'error': 'similar failed'});
    }
    if (similarEmpty) {
      return _queryResult(const []);
    }
    final item = _itemById(itemId);
    if (item == null) {
      return _json(404, {'error': 'not found'});
    }
    final similar = items
        .where(
          (other) =>
              other.id != item.id &&
              other.type == item.type &&
              (other.type == 'Movie' || other.type == 'Series'),
        )
        .toList();
    return _queryResult(_sortAndLimit(similar, options));
  }

  bool _belongsTo(
    FakeEmbyItem item,
    String parentId, {
    required bool recursive,
  }) {
    if (item.parentId == parentId) {
      return true;
    }
    if (!recursive) {
      return false;
    }
    var current = item.parentId;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      if (current == parentId) {
        return true;
      }
      current = _itemById(current)?.parentId;
    }
    return false;
  }

  FakeEmbyItem? _itemById(String id) {
    for (final item in items) {
      if (item.id == id) {
        return item;
      }
    }
    for (final view in views) {
      if (view.id == id) {
        return view;
      }
    }
    return null;
  }

  ResponseBody _queryResult(List<FakeEmbyItem> matched) {
    return _json(200, {
      'Items': [for (final item in matched) item.toJson()],
      'TotalRecordCount': matched.length,
    });
  }

  ResponseBody _handlePublicInfo() {
    if (publicInfoStatus != null) {
      final raw = publicInfoRawBody;
      if (raw != null) {
        return ResponseBody.fromString(raw, publicInfoStatus!);
      }
      return _json(publicInfoStatus!, {'error': 'failed'});
    }
    if (publicInfoHtml) {
      return ResponseBody.fromString(
        '<html>not emby</html>',
        200,
        headers: {
          Headers.contentTypeHeader: [ContentType.html.mimeType],
        },
      );
    }
    return _json(200, {
      'Id': serverId,
      'ServerName': serverName,
      'Version': version,
    });
  }

  ResponseBody _handleAuthenticate(String raw) {
    Map<String, dynamic> body = const {};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
    }
    final username = body['Username']?.toString() ?? '';
    final password = body['Pw']?.toString() ?? '';
    FakeEmbyUser? user;
    for (final item in users) {
      if (item.username == username && item.password == password) {
        user = item;
        break;
      }
    }
    if (user == null) {
      return _json(401, {'error': 'invalid credentials'});
    }
    final token = 'token-$serverId-${user.username}-${++_tokenSeq}';
    issuedTokens.add(token);
    return _json(200, {
      'AccessToken': token,
      'ServerId': serverId,
      'User': {'Id': user.userId, 'Name': user.username, 'ServerId': serverId},
    });
  }

  String? _headerValue(RequestOptions options, String name) {
    for (final entry in options.headers.entries) {
      if (entry.key.toString().toLowerCase() == name) {
        final value = entry.value;
        return value?.toString();
      }
    }
    return null;
  }

  String? _tokenOf(RequestOptions options) {
    final headers = options.headers;
    final header =
        headers['X-Emby-Token']?.toString() ??
        headers['x-emby-token']?.toString();
    if (header != null && header.isNotEmpty) {
      return header;
    }
    final authorization =
        headers['X-Emby-Authorization']?.toString() ??
        headers['Authorization']?.toString() ??
        headers['authorization']?.toString() ??
        '';
    return RegExp(r'Token="([^"]+)"').firstMatch(authorization)?.group(1);
  }

  Future<String> _readBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (options.data is String) {
      return options.data as String;
    }
    if (options.data is Map) {
      return jsonEncode(options.data);
    }
    if (requestStream == null) {
      return '';
    }
    final chunks = await requestStream.toList();
    return utf8.decode(chunks.expand((chunk) => chunk).toList());
  }

  ResponseBody _json(int status, Object body) {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

List<FakeEmbyItem> defaultCatalogViews() {
  return [
    FakeEmbyItem(
      id: 'view-movies',
      name: '电影',
      type: 'CollectionFolder',
      collectionType: 'movies',
    ),
    FakeEmbyItem(
      id: 'view-tv',
      name: '剧集',
      type: 'CollectionFolder',
      collectionType: 'tvshows',
    ),
    FakeEmbyItem(
      id: 'view-music',
      name: '音乐',
      type: 'CollectionFolder',
      collectionType: 'music',
    ),
    FakeEmbyItem(
      id: 'view-photos',
      name: '相册',
      type: 'CollectionFolder',
      collectionType: 'photos',
    ),
    FakeEmbyItem(id: 'view-untyped', name: '未分类影视', type: 'CollectionFolder'),
    FakeEmbyItem(id: 'view-mixed', name: '混合媒体', type: 'CollectionFolder'),
  ];
}

List<FakeEmbyItem> defaultCatalogItems() {
  const hour = 10000000 * 60 * 60;
  const minute = 10000000 * 60;
  return [
    FakeEmbyItem(
      id: 'movie-inception',
      name: 'Inception',
      type: 'Movie',
      parentId: 'view-movies',
      overview: 'A thief who steals corporate secrets through dream-sharing.',
      productionYear: 2010,
      runTimeTicks: hour * 2 + minute * 28,
      playbackPositionTicks: minute * 59,
      playedPercentage: 40,
      primaryImageTag: 'tag-inception',
      dateCreated: DateTime.utc(2024, 1, 1),
      communityRating: 8.8,
      chapters: const [
        FakeChapter(name: 'Chapter 1', startPositionTicks: 0),
        FakeChapter(
          name: 'Chapter 2',
          startPositionTicks: 7 * 60 * 10000000,
        ),
      ],
      mediaStreams: const [
        FakeMediaStream(
          index: 0,
          type: 'Video',
          codec: 'h264',
          displayTitle: '1080p',
        ),
        FakeMediaStream(
          index: 1,
          type: 'Audio',
          codec: 'ac3',
          language: 'eng',
          displayTitle: 'English',
          isDefault: true,
          channels: 6,
        ),
        FakeMediaStream(
          index: 2,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'chi',
          displayTitle: '中文',
          isDefault: true,
          isTextSubtitleStream: true,
        ),
      ],
    ),
    FakeEmbyItem(
      id: 'movie-up',
      name: '飞屋环游记',
      type: 'Movie',
      parentId: 'view-movies',
      overview: 'An old man flies his house to Paradise Falls.',
      productionYear: 2009,
      runTimeTicks: minute * 96,
      primaryImageTag: 'tag-up',
      dateCreated: DateTime.utc(2026, 1, 1),
    ),
    FakeEmbyItem(
      id: 'movie-broken',
      name: '封面失败片',
      type: 'Movie',
      parentId: 'view-movies',
      productionYear: 2021,
      primaryImageTag: 'tag-broken',
      dateCreated: DateTime.utc(2025, 6, 1),
    ),
    FakeEmbyItem(
      id: 'movie-transcode',
      name: '需转码片',
      type: 'Movie',
      parentId: 'view-movies',
      productionYear: 2012,
      runTimeTicks: minute * 90,
      forceTranscode: true,
      supportsDirectPlay: false,
      supportsDirectStream: false,
      dateCreated: DateTime.utc(2023, 1, 1),
    ),
    FakeEmbyItem(
      id: 'movie-pgs',
      name: '位图字幕片',
      type: 'Movie',
      parentId: 'view-movies',
      productionYear: 2015,
      runTimeTicks: minute * 80,
      dateCreated: DateTime.utc(2023, 6, 1),
      mediaStreams: const [
        FakeMediaStream(
          index: 0,
          type: 'Video',
          codec: 'hevc',
          displayTitle: '1080p',
        ),
        FakeMediaStream(
          index: 1,
          type: 'Audio',
          codec: 'aac',
          language: 'eng',
          displayTitle: 'English',
          isDefault: true,
        ),
        FakeMediaStream(
          index: 2,
          type: 'Subtitle',
          codec: 'pgssub',
          language: 'chi',
          displayTitle: 'PGS',
          isDefault: true,
          isTextSubtitleStream: false,
        ),
      ],
    ),
    FakeEmbyItem(
      id: 'series-friends',
      name: '老友记',
      type: 'Series',
      parentId: 'view-tv',
      overview: 'Six friends living in New York.',
      productionYear: 1994,
      childCount: 2,
      primaryImageTag: 'tag-friends',
      dateCreated: DateTime.utc(2024, 5, 1),
    ),
    FakeEmbyItem(
      id: 'season-friends-1',
      name: '第 1 季',
      type: 'Season',
      parentId: 'series-friends',
      seriesId: 'series-friends',
      seriesName: '老友记',
      indexNumber: 1,
    ),
    FakeEmbyItem(
      id: 'episode-friends-s1e1',
      name: 'The Pilot',
      type: 'Episode',
      parentId: 'season-friends-1',
      seriesId: 'series-friends',
      seriesName: '老友记',
      seasonId: 'season-friends-1',
      indexNumber: 1,
      parentIndexNumber: 1,
      played: true,
      playedPercentage: 100,
      runTimeTicks: minute * 22,
      dateCreated: DateTime.utc(2024, 5, 2),
    ),
    FakeEmbyItem(
      id: 'episode-friends-s1e2',
      name: 'The One with the Sonogram',
      type: 'Episode',
      parentId: 'season-friends-1',
      seriesId: 'series-friends',
      seriesName: '老友记',
      seasonId: 'season-friends-1',
      indexNumber: 2,
      parentIndexNumber: 1,
      nextUp: true,
      runTimeTicks: minute * 22,
      primaryImageTag: 'tag-e2',
      dateCreated: DateTime.utc(2026, 2, 1),
    ),
    FakeEmbyItem(
      id: 'album-noise',
      name: '噪音专辑',
      type: 'MusicAlbum',
      parentId: 'view-music',
    ),
    FakeEmbyItem(
      id: 'photo-sunset',
      name: '日落',
      type: 'Photo',
      parentId: 'view-photos',
    ),
    FakeEmbyItem(
      id: 'movie-untyped',
      name: '未分类型电影',
      type: 'Movie',
      parentId: 'view-untyped',
      productionYear: 2020,
    ),
    FakeEmbyItem(
      id: 'movie-mixed',
      name: '混合库电影',
      type: 'Movie',
      parentId: 'view-mixed',
    ),
    FakeEmbyItem(
      id: 'album-mixed',
      name: '混合库专辑',
      type: 'MusicAlbum',
      parentId: 'view-mixed',
    ),
  ];
}

class FakeEmbyAdapter implements HttpClientAdapter {
  FakeEmbyAdapter([List<FakeEmbyServer>? servers]) {
    for (final server in servers ?? const <FakeEmbyServer>[]) {
      add(server);
    }
  }

  bool certificateError = false;
  final Map<String, FakeEmbyServer> _servers = {};

  void add(FakeEmbyServer server) {
    _servers[server.baseUrl.authority] = server;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (certificateError) {
      return Future.error(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badCertificate,
          error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
      );
    }
    final server = _servers[options.uri.authority];
    if (server == null) {
      return Future.error(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const SocketException('Connection refused'),
        ),
      );
    }
    final future = server.handle(options, requestStream);
    final timeout = options.receiveTimeout ?? options.connectTimeout;
    if (timeout != null && timeout > Duration.zero) {
      return future.timeout(
        timeout,
        onTimeout: () => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
      );
    }
    return future;
  }

  @override
  void close({bool force = false}) {}
}

Dio dioForFakeEmby(
  FakeEmbyAdapter adapter, {
  Duration timeout = const Duration(seconds: 5),
}) {
  return Dio(
    BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
      headers: const {'Accept': 'application/json'},
    ),
  )..httpClientAdapter = adapter;
}
