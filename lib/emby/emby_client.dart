import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_url.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';

/// 图和 JSON 共用一个 Host。Dart 默认每主机 6 条连接,网格一滑就排队超时。
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

class EmbyClient {
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

  final EmbyDeviceInfo device;
  final Dio _dio;
  void Function()? onSessionExpired;
  Future<bool> Function()? onRefreshSession;
  Future<bool>? _refreshing;

  Uri? _baseUrl;
  String? _accessToken;
  String? _userId;
  String? _customUserAgent;

  Uri? get baseUrl => _baseUrl;
  String? get accessToken => _accessToken;
  String? get userId => _userId;
  String get userAgent => resolveUserAgent(_customUserAgent, device);
  String? get customUserAgent => _customUserAgent;
  bool get hasSession =>
      _baseUrl != null && _accessToken != null && _accessToken!.isNotEmpty;
  Map<String, String> get sessionHeaders =>
      _headers(token: _accessToken, userId: _userId);

  void setUserAgent(String? userAgent) {
    _customUserAgent = normalizeUserAgent(userAgent);
  }

  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) {
    _baseUrl = baseUrl;
    _accessToken = accessToken;
    _userId = userId;
    setUserAgent(userAgent);
  }

  void clearSession() {
    _baseUrl = null;
    _accessToken = null;
    _userId = null;
    _customUserAgent = null;
  }

  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    final uri = joinEmbyPath(baseUrl, '/System/Info/Public');
    try {
      final response = await _dio.getUri<dynamic>(
        uri,
        options: Options(headers: _headers()),
      );
      return PublicServerInfo.fromJson(
        _asJsonMap(response.data, notEmby: true),
        fallbackName: baseUrl.host,
      );
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw _mapPublicInfoFailure(error);
    }
  }

  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async {
    final uri = joinEmbyPath(baseUrl, '/Users/AuthenticateByName');
    try {
      final response = await _dio.postUri<dynamic>(
        uri,
        data: {'Username': username, 'Pw': password},
        options: Options(
          headers: {..._headers(), 'Content-Type': 'application/json'},
        ),
      );
      return AuthenticationResult.fromJson(
        _asJsonMap(response.data, notEmby: false),
        fallbackServerId: serverId,
      );
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw EmbyException.fromDio(error, authenticating: true);
    }
  }

  Future<void> logout() async {
    if (!hasSession) {
      return;
    }
    try {
      await postJson('/Sessions/Logout');
    } on EmbyException catch (error) {
      if (error.kind == EmbyFailureKind.sessionExpired) {
        return;
      }
      rethrow;
    }
  }

  static const itemFields =
      'Overview,ShortOverview,Taglines,ProductionYear,RunTimeTicks,ChildCount,'
      'SeriesInfo,DateCreated,PremiereDate,CommunityRating,SortName,'
      'MediaSources,Chapters,ImageTags';

  /// 海报网格不需要 MediaSources/Chapters,大库带上这两项会把 /Items 拖死。
  /// ImageTags 必须显式要:部分 Emby/Jellyfin 不带这个 Field 时条目有标题没海报 tag,
  /// 网格就会整页灰块。
  static const gridFields =
      'Overview,ShortOverview,Taglines,ProductionYear,RunTimeTicks,ChildCount,'
      'SeriesInfo,DateCreated,PremiereDate,CommunityRating,SortName,ImageTags';

  /// 首页海报行：不要简介和标语，这两项会把每条片库的 /Items 撑大。
  static const homePosterFields =
      'ProductionYear,ChildCount,SeriesInfo,DateCreated,PremiereDate,'
      'CommunityRating,ImageTags';
  static const imageTypes = 'Primary,Backdrop,Thumb';
  static const detailImageTypes = 'Primary,Backdrop,Thumb,Chapter';

  String _requireUserId() {
    final userId = _userId;
    if (!hasSession || userId == null || userId.isEmpty) {
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    return userId;
  }

  Future<List<EmbyItem>> getResumeItems({
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

  Future<EmbyItemPage> queryResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = gridFields,
  }) {
    return _getItemPage(
      '/Users/${_requireUserId()}/Items/Resume',
      queryParameters: {
        'Limit': '$limit',
        'MediaTypes': 'Video',
        'Fields': fields,
        'EnableImageTypes': imageTypes,
        if (startIndex != null) 'StartIndex': '$startIndex',
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  Future<List<EmbyItem>> getNextUp({
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

  Future<EmbyItemPage> queryNextUp({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = gridFields,
  }) {
    return _getItemPage(
      '/Shows/NextUp',
      queryParameters: {
        'UserId': _requireUserId(),
        'Limit': '$limit',
        'Fields': fields,
        'EnableImageTypes': imageTypes,
        if (startIndex != null) 'StartIndex': '$startIndex',
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  Future<List<EmbyItem>> getLatestItems({
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

  Future<List<EmbyItem>> getViews() {
    return _getItemList('/Users/${_requireUserId()}/Views');
  }

  Future<List<EmbyItem>> getItems({
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
    String fields = itemFields,
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
      fields: fields,
    )).items;
  }

  /// 官方筛选参数:[filters] 对应 `Filters`(IsPlayed/IsUnplayed 等已看状态),
  /// [genres] 对应 `Genres`,[years] 对应 `Years`,均支持逗号分隔多值。
  Future<EmbyItemPage> queryItems({
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
    String fields = gridFields,
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
        'Fields': fields,
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
        if (filters != null && filters.isNotEmpty) 'Filters': filters.join(','),
        if (genres != null && genres.isNotEmpty) 'Genres': genres.join(','),
        if (years != null && years.isNotEmpty) 'Years': years.join(','),
        'EnableImageTypes': imageTypes,
      },
    );
  }

  Future<List<EmbyItem>> searchByName(String searchTerm, {int? startIndex}) {
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

  Future<List<EmbyItem>> getSimilar(
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

  Future<EmbyItemPage> querySimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
    String fields = gridFields,
  }) {
    return _getItemPage(
      '/Items/$itemId/Similar',
      queryParameters: {
        'UserId': _requireUserId(),
        if (limit != null) 'Limit': '$limit',
        'Fields': fields,
        'EnableImageTypes': imageTypes,
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  /// 单条目详情。[fields] 覆盖默认 [itemFields];集详情路径传
  /// `'$itemFields,People'` 以取演职员,季列表等高频路径不要带 People
  /// (同 [gridFields] 注释,大字段会拖慢 /Items)。
  Future<EmbyItem> getItem(String itemId, {String? fields}) async {
    final data = await _request(
      'GET',
      '/Users/${_requireUserId()}/Items/$itemId',
      queryParameters: {
        'Fields': fields ?? itemFields,
        'EnableImageTypes': detailImageTypes,
      },
    );
    if (data is Map) {
      return EmbyItem.fromJson(Map<String, dynamic>.from(data));
    }
    throw const EmbyException(EmbyFailureKind.unknown);
  }

  Future<void> markPlayed(String itemId) async {
    await postJson('/Users/${_requireUserId()}/PlayedItems/$itemId');
  }

  Future<void> markUnplayed(String itemId) async {
    await deleteJson('/Users/${_requireUserId()}/PlayedItems/$itemId');
  }

  /// 从继续观看移除:优先 HideFromResume,旧版 Emby 则清零播放进度。
  ///
  /// Emby/Jellyfin 的 Hide 查询参数缺省为 false,不传则请求成功但条目仍留在 Resume。
  Future<void> hideFromResume(String itemId) async {
    try {
      await postJson(
        '/Users/${_requireUserId()}/Items/$itemId/HideFromResume',
        queryParameters: const {'Hide': 'true'},
      );
    } on EmbyException {
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

  Future<EmbyUser> getUser() async {
    final data = await getJson('/Users/${_requireUserId()}');
    return EmbyUser.fromJson(data);
  }

  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    int? maxStreamingBitrate,
    int? startTimeTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? mediaSourceId,
    Map<String, dynamic>? deviceProfile,
    bool forceTranscode = false,
  }) async {
    final bitrate =
        deviceProfile?['MaxStreamingBitrate'] as int? ??
        maxStreamingBitrate ??
        kMpvMaxStreamingBitrate;
    final data = await postJson(
      '/Items/$itemId/PlaybackInfo',
      queryParameters: {'UserId': _requireUserId()},
      body: {
        'UserId': _requireUserId(),
        'DeviceProfile':
            deviceProfile ?? mpvDeviceProfile(maxStreamingBitrate: bitrate),
        'MaxStreamingBitrate': bitrate,
        'StartTimeTicks': ?startTimeTicks,
        'AutoOpenLiveStream': true,
        'EnableDirectPlay': !forceTranscode,
        'EnableDirectStream': !forceTranscode,
        'EnableTranscoding': true,
        'AudioStreamIndex': ?audioStreamIndex,
        'SubtitleStreamIndex': ?subtitleStreamIndex,
        'MediaSourceId': ?mediaSourceId,
      },
    );
    return PlaybackInfo.fromJson(data);
  }

  Future<void> reportPlaying(PlaybackReport report) {
    return postJson('/Sessions/Playing', body: report.toJson());
  }

  Future<void> reportProgress(PlaybackReport report) {
    return postJson('/Sessions/Playing/Progress', body: report.toJson());
  }

  Future<void> reportStopped(PlaybackReport report) {
    return postJson('/Sessions/Playing/Stopped', body: report.toJson());
  }

  /// 同一季里紧邻的一集。只取一小页，避免为了上一集/下一集拉整季。
  Future<EmbyItem?> _adjacentEpisode(
    EmbyItem episode, {
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
    EmbyItem? neighbor;
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

  Future<EmbyItem?> getPreviousEpisode(EmbyItem episode) async {
    if (!episode.isEpisode) {
      return null;
    }
    return _adjacentEpisode(episode, after: false);
  }

  Future<EmbyItem?> getNextEpisode(EmbyItem episode) async {
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
  /// 请求头用 [sessionHeaders],其中 User-Agent 是这条服务器线路上配置的值。
  /// 服务器第一次提取会跑 ffmpeg,失败后缓存往往已就绪,因此超时和 5xx 再试。
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
  }) async {
    if (!hasSession) {
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    Object? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await _withAuthRetry(() async {
          final origin = _baseUrl!;
          final token = _accessToken!;
          final authorizedHeaders = sessionHeaders;
          var target = uri;
          for (var redirects = 0; redirects <= 5; redirects++) {
            final sameOrigin = target.origin == origin.origin;
            if (!sameOrigin) {
              target = target.replace(
                queryParameters: {
                  for (final entry in target.queryParameters.entries)
                    if (!{
                          'api_key',
                          'apikey',
                          'access_token',
                          'x-emby-token',
                        }.contains(entry.key.toLowerCase()) &&
                        !entry.value.contains(token))
                      entry.key: entry.value,
                },
              );
            }
            if (!{'http', 'https'}.contains(target.scheme) ||
                target.userInfo.isNotEmpty) {
              throw StateError('Unsupported subtitle URL');
            }
            final response = await _dio.requestUri<List<int>>(
              target,
              options: Options(
                method: 'GET',
                responseType: ResponseType.bytes,
                receiveTimeout: receiveTimeout,
                followRedirects: false,
                validateStatus: (status) =>
                    status != null &&
                    ((status >= 200 && status < 300) ||
                        {301, 302, 303, 307, 308}.contains(status)),
                headers: {
                  if (sameOrigin) ...authorizedHeaders,
                  'Accept': '*/*',
                },
              ),
            );
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
          throw StateError('Too many subtitle redirects');
        });
      } on EmbyException catch (error) {
        last = error;
        final retry =
            error.kind == EmbyFailureKind.timeout ||
            (error.statusCode != null && error.statusCode! >= 500);
        if (!retry || attempt == attempts - 1) {
          rethrow;
        }
      }
    }
    throw last ?? StateError('Unread response');
  }

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

  Future<List<EmbyItem>> _getItemList(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    return (await _getItemPage(path, queryParameters: queryParameters)).items;
  }

  Future<EmbyItemPage> _getItemPage(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final data = await _request('GET', path, queryParameters: queryParameters);
    return EmbyItemPage(
      items: parseEmbyItemList(data),
      totalRecordCount: parseEmbyTotalCount(data),
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
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    final uri = joinEmbyPath(
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
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    final uri = joinEmbyPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: _stringifyQuery(queryParameters));
    return _withAuthRetry(() async {
      final response = await _dio.requestUri<dynamic>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          method: 'GET',
          responseType: ResponseType.bytes,
          headers: {
            ..._headers(token: _accessToken, userId: _userId),
            'Accept': '*/*',
          },
        ),
      );
      final data = response.data;
      if (data is List<int>) {
        return data;
      }
      throw const EmbyException(EmbyFailureKind.unknown);
    });
  }

  Future<T> _withAuthRetry<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw EmbyException.fromDio(error);
      }
      final mapped = EmbyException.fromDio(error);
      if (mapped.kind != EmbyFailureKind.sessionExpired) {
        throw mapped;
      }
      if (!await _refreshIfExpired()) {
        onSessionExpired?.call();
        throw mapped;
      }
      try {
        return await send();
      } on EmbyException {
        rethrow;
      } on DioException catch (retryError) {
        final retryMapped = EmbyException.fromDio(retryError);
        if (retryMapped.kind == EmbyFailureKind.sessionExpired) {
          onSessionExpired?.call();
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
    final authorization = device.authorizationHeader(
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
    throw EmbyException(
      notEmby ? EmbyFailureKind.notEmby : EmbyFailureKind.unknown,
    );
  }

  EmbyException _mapPublicInfoFailure(DioException error) {
    final mapped = EmbyException.fromDio(error);
    if (mapped.kind == EmbyFailureKind.timeout ||
        mapped.kind == EmbyFailureKind.certificate ||
        mapped.kind == EmbyFailureKind.unreachable) {
      return mapped;
    }
    if (mapped.detail != null && mapped.detail!.trim().isNotEmpty) {
      return mapped;
    }
    if (error.response != null) {
      return EmbyException(
        EmbyFailureKind.notEmby,
        statusCode: error.response?.statusCode,
        detail: mapped.detail,
        cause: error,
      );
    }
    return mapped;
  }
}
