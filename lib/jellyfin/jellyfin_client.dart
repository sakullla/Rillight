import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/resources.dart';

import 'jellyfin_codec.dart';
part 'jellyfin_auth.dart';
part 'jellyfin_preview.dart';
part 'jellyfin_playback_handle.dart';

const _available = CapabilityStatus(
  CapabilityAvailability.available,
  reason: 'Jellyfin 协议支持',
);
const _detailFields =
    'Overview,Genres,People,MediaSources,Chapters,ProviderIds,DateCreated,ParentId';

/// List and source search. MediaSources and Chapters make /Items stall.
const _gridFields =
    'Overview,Genres,ProviderIds,DateCreated,ParentId,ChildCount,ProductionYear,UserData,ImageTags';

String _jellyfinFields(String fields) =>
    fields == MediaServerClient.gridFields ? _gridFields : _detailFields;

/// Independent Jellyfin adapter. No session is installed by a login response:
/// the source registry remains the only authority which commits credentials.
class JellyfinClient extends MediaServerClient
    implements InteractiveAuthentication, MediaFavorites {
  JellyfinClient({required this.device, Dio? dio, DateTime Function()? clock})
    : _dio = dio ?? Dio(),
      _clock = clock ?? DateTime.now;
  final Dio _dio;
  final DateTime Function() _clock;
  @override
  final ClientDeviceInfo device;
  @override
  Uri? baseUrl;
  @override
  String? accessToken;
  @override
  String? userId;
  @override
  String? customUserAgent;
  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  void Function()? _guard;
  int _generation = 0;
  final _leases = <String, PlaybackResourceLease>{};
  final _reports = <String, PlaybackReport>{};
  @override
  MediaServerType get serviceType => MediaServerType.jellyfin;
  @override
  InteractiveAuthentication get interactiveAuthentication => this;
  @override
  AccountResourceAuthentication? get accountAuthentication => null;
  @override
  bool get hasSession =>
      baseUrl != null && accessToken != null && userId != null;
  @override
  String get userAgent => resolveUserAgent(customUserAgent, device);
  String _quote(String v) => v.replaceAll(RegExp(r'["\\\r\n]'), '_');
  Map<String, String> _headers([String? token, String? playbackDevice]) => {
    'Authorization':
        'MediaBrowser Client="${_quote(device.clientName)}", Device="${_quote(device.deviceName)}", DeviceId="${_quote(playbackDevice ?? device.deviceId)}", Version="${_quote(device.version)}"${token == null ? '' : ', Token="${_quote(token)}"'}',
    'User-Agent': userAgent,
  };
  @override
  Map<String, String> get sessionHeaders => _headers(accessToken);
  @override
  ServiceCapabilities get capabilities => ServiceCapabilities(
    {
      for (final c in [
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
      ])
        c: _available,
      ServiceCapability.quickConnect: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '需查询服务器 Quick Connect 开关',
      ),
      ServiceCapability.preview: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '取决于条目的 trickplay 或章节图片',
      ),
      ServiceCapability.notifications: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '通过页面刷新取得最新状态',
      ),
    },
    serverOrderedShelves: const {'resume', 'nextup', 'similar'},
  );
  @override
  JellyfinClient createDetached() =>
      JellyfinClient(device: device, clock: _clock)
        ..setUserAgent(customUserAgent);
  @override
  JellyfinClient withRequestGuard(void Function() guard) {
    final copy = JellyfinClient(device: device, dio: _dio, clock: _clock)
      ..baseUrl = baseUrl
      ..accessToken = accessToken
      ..userId = userId
      ..customUserAgent = customUserAgent;
    final previous = _guard;
    copy._guard = () {
      previous?.call();
      guard();
    };
    return copy;
  }

  @override
  void setUserAgent(String? value) =>
      customUserAgent = normalizeUserAgent(value);
  @override
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) {
    _validateBase(baseUrl);
    _generation++;
    this.baseUrl = baseUrl;
    this.accessToken = accessToken;
    this.userId = userId;
    setUserAgent(userAgent);
  }

  @override
  void clearSession() {
    _generation++;
    baseUrl = null;
    accessToken = null;
    userId = null;
  }

  static void _validateBase(Uri base) {
    if (!['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidAddress);
    }
  }

  Uri _uri(Uri base, String path, [Map<String, dynamic>? query]) {
    _validateBase(base);
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = base.replace(
      path: '$prefix/${path.replaceFirst(RegExp(r'^/+'), '')}',
      query: null,
      fragment: null,
    );
    return query == null
        ? uri
        : uri.replace(
            queryParameters: {
              for (final e in query.entries)
                if (e.value != null) e.key: e.value.toString(),
            },
          );
  }

  void _check(int generation) {
    _guard?.call();
    if (generation != _generation) {
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
  }

  Future<dynamic> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Object? body,
    Uri? server,
    bool authenticated = true,
    CancelToken? cancelToken,
    String? playbackDevice,
  }) async {
    final generation = _generation;
    _check(generation);
    final base = server ?? baseUrl;
    if (base == null || (authenticated && !hasSession)) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    try {
      final r = await _dio.requestUri<dynamic>(
        _uri(base, path, query),
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: _headers(authenticated ? accessToken : null, playbackDevice),
          followRedirects: false,
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      _check(generation);
      return r.data;
    } on DioException catch (e) {
      _check(generation);
      final failure = MediaServerException.fromDio(
        e,
        authenticating: !authenticated,
      );
      if (failure.kind == MediaServerFailureKind.sessionExpired) {
        onSessionExpired?.call();
      }
      throw MediaServerException(failure.kind, statusCode: failure.statusCode);
    }
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return Map<String, dynamic>.from(value);
  }

  @override
  Uri resolveResource(String resource) {
    final base = baseUrl;
    if (base == null) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    final u = Uri.parse(resource);
    if (u.hasScheme) {
      _validateBase(u);
      return u;
    }
    if (resource.startsWith('//')) return base.resolve(resource);
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    if (prefix.isNotEmpty && u.path.startsWith('$prefix/')) {
      return base.resolve(resource);
    }
    return Uri.parse(
      '${base.origin}$prefix/${resource.replaceFirst(RegExp(r'^/+'), '')}',
    );
  }

  ResourceAuthorization get _authorization => ResourceAuthorization(
    headersByOrigin: {if (baseUrl != null) baseUrl!.origin: sessionHeaders},
    publicHeaders: {'User-Agent': userAgent},
  );
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async =>
      decodeJellyfinPublicServerInfo(
        _map(
          await _request(
            'System/Info/Public',
            server: baseUrl,
            authenticated: false,
          ),
        ),
      );

  /// Frozen Jellyfin image route `GET /Branding/Splashscreen`.
  /// One attempt: empty, failed, or missing responses yield null.
  Future<Uint8List?> loadBrandingLogo() async {
    final base = baseUrl;
    if (!hasSession || base == null) return null;
    final generation = _generation;
    try {
      _check(generation);
      final response = await _dio.getUri<List<int>>(
        _uri(base, 'Branding/Splashscreen'),
        options: Options(
          headers: _headers(accessToken),
          responseType: ResponseType.bytes,
          followRedirects: false,
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
          validateStatus: (status) => status == 200,
        ),
      );
      _check(generation);
      if (response.statusCode != 200) return null;
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } on MediaServerException {
      return null;
    } on DioException {
      return null;
    }
  }

  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async => _loginResult(
    await _request(
      'Users/AuthenticateByName',
      method: 'POST',
      server: baseUrl,
      authenticated: false,
      body: {'Username': username, 'Pw': password},
    ),
    serverId,
  );
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async =>
      decodeJellyfinMediaUser(
        _map(await _request('Users/Me', cancelToken: cancelToken)),
      );
  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    await _request(
      'Users/Password',
      method: 'POST',
      query: {'userId': userId},
      body: {
        'CurrentPw': currentPassword,
        'NewPw': newPassword,
        'ResetPassword': false,
      },
    );
  }

  @override
  Future<void> logout() async {
    try {
      if (hasSession) await _request('Sessions/Logout', method: 'POST');
    } finally {
      clearSession();
    }
  }

  @override
  Future<CapabilityStatus> availability(
    AuthorizationMethod method, {
    Uri? server,
  }) async {
    if (method == AuthorizationMethod.password) return _available;
    if (method != AuthorizationMethod.quickConnect) {
      return const CapabilityStatus(
        CapabilityAvailability.unsupported,
        reason: 'Jellyfin 使用密码或 Quick Connect',
      );
    }
    final enabled = await _request(
      'QuickConnect/Enabled',
      server: server,
      authenticated: false,
    );
    if (enabled is! bool) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return enabled
        ? _available
        : const CapabilityStatus(
            CapabilityAvailability.restricted,
            reason: '服务器已禁用 Quick Connect',
          );
  }

  @override
  Future<AuthorizationAttempt> begin(
    AuthorizationMethod method, {
    Uri? server,
  }) async {
    final target = server ?? baseUrl;
    if (target == null) {
      throw const MediaServerException(MediaServerFailureKind.invalidAddress);
    }
    final generation = _generation;
    if (method != AuthorizationMethod.quickConnect ||
        !(await availability(method, server: target)).isAvailable) {
      throw const MediaServerException(MediaServerFailureKind.unsupported);
    }
    final info = await getPublicInfo(target);
    final raw = _map(
      await _request(
        'QuickConnect/Initiate',
        method: 'POST',
        server: target,
        authenticated: false,
      ),
    );
    _check(generation);
    final secret = raw['Secret'];
    final code = raw['Code'];
    if (secret is! String ||
        secret.isEmpty ||
        code is! String ||
        code.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return _QuickConnectAttempt(
      this,
      target,
      info.id,
      secret,
      code,
      _clock().add(const Duration(minutes: 10)),
    );
  }

  @override
  CatalogNotifications? watchCatalog({
    required Future<void> Function() onUserDataChanged,
    required Future<void> Function() onLibraryChanged,
  }) => null;
  Future<MediaItemPage> _page(
    String path,
    Map<String, dynamic> query, {
    bool pageable = true,
  }) async {
    final data = await _request(path, query: {'userId': userId, ...query});
    return MediaItemPage(
      items: parseJellyfinItemList(data),
      totalRecordCount: parseJellyfinTotalCount(data),
      offset: query['startIndex'] as int? ?? 0,
      pagination: pageable
          ? _available
          : const CapabilityStatus(
              CapabilityAvailability.unsupported,
              reason: 'Jellyfin 此接口不提供偏移分页',
            ),
    );
  }

  void _noSort(String? sortBy, String? sortOrder) {
    if (sortBy != null || sortOrder != null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: 'Jellyfin 此接口由服务器决定排序',
      );
    }
  }

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
  }) => _page('Items', {
    'parentId': parentId,
    'searchTerm': searchTerm,
    'includeItemTypes': includeItemTypes,
    'recursive': recursive,
    'limit': limit,
    'startIndex': startIndex,
    'sortBy': sortBy,
    'sortOrder': sortOrder,
    'filters': filters?.join(','),
    'genres': genres?.join('|'),
    'years': years?.join(','),
    'personIds': personIds?.join(','),
    'fields': _jellyfinFields(fields),
    'enableUserData': true,
    'enableTotalRecordCount': true,
  });
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
  }) async => (await queryItems(
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
  @override
  Future<List<MediaItem>> getViews() async =>
      (await _page('UserViews', {}, pageable: false)).items;
  @override
  Future<MediaItemPage> queryResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    _noSort(sortBy, sortOrder);
    return _page('UserItems/Resume', {
      'limit': limit,
      'startIndex': startIndex,
      'fields': _detailFields,
      'includeItemTypes': 'Movie,Episode',
      'enableTotalRecordCount': true,
    });
  }

  @override
  Future<List<MediaItem>> getResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  }) async => (await queryResumeItems(
    limit: limit,
    startIndex: startIndex,
    sortBy: sortBy,
    sortOrder: sortOrder,
  )).items;
  @override
  Future<MediaItemPage> queryNextUp({
    String? parentId,
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    _noSort(sortBy, sortOrder);
    return _page('Shows/NextUp', {
      'parentId': parentId,
      'limit': limit,
      'startIndex': startIndex,
      'fields': _detailFields,
      'enableTotalRecordCount': true,
    });
  }

  @override
  Future<List<MediaItem>> getNextUp({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  }) async => (await queryNextUp(
    limit: limit,
    startIndex: startIndex,
    sortBy: sortBy,
    sortOrder: sortOrder,
  )).items;
  @override
  Future<List<MediaItem>> getLatestItems({
    required String includeItemTypes,
    bool groupItems = true,
    int limit = 24,
  }) async => parseJellyfinItemList(
    await _request(
      'Items/Latest',
      query: {
        'userId': userId,
        'includeItemTypes': includeItemTypes,
        'groupItems': groupItems,
        'limit': limit,
        'fields': _detailFields,
      },
    ),
  );
  @override
  Future<List<MediaItem>> searchByName(String searchTerm, {int? startIndex}) =>
      getItems(
        searchTerm: searchTerm,
        startIndex: startIndex,
        includeItemTypes: 'Movie,Series,Episode',
        recursive: true,
        limit: 50,
      );
  @override
  Future<List<String>> getLibraryGenres(String? parentId) async {
    final m = _map(
      await _request(
        'Items/Filters2',
        query: {
          'userId': userId,
          'parentId': parentId,
          'includeItemTypes': 'Movie,Series,Episode',
        },
      ),
    );
    return [
      for (final g in (m['Genres'] as List? ?? []))
        if (g is Map && g['Name'] is String) g['Name'] as String,
    ];
  }

  @override
  Future<MediaItemPage> querySimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) {
    _noSort(sortBy, sortOrder);
    return _page('Items/${Uri.encodeComponent(itemId)}/Similar', {
      'limit': limit,
      'fields': _detailFields,
    }, pageable: false);
  }

  @override
  Future<List<MediaItem>> getSimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
  }) async => (await querySimilar(
    itemId,
    limit: limit,
    sortBy: sortBy,
    sortOrder: sortOrder,
  )).items;
  @override
  Future<MediaItem> getItem(
    String itemId, {
    String? fields,
    CancelToken? cancelToken,
  }) async {
    final raw = _map(
      await _request(
        'Items/${Uri.encodeComponent(itemId)}',
        query: {'userId': userId},
        cancelToken: cancelToken,
      ),
    );
    if (raw['Type'] == 'Movie' || raw['Type'] == 'Episode') {
      final segments = _map(
        await _request(
          'MediaSegments/${Uri.encodeComponent(itemId)}',
          cancelToken: cancelToken,
        ),
      );
      final chapters = [...?raw['Chapters'] as List?];
      for (final segment in segments['Items'] as List? ?? []) {
        if (segment is! Map || segment['ItemId'] != itemId) continue;
        final start = segment['StartTicks'], end = segment['EndTicks'];
        if (start is! int || end is! int || start < 0 || end <= start) continue;
        final type = segment['Type'];
        if (type != 'Intro' && type != 'Outro') continue;
        chapters.add({
          'Name': type,
          'StartPositionTicks': start,
          'MarkerType': type == 'Intro' ? 'IntroStart' : 'CreditsStart',
        });
        chapters.add({
          'Name': type,
          'StartPositionTicks': end,
          'MarkerType': type == 'Intro' ? 'IntroEnd' : 'CreditsEnd',
        });
      }
      raw['Chapters'] = chapters;
    }
    return decodeJellyfinMediaItem(raw);
  }

  @override
  Future<void> markPlayed(String itemId) async {
    await _request(
      'UserPlayedItems/${Uri.encodeComponent(itemId)}',
      method: 'POST',
      query: {'userId': userId},
    );
  }

  @override
  Future<void> markUnplayed(String itemId) async {
    await _request(
      'UserPlayedItems/${Uri.encodeComponent(itemId)}',
      method: 'DELETE',
      query: {'userId': userId},
    );
  }

  @override
  Future<void> setFavorite(String itemId, {required bool favorite}) async {
    await _request(
      'UserFavoriteItems/${Uri.encodeComponent(itemId)}',
      method: favorite ? 'POST' : 'DELETE',
      query: {'userId': userId},
    );
  }

  @override
  Future<void> hideFromResume(String itemId) async {
    await _request(
      'UserItems/${Uri.encodeComponent(itemId)}/UserData',
      method: 'POST',
      query: {'userId': userId},
      body: {'PlaybackPositionTicks': 0},
    );
  }

  @override
  Future<LibraryCounts> getItemCounts() async => decodeJellyfinLibraryCounts(
    _map(await _request('Items/Counts', query: {'userId': userId})),
  );
  Future<MediaItem?> _adjacent(MediaItem episode, int direction) async {
    if (episode.seriesId == null) return null;
    final p = await _page(
      'Shows/${Uri.encodeComponent(episode.seriesId!)}/Episodes',
      {'adjacentTo': episode.id, 'fields': _detailFields},
    );
    final i = p.items.indexWhere((e) => e.id == episode.id);
    final target = i + direction;
    return i >= 0 && target >= 0 && target < p.items.length
        ? p.items[target]
        : null;
  }

  @override
  Future<MediaItem?> getPreviousEpisode(MediaItem episode) =>
      _adjacent(episode, -1);
  @override
  Future<MediaItem?> getNextEpisode(MediaItem episode) => _adjacent(episode, 1);

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
    final c = capabilities ?? const PlaybackCapabilities();
    final playbackDevice =
        'rillight-playback-${base64Url.encode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '')}';
    final raw = _map(
      await _request(
        'Items/${Uri.encodeComponent(itemId)}/PlaybackInfo',
        method: 'POST',
        playbackDevice: playbackDevice,
        body: {
          'UserId': userId,
          'StartTimeTicks':
              (startPosition ?? Duration.zero).inMicroseconds * 10,
          'MaxStreamingBitrate': maxStreamingBitrate ?? c.maxStreamingBitrate,
          'MediaSourceId': ?mediaSourceId,
          'AudioStreamIndex': ?audioStreamIndex,
          'SubtitleStreamIndex': ?subtitleStreamIndex,
          'EnableDirectPlay': !forceTranscode,
          'EnableDirectStream': !forceTranscode,
          'EnableTranscoding': true,
          'AutoOpenLiveStream': false,
          'DeviceProfile': {
            'Name': 'Rillight',
            'MaxStreamingBitrate': maxStreamingBitrate ?? c.maxStreamingBitrate,
            'DirectPlayProfiles': [
              {
                'Type': 'Video',
                'Container': 'mkv,mp4,mov,avi,ts,webm',
                'VideoCodec': [
                  if (c.h264) 'h264',
                  if (c.hevc) 'hevc',
                  'av1',
                  'vp9',
                  'mpeg2video',
                ].join(','),
                'AudioCodec': [
                  if (c.aac) 'aac',
                  if (c.ac3) 'ac3',
                  if (c.eac3) 'eac3',
                  if (c.truehd) 'truehd',
                  if (c.dts) 'dts',
                  'flac',
                  'opus',
                  'vorbis',
                  'mp3',
                ].join(','),
              },
            ],
            'TranscodingProfiles': [
              {
                'Type': 'Video',
                'Container': 'ts',
                'Protocol': 'hls',
                'VideoCodec': 'h264',
                'AudioCodec': 'aac',
                'Context': 'Streaming',
                'EnableSubtitlesInManifest': true,
              },
            ],
            'SubtitleProfiles': [
              for (final f in [
                'srt',
                'vtt',
                if (c.ass) 'ass',
                if (c.ssa) 'ssa',
              ])
                {'Format': f, 'Method': 'External'},
              if (c.pgs) {'Format': 'pgssub', 'Method': 'Embed'},
            ],
          },
        },
      ),
    );
    if (raw['ErrorCode'] != null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: 'Jellyfin 拒绝此播放协商',
      );
    }
    final parsed = decodeJellyfinPlaybackInfo(raw);
    if (parsed.playSessionId.isEmpty || parsed.mediaSources.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final handle = _PlaybackHandle(
      parsed.playSessionId,
      playbackDevice,
    ).encode();
    final lease = _lease(
      handle,
      itemId: itemId,
      mediaSourceId: mediaSourceId ?? parsed.primarySource?.id,
    );
    return PlaybackInfo(
      playSessionId: handle,
      mediaSources: parsed.mediaSources,
      resources: lease,
    );
  }

  PlaybackResourceLease _lease(
    String id, {
    String? itemId,
    String? mediaSourceId,
  }) {
    final handle = _PlaybackHandle.decode(id);
    return _leases.putIfAbsent(id, () {
      // Capture original authority; a later user switch must never send cleanup
      // using the replacement user's credentials.
      final bound = withRequestGuard(() {});
      return PlaybackResourceLease(
        id: id,
        itemId: itemId,
        mediaSourceId: mediaSourceId,
        release: () async {
          final report = _reports[id];
          await bound._request(
            'Sessions/Playing/Stopped',
            method: 'POST',
            playbackDevice: handle.deviceId,
            body: report == null
                ? {'PlaySessionId': handle.rawId}
                : {
                    for (final e in _wireReport(report).entries)
                      if (const {
                        'ItemId',
                        'MediaSourceId',
                        'PlaySessionId',
                        'PositionTicks',
                      }.contains(e.key))
                        e.key: e.value,
                  },
          );
          _reports.remove(id);
        },
      );
    });
  }

  Map<String, dynamic> _wireReport(PlaybackReport report) => {
    ...encodeJellyfinPlaybackReport(report),
    'PlaySessionId': _PlaybackHandle.decode(report.playSessionId).rawId,
  };
  @override
  ResolvedPlayback? resolvePlayback({
    required PlaybackInfo info,
    required String itemId,
    String? mediaSourceId,
    bool forceTranscode = false,
  }) {
    final handle = _PlaybackHandle.decode(info.playSessionId);
    final s = mediaSourceId == null
        ? info.primarySource
        : info.sourceById(mediaSourceId);
    if (s == null) return null;
    String? resource;
    PlayMethod method;
    if (!forceTranscode &&
        (s.supportsDirectPlay ||
            (s.supportsDirectStream && s.directStreamUrl != null))) {
      method = s.supportsDirectPlay
          ? PlayMethod.directPlay
          : PlayMethod.directStream;
      resource = s.isRemoteHttpPath ? s.path : s.directStreamUrl;
      resource ??= _uri(
        baseUrl!,
        'Videos/${Uri.encodeComponent(itemId)}/stream',
        {
          'static': true,
          'mediaSourceId': s.id,
          'playSessionId': handle.rawId,
          'deviceId': handle.deviceId,
        },
      ).toString();
    } else {
      method = !forceTranscode && s.supportsDirectStream
          ? PlayMethod.directStream
          : PlayMethod.transcode;
      resource = s.transcodingUrl;
      if ((!s.supportsTranscoding && !s.supportsDirectStream) ||
          resource == null) {
        return null;
      }
    }
    final uri = resolveResource(resource);
    final auth = ResourceAuthorization(
      headersByOrigin: {
        baseUrl!.origin: _headers(accessToken, handle.deviceId),
      },
      publicHeaders: {'User-Agent': userAgent},
    );
    return ResolvedPlayback(
      canRenewUrlInPlace: false,
      playMethod: method,
      outputBitrate:
          method == PlayMethod.transcode || resource == s.transcodingUrl
          ? s.transcodingOutputBitrate
          : s.bitrate,
      streamUrl: uri,
      playSessionId: info.playSessionId,
      mediaSource: s,
      itemId: itemId,
      resources: info.resources,
      authorization: auth,
      timeline: MediaTimeline([
        MediaPart(
          id: s.id,
          resource: AuthorizedMediaResource(
            url: uri.toString(),
            authorization: auth,
          ),
          duration: s.runtime,
        ),
      ]),
      requiresStrmExpansion: uri.path.toLowerCase().endsWith('.strm'),
    );
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {
    await _request(
      'Sessions/Playing',
      method: 'POST',
      body: _wireReport(report),
      playbackDevice: _PlaybackHandle.decode(report.playSessionId).deviceId,
    );
    _reports[report.playSessionId] = report;
  }

  @override
  Future<void> reportProgress(PlaybackReport report) async {
    await _request(
      'Sessions/Playing/Progress',
      method: 'POST',
      body: _wireReport(report),
      playbackDevice: _PlaybackHandle.decode(report.playSessionId).deviceId,
    );
    _reports[report.playSessionId] = report;
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
    _reports[report.playSessionId] = report;
    await _lease(report.playSessionId).release();
  }

  @override
  Future<void> releasePlayback(PlaybackReport report) =>
      _lease(report.playSessionId).release();
  @override
  Uri subtitleStreamUrl({
    required String itemId,
    required String mediaSourceId,
    required int index,
    String format = 'srt',
  }) => _uri(
    baseUrl!,
    'Videos/${Uri.encodeComponent(itemId)}/${Uri.encodeComponent(mediaSourceId)}/Subtitles/$index/Stream.${Uri.encodeComponent(format)}',
  );
  @override
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
    int? maxBytes,
  }) async {
    final gen = _generation;
    final auth = _authorization;
    final cap = maxBytes ?? 16 * 1024 * 1024;
    for (var attempt = 0; ; attempt++) {
      try {
        var target = uri;
        for (var redirect = 0; redirect < 6; redirect++) {
          _check(gen);
          _validateBase(target);
          target = auth.sanitizeUri(target);
          final r = await _dio.getUri<ResponseBody>(
            target,
            options: Options(
              responseType: ResponseType.stream,
              headers: auth.headersFor(target),
              followRedirects: false,
              receiveTimeout: receiveTimeout,
              validateStatus: (s) => s != null && s >= 200 && s < 400,
            ),
          );
          _check(gen);
          if (r.statusCode! >= 300) {
            await r.data!.stream.drain<void>();
            final location = r.headers.value('location');
            if (location == null) break;
            target = target.resolve(location);
            continue;
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in r.data!.stream) {
            _check(gen);
            if (builder.length + chunk.length > cap) {
              throw const MediaServerException(
                MediaServerFailureKind.invalidResponse,
                detail: '资源超过读取上限',
              );
            }
            builder.add(chunk);
          }
          _check(gen);
          return builder.takeBytes();
        }
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
          detail: '重定向无效',
        );
      } on DioException catch (e) {
        _check(gen);
        final f = MediaServerException.fromDio(e);
        if (attempt + 1 >= attempts ||
            ![
              MediaServerFailureKind.timeout,
              MediaServerFailureKind.unreachable,
            ].contains(f.kind)) {
          throw MediaServerException(f.kind, statusCode: f.statusCode);
        }
      }
    }
  }

  Future<List<int>> _image(
    String itemId,
    String type,
    int? index,
    String? tag,
    int? maxWidth,
    CancelToken? token,
  ) async {
    if (token?.isCancelled == true) {
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
    final data = await readAuthorizedBytes(
      _uri(
        baseUrl!,
        'Items/${Uri.encodeComponent(itemId)}/Images/${Uri.encodeComponent(type)}${index == null ? '' : '/$index'}',
        {'tag': tag, 'maxWidth': maxWidth},
      ),
    );
    if (token?.isCancelled == true) {
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
    return data;
  }

  @override
  Future<List<int>> getPrimaryImage(
    String itemId, {
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) => _image(itemId, 'Primary', null, tag, maxWidth, cancelToken);
  @override
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  }) => _image(itemId, 'Chapter', index, tag, maxWidth, cancelToken);
  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int? index,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) => _image(itemId, type, index, tag, maxWidth, cancelToken);
  @override
  Future<List<int>> getOriginalItemImage(
    String itemId, {
    String type = 'Backdrop',
    String? tag,
    int? index,
    CancelToken? cancelToken,
  }) => _image(itemId, type, index, tag, null, cancelToken);
  @override
  Future<MediaPreview?> openPreview(String itemId) async {
    final raw = _map(
      await _request(
        'Items/${Uri.encodeComponent(itemId)}',
        query: {'userId': userId},
      ),
    );
    final trick = raw['Trickplay'];
    if (trick is Map) {
      for (final source in trick.entries) {
        if (source.value is! Map) continue;
        for (final entry in (source.value as Map).values) {
          if (entry is Map) {
            final preview = _JellyfinPreview.tryCreate(
              this,
              itemId,
              source.key.toString(),
              entry,
            );
            if (preview != null) return preview;
          }
        }
      }
    }
    final item = decodeJellyfinMediaItem(raw);
    return item.chapters.any((c) => c.imageTag != null)
        ? _ChapterPreview(this, item)
        : null;
  }
}
