import 'emby_socket.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/player/bif_preview.dart';
import 'package:rillight/emby/emby_playback.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/emby/emby_codec.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/emby/emby_url.dart';
import 'package:rillight/media_server/playback.dart';

/// 图和 JSON 共用一个 Host。Dart 默认不限制每主机连接数；这里显式限制为 16，
/// 为有界图片并发之外的目录/API 请求保留空间。
/// 只改默认 adapter 的 HttpClient,不替换整个 adapter,避免丢掉 Dio 的空闲回收。
const int _maxConnectionsPerHost = 16;

Dio _createEmbyDio({
  required Duration connectTimeout,
  required Duration receiveTimeout,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: connectTimeout,
      headers: const {'Accept': 'application/json'},
    ),
  );
  final adapter = dio.httpClientAdapter;
  if (adapter is IOHttpClientAdapter) {
    adapter.createHttpClient = () {
      return HttpClient()
        // 关掉 Dart 默认的 Dart/x.y，只保留会话里配置的 User-Agent。
        ..userAgent = null
        ..idleTimeout = const Duration(seconds: 3)
        ..maxConnectionsPerHost = _maxConnectionsPerHost;
    };
  }
  return dio;
}

class EmbyClient implements MediaServerClient {
  @override
  MediaServerType get serviceType => MediaServerType.emby;
  @override
  ServiceCapabilities get capabilities => ServiceCapabilities({
    for (final capability in [
      ServiceCapability.passwordLogin,
      ServiceCapability.changePassword,
      ServiceCapability.resume,
      ServiceCapability.nextUp,
      ServiceCapability.latest,
      ServiceCapability.search,
      ServiceCapability.filters,
      ServiceCapability.pagination,
      ServiceCapability.watchedState,
      ServiceCapability.directPlay,
      ServiceCapability.directStream,
      ServiceCapability.transcode,
      ServiceCapability.chapters,
      ServiceCapability.notifications,
    ])
      capability: CapabilityStatus(
        CapabilityAvailability.available,
        reason: 'Emby 协议提供此能力，单次操作仍须检查权限和响应',
      ),
    for (final capability in [
      ServiceCapability.quickConnect,
      ServiceCapability.browserAuthorization,
      ServiceCapability.accountResources,
      ServiceCapability.homeUsers,
    ])
      capability: CapabilityStatus(
        CapabilityAvailability.unsupported,
        reason: 'Emby 密码会话不提供此认证流程',
      ),
  });
  @override
  InteractiveAuthentication? get interactiveAuthentication => null;
  @override
  AccountResourceAuthentication? get accountAuthentication => null;
  final Map<String, PlaybackResourceLease> _resources = {};
  PlaybackResourceLease _resourceLease(
    String sessionId, {
    String? itemId,
    String? mediaSourceId,
  }) {
    final base = baseUrl!, user = userId!, token = accessToken!;
    return _resources.putIfAbsent('$base|$user|$sessionId', () {
      final frozen = EmbyClient(device: device, dio: _dio)
        ..attachSession(
          baseUrl: base,
          accessToken: token,
          userId: user,
          userAgent: userAgent,
        );
      return PlaybackResourceLease(
        id: sessionId,
        itemId: itemId,
        mediaSourceId: mediaSourceId,
        release: () async {
          await frozen._requestJson(
            'DELETE',
            '/Videos/ActiveEncodings',
            queryParameters: {
              'DeviceId': device.deviceId,
              'PlaySessionId': sessionId,
            },
          );
        },
      );
    });
  }

  @override
  Future<void> releasePlayback(PlaybackReport report) async {
    if (report.playMethod != PlayMethod.transcode ||
        report.playSessionId.isEmpty) {
      return;
    }
    await _resourceLease(report.playSessionId).release();
  }

  @override
  Future<MediaPreview?> openPreview(String itemId) async {
    if (!await hasVideoPreviewThumbnails(itemId)) return null;
    final bif = BifPreview.parse(await getVideoPreviewBif(itemId));
    if (bif == null) {
      throw const MediaServerException(
        MediaServerFailureKind.unknown,
        detail: 'Invalid preview index',
      );
    }
    return _EmbyPreview(itemId, bif);
  }

  @override
  CatalogNotifications? watchCatalog({
    required Future<void> Function() onUserDataChanged,
    required Future<void> Function() onLibraryChanged,
  }) => hasSession
      ? EmbySocket(
          baseUrl: baseUrl!,
          apiKey: accessToken!,
          onUserDataChanged: onUserDataChanged,
          onLibraryChanged: onLibraryChanged,
        )
      : null;
  @override
  EmbyClient createDetached() => EmbyClient(device: device);
  @override
  ResolvedPlayback? resolvePlayback({
    required PlaybackInfo info,
    required String itemId,
    String? mediaSourceId,
    bool forceTranscode = false,
  }) {
    final result = resolveEmbyPlayback(
      info: info,
      baseUrl: baseUrl!,
      accessToken: accessToken!,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      forceTranscode: forceTranscode,
    );
    if (result == null) return null;
    final authorization = ResourceAuthorization(
      headersByOrigin: {baseUrl!.origin: sessionHeaders},
      publicHeaders: {'User-Agent': userAgent},
    );
    return ResolvedPlayback(
      playMethod: result.playMethod,
      outputBitrate: result.outputBitrate,
      streamUrl: result.streamUrl,
      playSessionId: result.playSessionId,
      mediaSource: result.mediaSource,
      itemId: result.itemId,
      requiresStrmExpansion: result.requiresStrmExpansion,
      authorization: authorization,
      resources: info.resources,
      timeline: MediaTimeline([
        MediaPart(
          id: result.mediaSource.id,
          duration: result.mediaSource.runtime,
          resource: AuthorizedMediaResource(
            url: result.streamUrl.toString(),
            authorization: authorization,
          ),
        ),
      ]),
    );
  }

  @override
  Uri resolveResource(String resource) =>
      embyResourceUri(baseUrl!, resource, accessToken!);
  EmbyClient({
    required this.device,
    Dio? dio,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 15),
    this.onSessionExpired,
    this.onRefreshSession,
  }) : _dio =
           dio ??
           _createEmbyDio(
             connectTimeout: connectTimeout,
             receiveTimeout: receiveTimeout,
           );

  @override
  final ClientDeviceInfo device;
  final Dio _dio;

  /// Independent request/receipt gate for a consumer's frozen source lease.
  /// Shares the transport, not mutable session credentials or interceptors.
  void Function()? _requestGuard;

  @override
  MediaServerClient withRequestGuard(void Function() guard) {
    final previous = _requestGuard;
    void check() {
      previous?.call();
      guard();
    }

    final dio = Dio(_dio.options.copyWith());
    dio.httpClientAdapter = _dio.httpClientAdapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          try {
            check();
            handler.next(options);
          } catch (error) {
            handler.reject(DioException(requestOptions: options, error: error));
          }
        },
        onResponse: (response, handler) {
          try {
            check();
            handler.next(response);
          } catch (error) {
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                error: error,
              ),
            );
          }
        },
      ),
    );
    final guarded = EmbyClient(device: device, dio: dio)
      .._requestGuard = check
      ..setUserAgent(customUserAgent);
    if (hasSession) {
      guarded.attachSession(
        baseUrl: baseUrl!,
        accessToken: accessToken!,
        userId: userId!,
        userAgent: customUserAgent,
      );
    }
    return guarded;
  }

  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  Future<bool>? _refreshing;

  Uri? _baseUrl;
  String? _accessToken;
  String? _userId;
  String? _customUserAgent;
  int _resourceGeneration = 0;

  @override
  Uri? get baseUrl => _baseUrl;
  @override
  String? get accessToken => _accessToken;
  @override
  String? get userId => _userId;
  @override
  String get userAgent => resolveUserAgent(_customUserAgent, device);
  @override
  String? get customUserAgent => _customUserAgent;
  @override
  bool get hasSession =>
      _baseUrl != null && _accessToken != null && _accessToken!.isNotEmpty;
  @override
  Map<String, String> get sessionHeaders =>
      _headers(token: _accessToken, userId: _userId);

  @override
  void setUserAgent(String? userAgent) {
    _customUserAgent = normalizeUserAgent(userAgent);
  }

  @override
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) {
    _resourceGeneration++;
    _baseUrl = baseUrl;
    _accessToken = accessToken;
    _userId = userId;
    setUserAgent(userAgent);
  }

  @override
  void clearSession() {
    _resourceGeneration++;
    _baseUrl = null;
    _accessToken = null;
    _userId = null;
    _customUserAgent = null;
  }

  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    final uri = joinEmbyApiPath(baseUrl, '/System/Info/Public');
    try {
      final response = await _dio.getUri<dynamic>(
        uri,
        options: Options(headers: _headers()),
      );
      return decodeEmbyPublicServerInfo(
        _asJsonMap(response.data, notEmby: true),
        fallbackName: baseUrl.host,
      );
    } on MediaServerException {
      rethrow;
    } on DioException catch (error) {
      throw _mapPublicInfoFailure(error);
    }
  }

  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async {
    final uri = joinEmbyApiPath(baseUrl, '/Users/AuthenticateByName');
    try {
      final response = await _dio.postUri<dynamic>(
        uri,
        data: {'Username': username, 'Pw': password},
        options: Options(
          headers: {..._headers(), 'Content-Type': 'application/json'},
        ),
      );
      return decodeEmbyAuthenticationResult(
        _asJsonMap(response.data, notEmby: false),
        fallbackServerId: serverId,
      );
    } on MediaServerException {
      rethrow;
    } on DioException catch (error) {
      throw MediaServerException.fromDio(error, authenticating: true);
    }
  }

  @override
  Future<void> logout() async {
    if (!hasSession) {
      return;
    }
    try {
      await postJson('/Sessions/Logout');
    } on MediaServerException catch (error) {
      if (error.kind == MediaServerFailureKind.sessionExpired) {
        return;
      }
      rethrow;
    }
  }

  static const itemFields =
      'Overview,ShortOverview,Taglines,ProductionYear,RunTimeTicks,ChildCount,'
      'SeriesInfo,DateCreated,PremiereDate,CommunityRating,SortName,'
      'MediaSources,Chapters,ImageTags,ProviderIds,UserData';

  /// 海报网格不需要 MediaSources/Chapters,大库带上这两项会把 /Items 拖死。
  /// ImageTags 必须显式要:部分 Emby/Jellyfin 不带这个 Field 时条目有标题没海报 tag,
  /// 网格就会整页灰块。
  static const gridFields =
      'Overview,ShortOverview,Taglines,ProductionYear,RunTimeTicks,ChildCount,'
      'SeriesInfo,DateCreated,PremiereDate,CommunityRating,SortName,ImageTags,'
      'ProviderIds,UserData';

  /// 首页海报行：不要简介和标语，这两项会把每条片库的 /Items 撑大。
  static const homePosterFields =
      'ProductionYear,ChildCount,SeriesInfo,DateCreated,PremiereDate,'
      'CommunityRating,ImageTags,ProviderIds,UserData';
  static const imageTypes = 'Primary,Backdrop,Thumb';
  static const detailImageTypes = 'Primary,Backdrop,Thumb,Chapter';

  /// Latest movie/series rows also feed the home carousel, which draws the
  /// transparent title logo when the server has one.
  static const featuredImageTypes = 'Primary,Backdrop,Thumb,Logo';

  /// `PersonIds` 的查询值。空白 id 去掉；没有有效 id 时返回 null，调用方不带参数。
  static String? personIdsQueryValue(List<String>? personIds) {
    if (personIds == null) return null;
    final ids = [
      for (final id in personIds)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (ids.isEmpty) return null;
    return ids.join(',');
  }

  String _requireUserId() {
    final userId = _userId;
    if (!hasSession || userId == null || userId.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    return userId;
  }

  @override
  Future<List<MediaItem>> getResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  }) async {
    return (await queryResumeItems(
      limit: limit,
      startIndex: startIndex,
      sortBy: sortBy,
      sortOrder: sortOrder,
    )).items;
  }

  @override
  Future<MediaItemPage> queryResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    return _getItemPage(
      '/Users/${_requireUserId()}/Items/Resume',
      queryParameters: {
        'Limit': '$limit',
        'MediaTypes': 'Video',
        'Fields': _projection(fields),
        'EnableImageTypes': imageTypes,
        if (startIndex != null) 'StartIndex': '$startIndex',
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  @override
  Future<List<MediaItem>> getNextUp({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  }) async {
    return (await queryNextUp(
      limit: limit,
      startIndex: startIndex,
      sortBy: sortBy,
      sortOrder: sortOrder,
    )).items;
  }

  @override
  Future<MediaItemPage> queryNextUp({
    String? parentId,
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    return _getItemPage(
      '/Shows/NextUp',
      queryParameters: {
        'ParentId': ?parentId,
        'UserId': _requireUserId(),
        'Limit': '$limit',
        'Fields': _projection(fields),
        'EnableImageTypes': imageTypes,
        if (startIndex != null) 'StartIndex': '$startIndex',
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  @override
  Future<List<MediaItem>> getLatestItems({
    required String includeItemTypes,
    bool groupItems = true,
    int limit = 24,
  }) {
    return _getItemList(
      '/Users/${_requireUserId()}/Items/Latest',
      queryParameters: {
        'IncludeItemTypes': includeItemTypes,
        'GroupItems': '$groupItems',
        'Limit': '$limit',
        'Fields': gridFields,
        'EnableImageTypes': imageTypes,
      },
    );
  }

  @override
  Future<List<MediaItem>> getViews() {
    return _getItemList('/Users/${_requireUserId()}/Views');
  }

  @override
  Future<List<MediaItem>> getItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    List<String>? personIds,
    String fields = MediaServerClient.itemFields,
  }) async {
    return (await queryItems(
      parentId: parentId,
      searchTerm: searchTerm,
      includeItemTypes: includeItemTypes,
      recursive: recursive,
      limit: limit,
      startIndex: startIndex,
      sortBy: sortBy,
      sortOrder: sortOrder,
      filters: filters,
      genres: genres,
      years: years,
      personIds: personIds,
      fields: fields,
    )).items;
  }

  /// 官方筛选参数:[filters] 对应 `Filters`(IsPlayed/IsUnplayed 等已看状态),
  /// [genres] 对应 `Genres`(竖线分隔),[years] 对应 `Years`(逗号分隔)。
  @override
  Future<MediaItemPage> queryItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    List<String>? personIds,
    String fields = MediaServerClient.gridFields,
    String imageTypes = MediaServerClient.imageTypes,
  }) {
    return _getItemPage(
      '/Users/${_requireUserId()}/Items',
      queryParameters: {
        if (parentId != null && parentId.isNotEmpty) 'ParentId': parentId,
        'SearchTerm': ?searchTerm,
        if (includeItemTypes != null && includeItemTypes.isNotEmpty)
          'IncludeItemTypes': includeItemTypes,
        'Recursive': '$recursive',
        if (limit != null) 'Limit': '$limit',
        if (startIndex != null) 'StartIndex': '$startIndex',
        'Fields': _projection(fields),
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
        if (filters != null && filters.isNotEmpty) 'Filters': filters.join(','),
        if (genres != null && genres.isNotEmpty) 'Genres': genres.join('|'),
        if (years != null && years.isNotEmpty) 'Years': years.join(','),
        'PersonIds': ?personIdsQueryValue(personIds),
        'EnableImageTypes': _imageProjection(imageTypes),
      },
    );
  }

  @override
  Future<List<MediaItem>> searchByName(String searchTerm, {int? startIndex}) {
    final term = searchTerm.trim();
    if (term.isEmpty) {
      throw ArgumentError.value(searchTerm, 'searchTerm');
    }
    return getItems(
      searchTerm: term,
      recursive: true,
      includeItemTypes: 'Movie,Series',
      limit: 50,
      startIndex: startIndex,
      sortBy: 'SortName',
      sortOrder: 'Ascending',
    );
  }

  /// Emby exposes library-wide genres separately from a paginated item result.
  /// Never derive the complete filter list from the first 60 posters alone.
  @override
  Future<List<String>> getLibraryGenres(String? parentId) async {
    final names = <String>{};
    var offset = 0;
    while (true) {
      final page = await _getItemPage(
        '/Genres',
        queryParameters: {
          'UserId': _requireUserId(),
          if (parentId != null && parentId.isNotEmpty) 'ParentId': parentId,
          'Recursive': 'true',
          'StartIndex': '$offset',
          'Limit': '200',
          'EnableImages': 'false',
          'EnableUserData': 'false',
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
        },
      );
      final before = names.length;
      names.addAll(
        page.items
            .map((item) => item.name.trim())
            .where((name) => name.isNotEmpty),
      );
      offset += page.items.length;
      if (!page.hasMore(fetched: offset, pageSize: 200) ||
          names.length == before) {
        break;
      }
    }
    return names.toList()..sort();
  }

  @override
  Future<List<MediaItem>> getSimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
  }) async {
    return (await querySimilar(
      itemId,
      limit: limit,
      sortBy: sortBy,
      sortOrder: sortOrder,
    )).items;
  }

  @override
  Future<MediaItemPage> querySimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    return _getItemPage(
      '/Items/$itemId/Similar',
      queryParameters: {
        'UserId': _requireUserId(),
        if (limit != null) 'Limit': '$limit',
        'Fields': _projection(fields),
        'EnableImageTypes': imageTypes,
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  /// 单条目详情。[fields] 覆盖默认 [itemFields];集详情路径传
  /// `'$itemFields,People'` 以取演职员,季列表等高频路径不要带 People
  /// (同 [gridFields] 注释,大字段会拖慢 /Items)。
  @override
  Future<MediaItem> getItem(
    String itemId, {
    String? fields,
    CancelToken? cancelToken,
  }) async {
    final data = await _request(
      'GET',
      '/Users/${_requireUserId()}/Items/$itemId',
      cancelToken: cancelToken,
      queryParameters: {
        'Fields': _projection(fields ?? MediaServerClient.itemFields),
        'EnableImageTypes': detailImageTypes,
      },
    );
    if (data is Map) {
      return decodeEmbyMediaItem(Map<String, dynamic>.from(data));
    }
    throw const MediaServerException(MediaServerFailureKind.unknown);
  }

  @override
  Future<void> markPlayed(String itemId) async {
    await postJson('/Users/${_requireUserId()}/PlayedItems/$itemId');
  }

  @override
  Future<void> markUnplayed(String itemId) async {
    await deleteJson('/Users/${_requireUserId()}/PlayedItems/$itemId');
  }

  /// 从继续观看移除:优先 HideFromResume,旧版 Emby 则清零播放进度。
  ///
  /// Emby/Jellyfin 的 Hide 查询参数缺省为 false,不传则请求成功但条目仍留在 Resume。
  @override
  Future<void> hideFromResume(String itemId) async {
    try {
      await postJson(
        '/Users/${_requireUserId()}/Items/$itemId/HideFromResume',
        queryParameters: const {'Hide': 'true'},
      );
    } on MediaServerException {
      await postJson(
        '/Users/${_requireUserId()}/Items/$itemId/UserData',
        body: {
          'PlaybackPositionTicks': 0,
          'PlayedPercentage': 0,
          'Played': false,
          'HideFromResume': true,
        },
      );
    }
  }

  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    final data = await getJson(
      '/Users/${_requireUserId()}',
      cancelToken: cancelToken,
    );
    return decodeEmbyMediaUser(data);
  }

  /// 当前登录用户可见的库规模统计。失败/无权限按 [MediaServerException] 抛出,
  /// 由调用方决定留在原界面并展示原因。
  @override
  Future<LibraryCounts> getItemCounts() async {
    final data = await getJson('/Items/Counts');
    return decodeEmbyLibraryCounts(data);
  }

  /// 修改当前登录用户的密码。旧密码可留空照常提交,是否要求由服务器裁决。
  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    await postJson(
      '/Users/${_requireUserId()}/Password',
      body: {
        'Id': _requireUserId(),
        'CurrentPw': ?currentPassword,
        'NewPw': newPassword,
      },
    );
  }

  @override
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    int? maxStreamingBitrate,
    Duration? startPosition,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? mediaSourceId,
    PlaybackCapabilities? capabilities,
    bool forceTranscode = false,
  }) async {
    final bitrate =
        capabilities?.maxStreamingBitrate ??
        maxStreamingBitrate ??
        kCoreMaxStreamingBitrate;
    final data = await postJson(
      '/Items/$itemId/PlaybackInfo',
      queryParameters: {'UserId': _requireUserId()},
      body: {
        'UserId': _requireUserId(),
        'DeviceProfile': capabilities != null
            ? encodeEmbyDeviceProfile(capabilities)
            : ownedCoreDeviceProfile(
                h264: true,
                aac: true,
                maxStreamingBitrate: bitrate,
              ),
        'MaxStreamingBitrate': bitrate,
        if (startPosition != null)
          'StartTimeTicks': startPosition.inMicroseconds * 10,
        'AutoOpenLiveStream': true,
        'EnableDirectPlay': !forceTranscode,
        'EnableDirectStream': !forceTranscode,
        'EnableTranscoding': true,
        'AudioStreamIndex': ?audioStreamIndex,
        'SubtitleStreamIndex': ?subtitleStreamIndex,
        'MediaSourceId': ?mediaSourceId,
      },
    );
    final info = decodeEmbyPlaybackInfo(data);
    return PlaybackInfo(
      playSessionId: info.playSessionId,
      mediaSources: info.mediaSources,
      resources: info.playSessionId.isEmpty
          ? null
          : _resourceLease(
              info.playSessionId,
              itemId: itemId,
              mediaSourceId: mediaSourceId ?? info.primarySource?.id,
            ),
    );
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) {
    return postJson(
      '/Sessions/Playing',
      body: encodeEmbyPlaybackReport(report),
    );
  }

  @override
  Future<void> reportProgress(PlaybackReport report) {
    return postJson(
      '/Sessions/Playing/Progress',
      body: encodeEmbyPlaybackReport(report),
    );
  }

  @override
  Future<void> reportStopped(PlaybackReport report) {
    return postJson(
      '/Sessions/Playing/Stopped',
      body: encodeEmbyPlaybackReport(report),
    );
  }

  /// 同一季里紧邻的一集。只取一小页，避免为了上一集/下一集拉整季。
  Future<MediaItem?> _adjacentEpisode(
    MediaItem episode, {
    required bool after,
  }) async {
    final seasonId = episode.seasonId ?? episode.parentId;
    final number = episode.indexNumber;
    if (seasonId == null || seasonId.isEmpty || number == null) {
      return null;
    }
    final start = number > 1 ? number - 2 : 0;
    final page = await queryItems(
      parentId: seasonId,
      includeItemTypes: 'Episode',
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
      startIndex: start,
      limit: 5,
      fields: itemFields,
    );
    MediaItem? neighbor;
    for (final candidate in page.items) {
      final candidateNumber = candidate.indexNumber;
      if (candidate.id == episode.id || candidateNumber == null) {
        continue;
      }
      final matches = after
          ? candidateNumber > number
          : candidateNumber < number;
      if (!matches) {
        continue;
      }
      if (neighbor == null) {
        neighbor = candidate;
        continue;
      }
      final neighborNumber = neighbor.indexNumber ?? 0;
      final closer = after
          ? candidateNumber < neighborNumber
          : candidateNumber > neighborNumber;
      if (closer) {
        neighbor = candidate;
      }
    }
    return neighbor;
  }

  @override
  Future<MediaItem?> getPreviousEpisode(MediaItem episode) async {
    if (!episode.isEpisode) {
      return null;
    }
    return _adjacentEpisode(episode, after: false);
  }

  @override
  Future<MediaItem?> getNextEpisode(MediaItem episode) async {
    if (!episode.isEpisode) {
      return null;
    }
    final seriesId = episode.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return null;
    }
    final nearby = await _adjacentEpisode(episode, after: true);
    if (nearby != null) {
      return nearby;
    }
    final episodes = await getItems(
      parentId: seriesId,
      includeItemTypes: 'Episode',
      recursive: true,
    );
    episodes.sort((a, b) {
      final season = (a.parentIndexNumber ?? 0).compareTo(
        b.parentIndexNumber ?? 0,
      );
      if (season != 0) {
        return season;
      }
      return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
    });
    final index = episodes.indexWhere((item) => item.id == episode.id);
    if (index < 0 || index + 1 >= episodes.length) {
      return null;
    }
    return episodes[index + 1];
  }

  @override
  Uri subtitleStreamUrl({
    required String itemId,
    required String mediaSourceId,
    required int index,
    String format = 'srt',
  }) {
    // StartPositionTicks 用 0,与 Emby 播放器同一条提取地址。
    return embyResourceUri(
      _baseUrl!,
      '/Videos/$itemId/$mediaSourceId/Subtitles/$index/0/Stream.$format',
      _accessToken ?? '',
    );
  }

  /// 整文件下载。字幕提取不走播放代理,避免 Range 和短超时把转换请求掐掉。
  /// 请求头用 [sessionHeaders],其中 User-Agent 是该服务器级配置的值;
  /// 跨域跳转后仍携带同一 User-Agent,但不再携带会话鉴权头。
  /// 服务器第一次提取会跑 ffmpeg,失败后缓存往往已就绪,因此超时和 5xx 再试。
  @override
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
    int? maxBytes,
    CancelToken? cancelToken,
  }) async {
    if (!hasSession) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    Object? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await _withAuthRetry(() async {
          final generation = _resourceGeneration;
          void checkCurrent() {
            if (generation != _resourceGeneration || !hasSession) {
              throw const MediaServerException(
                MediaServerFailureKind.cancelled,
              );
            }
          }

          final origin = _baseUrl!;
          final authorizedHeaders = sessionHeaders;
          final authorization = ResourceAuthorization(
            headersByOrigin: {origin.origin: authorizedHeaders},
          );
          var target = uri;
          for (var redirects = 0; redirects <= 5; redirects++) {
            checkCurrent();
            final sameOrigin = target.origin == origin.origin;
            target = authorization.sanitizeUri(target);
            if (!{'http', 'https'}.contains(target.scheme) ||
                target.userInfo.isNotEmpty) {
              throw StateError('Unsupported subtitle URL');
            }
            final headers = {
              if (sameOrigin) ...authorizedHeaders,
              'User-Agent': userAgent,
              'Accept': '*/*',
            };
            final options = Options(
              method: 'GET',
              responseType: maxBytes == null
                  ? ResponseType.bytes
                  : ResponseType.stream,
              receiveTimeout: receiveTimeout,
              followRedirects: false,
              validateStatus: (status) =>
                  status != null &&
                  ((status >= 200 && status < 300) ||
                      {301, 302, 303, 307, 308}.contains(status)),
              headers: headers,
            );
            if (maxBytes == null) {
              final response = await _dio.requestUri<List<int>>(
                target,
                options: options,
                cancelToken: cancelToken,
              );
              checkCurrent();
              if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
                final location = response.headers.value('location');
                if (location == null) {
                  throw StateError('Subtitle redirect has no destination');
                }
                final next = target.resolve(location);
                if (target.scheme == 'https' && next.scheme != 'https') {
                  throw StateError('Insecure subtitle redirect');
                }
                target = next;
                continue;
              }
              final data = response.data;
              if (data == null || data.isEmpty) {
                throw StateError('Empty response');
              }
              return data;
            }
            if (cancelToken?.isCancelled == true) {
              throw cancelToken!.cancelError!;
            }
            final transferCancel = CancelToken();
            cancelToken?.whenCancel.then(transferCancel.cancel);
            final response = await _dio.requestUri<ResponseBody>(
              target,
              cancelToken: transferCancel,
              options: options,
            );
            try {
              checkCurrent();
            } catch (_) {
              transferCancel.cancel();
              rethrow;
            }
            if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
              transferCancel.cancel();
              final location = response.headers.value('location');
              if (location == null) {
                throw StateError('Subtitle redirect has no destination');
              }
              final next = target.resolve(location);
              if (target.scheme == 'https' && next.scheme != 'https') {
                throw StateError('Insecure subtitle redirect');
              }
              target = next;
              continue;
            }
            final body = response.data;
            if (body == null) {
              transferCancel.cancel();
              throw StateError('Empty response');
            }
            final bytes = BytesBuilder(copy: false);
            try {
              await for (final chunk in body.stream) {
                checkCurrent();
                final room = maxBytes - bytes.length;
                if (room <= 0) break;
                if (chunk.length > room) {
                  bytes.add(chunk.sublist(0, room));
                  break;
                }
                bytes.add(chunk);
              }
            } finally {
              if (!transferCancel.isCancelled) {
                transferCancel.cancel();
              }
            }
            final data = bytes.takeBytes();
            checkCurrent();
            if (data.isEmpty) {
              throw StateError('Empty response');
            }
            return data;
          }
          throw StateError('Too many subtitle redirects');
        });
      } on MediaServerException catch (error) {
        last = error;
        final retry =
            error.kind == MediaServerFailureKind.timeout ||
            (error.statusCode != null && error.statusCode! >= 500);
        if (!retry || attempt == attempts - 1) {
          rethrow;
        }
      }
    }
    throw last ?? StateError('Unread response');
  }

  @override
  Future<List<int>> getPrimaryImage(
    String itemId, {
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) {
    return getItemImage(
      itemId,
      type: 'Primary',
      tag: tag,
      maxWidth: maxWidth,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _requestBytes(
        '/Items/$itemId/Images/Chapter/$index',
        queryParameters: {
          'maxWidth': '$maxWidth',
          if (tag != null && tag.isNotEmpty) 'tag': tag,
        },
        cancelToken: cancelToken,
      );
    } catch (_) {
      if (tag == null || tag.isEmpty) {
        rethrow;
      }
      return _requestBytes(
        '/Items/$itemId/Images/Chapter/$index',
        queryParameters: {'maxWidth': '$maxWidth'},
        cancelToken: cancelToken,
      );
    }
  }

  Future<bool> hasVideoPreviewThumbnails(
    String itemId, {
    CancelToken? cancelToken,
  }) async {
    final data = await _requestJson(
      'GET',
      '/Items/$itemId/ThumbnailSet',
      queryParameters: {'Width': '160'},
      cancelToken: cancelToken,
    );
    return data['Thumbnails'] is List &&
        (data['Thumbnails'] as List).isNotEmpty;
  }

  /// BIF previews are optional and bounded; never buffer a large response before
  /// checking its size. Requests use the saved session headers and UA.
  Future<Uint8List> getVideoPreviewBif(
    String itemId, {
    CancelToken? cancelToken,
  }) async {
    if (!hasSession) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    final uri = joinEmbyApiPath(
      _baseUrl!,
      '/Videos/$itemId/index.bif',
    ).replace(queryParameters: {'Width': '160'});
    const limit = 32 * 1024 * 1024;
    final bytes = await readAuthorizedBytes(
      uri,
      cancelToken: cancelToken,
      attempts: 1,
      maxBytes: limit + 1,
    );
    if (bytes.length > limit) {
      throw const FormatException('Preview data exceeds memory limit');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int? index,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) {
    final path = index == null
        ? '/Items/$itemId/Images/$type'
        : '/Items/$itemId/Images/$type/$index';
    return _requestBytes(
      path,
      queryParameters: {
        'maxWidth': '$maxWidth',
        if (tag != null && tag.isNotEmpty) 'tag': tag,
      },
      cancelToken: cancelToken,
    );
  }

  @override
  Future<List<int>> getOriginalItemImage(
    String itemId, {
    String type = 'Backdrop',
    String? tag,
    int? index,
    CancelToken? cancelToken,
  }) => _requestBytes(
    index == null
        ? '/Items/$itemId/Images/$type'
        : '/Items/$itemId/Images/$type/$index',
    queryParameters: {if (tag != null && tag.isNotEmpty) 'tag': tag},
    cancelToken: cancelToken,
  );

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) {
    return _requestJson(
      'GET',
      path,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
    );
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
  }) {
    return _requestJson(
      'POST',
      path,
      body: body,
      queryParameters: queryParameters,
    );
  }

  Future<Map<String, dynamic>> deleteJson(String path) {
    return _requestJson('DELETE', path);
  }

  Future<List<MediaItem>> _getItemList(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    return (await _getItemPage(path, queryParameters: queryParameters)).items;
  }

  Future<MediaItemPage> _getItemPage(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final data = await _request('GET', path, queryParameters: queryParameters);
    return MediaItemPage(
      items: parseEmbyItemList(data),
      totalRecordCount: parseEmbyTotalCount(data),
      offset: int.tryParse('${queryParameters?['StartIndex']}') ?? 0,
      pagination: const CapabilityStatus(
        CapabilityAvailability.available,
        reason: 'Emby 目录支持偏移分页',
      ),
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    final data = await _request(
      method,
      path,
      body: body,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
    );
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    if (data == null) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{'value': data};
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    if (!hasSession) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    final uri = joinEmbyApiPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: _stringifyQuery(queryParameters));
    return _withAuthRetry(() async {
      final response = await _dio.requestUri<dynamic>(
        uri,
        data: body,
        options: Options(
          method: method,
          headers: _headers(token: _accessToken, userId: _userId),
        ),
        cancelToken: cancelToken,
      );
      return _decodeBody(response.data);
    });
  }

  Future<List<int>> _requestBytes(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    if (!hasSession) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    final uri = joinEmbyApiPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: _stringifyQuery(queryParameters));
    return readAuthorizedBytes(
      uri,
      cancelToken: cancelToken,
      attempts: 1,
      receiveTimeout:
          _dio.options.receiveTimeout ?? const Duration(seconds: 15),
    );
  }

  Future<T> _withAuthRetry<T>(Future<T> Function() send) async {
    final expired = onSessionExpired;
    final refresh = onRefreshSession;
    try {
      return await send();
    } on MediaServerException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw MediaServerException.fromDio(error);
      }
      final mapped = MediaServerException.fromDio(error);
      if (mapped.kind != MediaServerFailureKind.sessionExpired) {
        throw mapped;
      }
      // A selected Emby client can be reattached while this request is in
      // flight. Never borrow the callbacks installed for its later session.
      if (!identical(expired, onSessionExpired) ||
          !identical(refresh, onRefreshSession)) {
        throw const MediaServerException(MediaServerFailureKind.cancelled);
      }
      if (!await _refreshIfExpired()) {
        expired?.call();
        throw mapped;
      }
      final retryExpired = onSessionExpired;
      try {
        return await send();
      } on MediaServerException {
        rethrow;
      } on DioException catch (retryError) {
        final retryMapped = MediaServerException.fromDio(retryError);
        if (retryMapped.kind == MediaServerFailureKind.sessionExpired) {
          if (identical(retryExpired, onSessionExpired)) retryExpired?.call();
        }
        throw retryMapped;
      }
    }
  }

  Future<bool> _refreshIfExpired() async {
    final inflight = _refreshing;
    if (inflight != null) {
      return inflight;
    }
    final hook = onRefreshSession;
    if (hook == null) {
      return false;
    }
    final pending = hook();
    _refreshing = pending;
    try {
      return await pending;
    } finally {
      if (identical(_refreshing, pending)) {
        _refreshing = null;
      }
    }
  }

  Map<String, String>? _stringifyQuery(Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) {
      return null;
    }
    return {
      for (final entry in query.entries)
        if (entry.value != null) entry.key: '${entry.value}',
    };
  }

  dynamic _decodeBody(dynamic data) {
    if (data == null || (data is String && data.isEmpty)) {
      return <String, dynamic>{};
    }
    if (data is Map) {
      return _asJsonMap(data, notEmby: false);
    }
    if (data is List) {
      return data;
    }
    return data;
  }

  Map<String, String> _headers({String? token, String? userId}) {
    final authorization = embyAuthorizationHeader(
      device,
      userId: userId,
      token: token,
    );
    return {
      'Authorization': authorization,
      'X-Emby-Authorization': authorization,
      'User-Agent': userAgent,
      if (token != null && token.isNotEmpty) 'X-Emby-Token': token,
    };
  }

  Map<String, dynamic> _asJsonMap(dynamic data, {required bool notEmby}) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw MediaServerException(
      notEmby
          ? MediaServerFailureKind.incompatibleServer
          : MediaServerFailureKind.unknown,
    );
  }

  MediaServerException _mapPublicInfoFailure(DioException error) {
    final mapped = MediaServerException.fromDio(error);
    if (mapped.kind == MediaServerFailureKind.timeout ||
        mapped.kind == MediaServerFailureKind.certificate ||
        mapped.kind == MediaServerFailureKind.unreachable) {
      return mapped;
    }
    if (mapped.detail != null && mapped.detail!.trim().isNotEmpty) {
      return mapped;
    }
    if (error.response != null) {
      return MediaServerException(
        MediaServerFailureKind.incompatibleServer,
        statusCode: error.response?.statusCode,
        detail: mapped.detail,
        cause: error,
      );
    }
    return mapped;
  }
}

class _EmbyPreview implements MediaPreview {
  _EmbyPreview(this.itemId, this._bif);
  @override
  final String itemId;
  BifPreview? _bif;
  @override
  CapabilityStatus get availability => const CapabilityStatus(
    CapabilityAvailability.available,
    reason: '服务返回经过校验的 BIF 索引',
  );
  @override
  Future<PreviewFrame?> frameAt(Duration position) async {
    final bif = _bif;
    return bif == null ? null : PreviewFrame(bytes: bif.imageAt(position));
  }

  @override
  Future<void> close() async {
    _bif = null;
  }
}

String _projection(String projection) => switch (projection) {
  MediaServerClient.itemFields => EmbyClient.itemFields,
  MediaServerClient.gridFields => EmbyClient.gridFields,
  MediaServerClient.homePosterFields => EmbyClient.homePosterFields,
  MediaServerClient.detailWithPeople => '${EmbyClient.itemFields},People',
  // Explicit adapter inputs are used only by protocol regression fixtures.
  EmbyClient.itemFields ||
  EmbyClient.gridFields ||
  EmbyClient.homePosterFields => projection,
  _ when projection == '${EmbyClient.itemFields},People' => projection,
  _ => throw ArgumentError.value(projection, 'projection'),
};
String _imageProjection(String projection) => switch (projection) {
  MediaServerClient.imageTypes => EmbyClient.imageTypes,
  MediaServerClient.detailImageTypes => EmbyClient.detailImageTypes,
  MediaServerClient.featuredImageTypes => EmbyClient.featuredImageTypes,
  _ => throw ArgumentError.value(projection, 'imageProjection'),
};
