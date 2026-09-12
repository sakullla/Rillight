import 'package:dio/dio.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_url.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';

class EmbyClient {
  EmbyClient({
    required this.device,
    Dio? dio,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 15),
    this.onSessionExpired,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: receiveTimeout,
               sendTimeout: connectTimeout,
               headers: const {'Accept': 'application/json'},
             ),
           );

  final EmbyDeviceInfo device;
  final Dio _dio;
  void Function()? onSessionExpired;

  Uri? _baseUrl;
  String? _accessToken;
  String? _userId;
  String? _customUserAgent;

  Uri? get baseUrl => _baseUrl;
  String? get accessToken => _accessToken;
  String? get userId => _userId;
  String get userAgent => resolveUserAgent(_customUserAgent, device);
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
      'Overview,ProductionYear,RunTimeTicks,ChildCount,SeriesInfo,'
      'DateCreated,PremiereDate,CommunityRating,SortName,MediaSources,Chapters';
  static const imageTypes = 'Primary,Backdrop,Thumb';

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
  }) {
    return _getItemList(
      '/Users/${_requireUserId()}/Items/Resume',
      queryParameters: {
        'Limit': '$limit',
        'MediaTypes': 'Video',
        'Fields': itemFields,
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
  }) {
    return _getItemList(
      '/Shows/NextUp',
      queryParameters: {
        'UserId': _requireUserId(),
        'Limit': '$limit',
        'Fields': itemFields,
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
        'Fields': itemFields,
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
    String fields = itemFields,
  }) {
    return _getItemList(
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
  }) {
    return _getItemList(
      '/Items/$itemId/Similar',
      queryParameters: {
        'UserId': _requireUserId(),
        if (limit != null) 'Limit': '$limit',
        'Fields': itemFields,
        'EnableImageTypes': imageTypes,
        'SortBy': ?sortBy,
        'SortOrder': ?sortOrder,
      },
    );
  }

  Future<EmbyItem> getItem(String itemId) async {
    final data = await _request(
      'GET',
      '/Users/${_requireUserId()}/Items/$itemId',
      queryParameters: {'Fields': itemFields, 'EnableImageTypes': imageTypes},
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
  }) async {
    final bitrate = maxStreamingBitrate ?? kMpvMaxStreamingBitrate;
    final data = await postJson(
      '/Items/$itemId/PlaybackInfo',
      queryParameters: {'UserId': _requireUserId()},
      body: {
        'UserId': _requireUserId(),
        'DeviceProfile': mpvDeviceProfile(maxStreamingBitrate: bitrate),
        'MaxStreamingBitrate': bitrate,
        'StartTimeTicks': ?startTimeTicks,
        'AutoOpenLiveStream': true,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
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

  Future<EmbyItem?> getNextEpisode(EmbyItem episode) async {
    if (!episode.isEpisode) {
      return null;
    }
    final seriesId = episode.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return null;
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
    return embyResourceUri(
      _baseUrl!,
      '/Videos/$itemId/$mediaSourceId/Subtitles/$index/Stream.$format',
      _accessToken ?? '',
    );
  }

  Future<List<int>> getPrimaryImage(
    String itemId, {
    String? tag,
    int maxWidth = 280,
  }) {
    return getItemImage(itemId, type: 'Primary', tag: tag, maxWidth: maxWidth);
  }

  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 320,
  }) {
    return _requestBytes(
      '/Items/$itemId/Images/Chapter/$index',
      queryParameters: {
        'maxWidth': '$maxWidth',
        if (tag != null && tag.isNotEmpty) 'tag': tag,
      },
    );
  }

  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int maxWidth = 280,
  }) {
    return _requestBytes(
      '/Items/$itemId/Images/$type',
      queryParameters: {
        'maxWidth': '$maxWidth',
        if (tag != null && tag.isNotEmpty) 'tag': tag,
      },
    );
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _requestJson('GET', path, queryParameters: queryParameters);
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
    final data = await _request('GET', path, queryParameters: queryParameters);
    return parseEmbyItemList(data);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
  }) async {
    final data = await _request(
      method,
      path,
      body: body,
      queryParameters: queryParameters,
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
  }) async {
    if (!hasSession) {
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    final uri = joinEmbyPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: _stringifyQuery(queryParameters));
    try {
      final response = await _dio.requestUri<dynamic>(
        uri,
        data: body,
        options: Options(
          method: method,
          headers: _headers(token: _accessToken, userId: _userId),
        ),
      );
      return _decodeBody(response.data);
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw _mapAuthenticatedFailure(error);
    }
  }

  Future<List<int>> _requestBytes(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    if (!hasSession) {
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    final uri = joinEmbyPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: _stringifyQuery(queryParameters));
    try {
      final response = await _dio.requestUri<dynamic>(
        uri,
        options: Options(
          method: 'GET',
          responseType: ResponseType.bytes,
          headers: _headers(token: _accessToken, userId: _userId),
        ),
      );
      final data = response.data;
      if (data is List<int>) {
        return data;
      }
      throw const EmbyException(EmbyFailureKind.unknown);
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw _mapAuthenticatedFailure(error);
    }
  }

  EmbyException _mapAuthenticatedFailure(DioException error) {
    final mapped = EmbyException.fromDio(error);
    if (mapped.kind == EmbyFailureKind.sessionExpired) {
      onSessionExpired?.call();
    }
    return mapped;
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
