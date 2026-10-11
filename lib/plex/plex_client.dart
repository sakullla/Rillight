import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/playback_metadata.dart';
import 'package:rillight/media_server/resources.dart';
import 'plex_authentication.dart';
import 'plex_codec.dart';
import 'plex_http.dart';

class PlexClient extends MediaServerClient
    implements PartPlaybackProvider, PlaybackMetadataProvider {
  PlexClient({
    required this.device,
    Dio? dio,
    PlexAuthentication? authentication,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 30),
             ),
           ),
       _authentication = authentication;
  final Dio _dio;
  final PlexAuthentication? _authentication;
  void Function()? _guard;
  int _generation = 0;
  int _sessionCounter = 0;
  final Map<String, Map<String, dynamic>> _metadata = {};
  final Map<String, Map<String, Set<String>>> _genres = {};
  PlexVerifiedResourceIdentity? _verifiedIdentity;
  final Map<String, _Playback> _playbacks = {};
  final Set<String> _releasedSessions = {};
  void _released(String session) {
    _playbacks.remove(session);
    _releasedSessions.add(session);
    if (_releasedSessions.length > 256) {
      _releasedSessions.remove(_releasedSessions.first);
    }
  }

  @override
  final ClientDeviceInfo device;
  @override
  MediaServerType get serviceType => MediaServerType.plex;
  @override
  InteractiveAuthentication? get interactiveAuthentication => _authentication;
  @override
  AccountResourceAuthentication? get accountAuthentication => _authentication;
  @override
  Uri? baseUrl;
  @override
  String? accessToken;
  @override
  String? userId;
  @override
  String? customUserAgent;
  @override
  String get userAgent => resolveUserAgent(customUserAgent, device);
  @override
  bool get hasSession =>
      baseUrl != null && accessToken != null && userId != null;
  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  @override
  Map<String, String> get sessionHeaders => {
    'X-Plex-Client-Identifier': device.deviceId,
    'X-Plex-Product': device.clientName,
    'X-Plex-Version': device.version,
    'X-Plex-Pms-Api-Version': '1.2.3',
    'User-Agent': userAgent,
    'X-Plex-Token': ?accessToken,
  };
  @override
  ServiceCapabilities get capabilities => ServiceCapabilities(
    {
      for (final c in [
        ServiceCapability.browserAuthorization,
        ServiceCapability.accountResources,
        ServiceCapability.homeUsers,
        ServiceCapability.resume,
        ServiceCapability.nextUp,
        ServiceCapability.latest,
        ServiceCapability.search,
        ServiceCapability.filters,
        ServiceCapability.pagination,
        ServiceCapability.watchedState,
        ServiceCapability.directPlay,
        ServiceCapability.directStream,
      ])
        c: const CapabilityStatus(
          CapabilityAvailability.available,
          reason: 'Plex 影视协议',
        ),
      ServiceCapability.transcode: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '由服务器协商及当前用户权限决定',
      ),
      ServiceCapability.preview: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '由媒体实际生成的预览决定',
      ),
      ServiceCapability.chapters: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '由实际章节元数据决定',
      ),
      for (final c in [
        ServiceCapability.passwordLogin,
        ServiceCapability.quickConnect,
        ServiceCapability.changePassword,
      ])
        c: const CapabilityStatus(
          CapabilityAvailability.unsupported,
          reason: 'Plex 账号通过官方网页管理',
        ),
      ServiceCapability.notifications: const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '通过显式刷新获取目录状态',
      ),
    },
    defaultRecentSort: 'DateCreated',
    unsupportedFilters: const {'IsFavorite'},
    unsupportedSorts: const {
      'DateLastContentAdded',
      'CriticRating',
      'OfficialRating',
      'Runtime',
    },
  );
  @override
  MediaServerClient createDetached() => PlexClient(device: device);
  @override
  MediaServerClient withRequestGuard(void Function() guard) {
    final client = PlexClient(
      device: device,
      dio: _dio,
      authentication: _authentication,
    );
    if (hasSession) {
      client.attachSession(
        baseUrl: baseUrl!,
        accessToken: accessToken!,
        userId: userId!,
        userAgent: customUserAgent,
      );
    }
    client._guard = () {
      _guard?.call();
      guard();
    };
    client._verifiedIdentity = _verifiedIdentity;
    return client;
  }

  @override
  void setUserAgent(String? userAgent) =>
      customUserAgent = normalizeUserAgent(userAgent);
  @override
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) {
    _generation++;
    _metadata.clear();
    _genres.clear();
    _verifiedIdentity = null;
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
    _metadata.clear();
    _genres.clear();
    _verifiedIdentity = null;
  }

  Uri _uri(String path, [Map<String, Object?> query = const {}]) {
    if (baseUrl == null) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    return plexEndpoint(baseUrl!, path, query);
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, Object?> query = const {},
    String method = 'GET',
    CancelToken? cancelToken,
    bool refreshed = false,
  }) async {
    _guard?.call();
    final generation = _generation;
    try {
      final response = await plexRequest(
        _dio,
        _uri(path, query),
        method: method,
        headers: sessionHeaders,
        cancelToken: cancelToken,
      );
      _guard?.call();
      if (generation != _generation) {
        throw const MediaServerException(MediaServerFailureKind.cancelled);
      }
      if ((response.statusCode ?? 0) >= 300) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
        );
      }
      if (response.data == null || response.data == '') return {};
      final root = plexMap(response.data);
      return root['MediaContainer'] is Map
          ? plexMap(root['MediaContainer'])
          : root;
    } on MediaServerException catch (error) {
      if (error.kind == MediaServerFailureKind.authorizationExpired &&
          !refreshed &&
          onRefreshSession != null) {
        _guard?.call();
        if (await onRefreshSession!()) {
          _guard?.call();
          return _get(
            path,
            query: query,
            method: method,
            cancelToken: cancelToken,
            refreshed: true,
          );
        }
      }
      if (error.kind == MediaServerFailureKind.sessionExpired ||
          error.kind == MediaServerFailureKind.authorizationExpired) {
        onSessionExpired?.call();
      }
      rethrow;
    }
  }

  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    _guard?.call();
    final response = await plexRequest(
      _dio,
      plexEndpoint(baseUrl, '/identity'),
      headers: {'X-Plex-Client-Identifier': device.deviceId},
    );
    _guard?.call();
    final root = plexMap(plexMap(response.data)['MediaContainer']);
    final id = plexString(root['machineIdentifier']);
    if (id.isEmpty) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
    return PublicServerInfo(
      id: id,
      serverName: plexString(root['friendlyName']).isEmpty
          ? 'Plex'
          : plexString(root['friendlyName']),
      version: root['version'] as String?,
    );
  }

  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async =>
      throw const MediaServerException(MediaServerFailureKind.unsupported);
  @override
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async =>
      throw const MediaServerException(MediaServerFailureKind.unsupported);
  @override
  Future<void> logout() async {
    clearSession();
  }

  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    final identity = _verifiedIdentity;
    if (identity == null || !identity.matches(baseUrl, accessToken, userId)) {
      throw const MediaServerException(
        MediaServerFailureKind.forbidden,
        detail: 'Plex 资源身份尚未核验',
      );
    }
    final root = await _get('/', cancelToken: cancelToken);
    if (!identical(identity, _verifiedIdentity) ||
        plexString(root['machineIdentifier']) != identity.serverId) {
      throw const MediaServerException(
        MediaServerFailureKind.forbidden,
        detail: 'Plex 服务器身份不匹配',
      );
    }
    return identity.user;
  }

  /// Called by the source authority only after PlexAuthentication verifies the
  /// live account/Home -> resources chain. attachSession invalidates this proof.
  void bindVerifiedIdentity(PlexVerifiedResourceIdentity identity) {
    _guard?.call();
    if (!identity.matches(baseUrl, accessToken, userId)) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    _verifiedIdentity = identity;
  }

  @override
  CatalogNotifications? watchCatalog({
    required Future<void> Function() onUserDataChanged,
    required Future<void> Function() onLibraryChanged,
  }) => null;
  List<MediaItem> _items(Map<String, dynamic> root) {
    final rows = [
      ...plexList(root['Metadata']),
      for (final hub in plexList(root['Hub'])) ...plexList(hub['Metadata']),
    ];
    return [
      for (final row in rows)
        if (['movie', 'show', 'season', 'episode'].contains(row['type']))
          _remember(row),
    ];
  }

  MediaItem _remember(Map<String, dynamic> row) {
    final item = plexItem(row);
    _metadata[item.id] = row;
    return item;
  }

  Future<MediaItemPage> _page(
    String path, {
    Map<String, Object?> query = const {},
    int? limit,
    int? startIndex,
  }) async {
    final root = await _get(
      path,
      query: {
        ...query,
        'X-Plex-Container-Size': ?limit,
        if (limit != null) 'X-Plex-Container-Start': startIndex ?? 0,
      },
    );
    return MediaItemPage(
      items: _items(root),
      totalRecordCount: plexInt(root['totalSize']),
      offset: plexInt(root['offset']) ?? 0,
      pagination: CapabilityStatus(
        root.containsKey('offset')
            ? CapabilityAvailability.available
            : CapabilityAvailability.unsupported,
        reason: root.containsKey('offset') ? '服务器返回分页偏移' : '服务器返回完整未分页集合',
      ),
    );
  }

  @override
  Future<List<MediaItem>> getViews() async {
    final root = await _get('/library/sections');
    return [
      for (final row in plexList(root['Directory']))
        if (['movie', 'show'].contains(row['type']))
          plexItem({...row, 'key': 'section:${row['key']}'}, section: true),
    ];
  }

  String? _sort(String? sortBy, String? order) {
    if (sortBy == null) return null;
    const values = {
      'SortName': 'titleSort',
      'Name': 'titleSort',
      'DateCreated': 'addedAt',
      'PremiereDate': 'originallyAvailableAt',
      'ProductionYear': 'year',
      'CommunityRating': 'rating',
      'DatePlayed': 'lastViewedAt',
      'PlayCount': 'viewCount',
      'IndexNumber': 'index',
      'ParentIndexNumber': 'parentIndex',
      'Random': 'random',
    };
    return sortBy
        .split(',')
        .map((v) {
          final key = values[v];
          if (key == null) {
            throw const MediaServerException(
              MediaServerFailureKind.unsupported,
              detail: '该排序没有 Plex 等价语义',
            );
          }
          return '$key:${order == 'Descending' ? 'desc' : 'asc'}';
        })
        .join(',');
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
    String fields = MediaServerClient.gridFields,
    String imageTypes = MediaServerClient.imageTypes,
  }) async {
    final section = parentId?.startsWith('section:') == true;
    // Hub search is a recommendation preview (three hits per hub by default),
    // not the paginated, filterable media query used by the search screen.
    final path = parentId == null
        ? '/library/all'
        : section
        ? '/library/sections/${Uri.encodeComponent(parentId.substring(8))}/all'
        : '/library/metadata/${Uri.encodeComponent(parentId)}/${recursive ? 'allLeaves' : 'children'}';
    final types = <String>[];
    for (final type
        in includeItemTypes?.split(',') ??
            (searchTerm != null
                ? ['Movie', 'Series', 'Episode']
                : <String>[])) {
      final code = {
        'Movie': '1',
        'Series': '2',
        'Season': '3',
        'Episode': '4',
      }[type];
      if (code != null) types.add(code);
    }
    final genreKeys = genres?.isNotEmpty == true
        ? await _genreKeys(parentId, genres!)
        : null;
    if (genreKeys != null && genreKeys.isEmpty) {
      return MediaItemPage(
        items: const [],
        totalRecordCount: 0,
        offset: startIndex ?? 0,
        pagination: const CapabilityStatus(
          CapabilityAvailability.available,
          reason: '所选分类在此媒体库没有对应标签',
        ),
      );
    }
    final filterQuery = <String, Object?>{};
    for (final filter in filters ?? <String>[]) {
      switch (filter) {
        case 'IsPlayed':
          filterQuery['unwatched'] = 0;
        case 'IsUnplayed':
          filterQuery['unwatched'] = 1;
        case 'IsResumable':
          filterQuery['inProgress'] = 1;
        default:
          throw const MediaServerException(
            MediaServerFailureKind.unsupported,
            detail: '该筛选没有 Plex 等价语义',
          );
      }
    }
    return _page(
      path,
      limit: limit,
      startIndex: startIndex,
      query: {
        if (types.isNotEmpty) 'type': types.join(','),
        'title': ?searchTerm,
        'sort': _sort(sortBy, sortOrder),
        if (genreKeys != null) 'genre': genreKeys.join(','),
        if (years?.isNotEmpty == true) 'year': years!.join(','),
        ...filterQuery,
      },
    );
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
    fields: fields,
  )).items;
  @override
  Future<List<MediaItem>> searchByName(String searchTerm, {int? startIndex}) =>
      getItems(searchTerm: searchTerm, limit: 40, startIndex: startIndex);
  @override
  Future<MediaItemPage> queryResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) => _page(
    '/hubs/continueWatching',
    limit: limit,
    startIndex: startIndex,
    query: {'count': limit, 'sort': _sort(sortBy, sortOrder)},
  );
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
  }) => _page(
    parentId?.startsWith('section:') == true
        ? '/library/sections/${Uri.encodeComponent(parentId!.substring(8))}/onDeck'
        : '/library/onDeck',
    limit: limit,
    startIndex: startIndex,
    query: {'type': 4, 'sort': _sort(sortBy, sortOrder)},
  );
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
  }) => getItems(
    includeItemTypes: includeItemTypes,
    limit: limit,
    sortBy: 'DateCreated',
    sortOrder: 'Descending',
  );
  @override
  Future<List<String>> getLibraryGenres(String? parentId) async {
    if (parentId == null) {
      final values = <String>{};
      for (final view in await getViews()) {
        values.addAll(await getLibraryGenres(view.id));
      }
      return values.toList()..sort();
    }
    final root = await _get(
      '/library/sections/${Uri.encodeComponent(parentId.replaceFirst('section:', ''))}/genre',
    );
    final mapping = <String, Set<String>>{};
    for (final row in plexList(root['Directory'])) {
      final title = plexString(row['title']);
      final key = plexString(row['key']);
      final value = Uri.tryParse(key)?.queryParameters['genre'] ?? key;
      if (title.isEmpty || !RegExp(r'^\d+$').hasMatch(value)) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
          detail: 'Plex 分类缺少有效标签标识',
        );
      }
      mapping.putIfAbsent(title, () => {}).add(value);
    }
    _genres[parentId] = mapping;
    return mapping.keys.toList()..sort();
  }

  Future<Set<String>> _genreKeys(String? parentId, List<String> titles) async {
    final sections = <String>[];
    if (parentId == null) {
      sections.addAll((await getViews()).map((v) => v.id));
    } else if (parentId.startsWith('section:')) {
      sections.add(parentId);
    } else {
      if (!_metadata.containsKey(parentId)) await getItem(parentId);
      final section = _metadata[parentId]?['librarySectionID'];
      if (section == null) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
        );
      }
      sections.add('section:$section');
    }
    final result = <String>{};
    for (final section in sections) {
      // Resolve against each section's actual tag IDs, never against its label.
      await getLibraryGenres(section);
      for (final title in titles) {
        result.addAll(_genres[section]?[title] ?? {});
      }
    }
    return result;
  }

  @override
  Future<MediaItemPage> querySimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  }) => _page(
    '/library/metadata/${Uri.encodeComponent(itemId)}/similar',
    limit: limit,
    query: {'sort': _sort(sortBy, sortOrder)},
  );
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
    if (itemId.startsWith('section:')) {
      return (await getViews()).firstWhere((v) => v.id == itemId);
    }
    final root = await _get(
      '/library/metadata/${Uri.encodeComponent(itemId)}',
      query: {'includeChapters': 1, 'includeMarkers': 1, 'includeGuids': 1},
      cancelToken: cancelToken,
    );
    final rows = plexList(root['Metadata']);
    if (rows.length != 1 || plexString(rows.first['ratingKey']) != itemId) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return _remember(rows.first);
  }

  @override
  Future<void> markPlayed(String itemId) async {
    await _get(
      '/:/scrobble',
      query: {'key': itemId, 'identifier': 'com.plexapp.plugins.library'},
    );
  }

  @override
  Future<void> markUnplayed(String itemId) async {
    await _get(
      '/:/unscrobble',
      query: {'key': itemId, 'identifier': 'com.plexapp.plugins.library'},
    );
  }

  @override
  Future<void> hideFromResume(String itemId) async {
    await _get(
      '/actions/removeFromContinueWatching',
      method: 'PUT',
      query: {'ratingKey': itemId},
    );
  }

  @override
  Future<LibraryCounts> getItemCounts() async {
    final counts = <int?>[];
    for (final type in ['Movie', 'Series', 'Episode']) {
      counts.add(
        (await queryItems(includeItemTypes: type, limit: 0)).totalRecordCount,
      );
    }
    return LibraryCounts(
      movie: counts[0],
      series: counts[1],
      episode: counts[2],
      others: const [],
    );
  }

  Future<MediaItem?> _adjacent(MediaItem episode, int direction) async {
    if (episode.seriesId == null) return null;
    MediaItem? previous;
    var found = false;
    var offset = 0;
    while (true) {
      final page = await queryItems(
        parentId: episode.seriesId,
        recursive: true,
        includeItemTypes: 'Episode',
        limit: 200,
        startIndex: offset,
        sortBy: 'ParentIndexNumber,IndexNumber',
        sortOrder: 'Ascending',
      );
      if (page.pagination.isAvailable && page.offset != offset) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
        );
      }
      for (final item in page.items) {
        if (found && direction > 0) return item;
        if (item.id == episode.id) {
          if (direction < 0) return previous;
          found = true;
        }
        previous = item;
      }
      offset += page.items.length;
      if (!page.hasMore(fetched: offset, pageSize: 200)) return null;
    }
  }

  @override
  Future<MediaItem?> getPreviousEpisode(MediaItem episode) =>
      _adjacent(episode, -1);
  @override
  Future<MediaItem?> getNextEpisode(MediaItem episode) => _adjacent(episode, 1);

  ResourceAuthorization get _authorization => ResourceAuthorization(
    headersByOrigin: {if (baseUrl != null) baseUrl!.origin: sessionHeaders},
    publicHeaders: {'User-Agent': userAgent},
  );
  @override
  Uri resolveResource(String resource) {
    final uri = Uri.parse(resource);
    if (uri.hasScheme || uri.hasAuthority) {
      if (!['http', 'https'].contains(uri.scheme)) {
        throw const MediaServerException(MediaServerFailureKind.invalidAddress);
      }
      return uri;
    }
    // Preserve query bytes from signed keys while retaining reverse-proxy prefix.
    return Uri.parse(
      '${baseUrl.toString().replaceFirst(RegExp(r'/+$'), '')}/${resource.replaceFirst(RegExp(r'^/+'), '')}',
    );
  }

  @override
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
    int? maxBytes,
  }) async {
    final generation = _generation;
    final auth = _authorization;
    var target = uri;
    for (var hop = 0; hop < 6; hop++) {
      _guard?.call();
      target = auth.sanitizeUri(target);
      final response = await plexRequest(
        _dio,
        target,
        headers: auth.headersFor(target),
        responseType: ResponseType.stream,
      );
      _guard?.call();
      if (generation != _generation) {
        throw const MediaServerException(MediaServerFailureKind.cancelled);
      }
      final body = response.data as ResponseBody;
      if ((response.statusCode ?? 0) >= 300) {
        await body.stream.drain<void>();
        final location = response.headers.value('location');
        if (location == null) break;
        target = target.resolve(location);
        if (!['http', 'https'].contains(target.scheme)) break;
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream.timeout(receiveTimeout)) {
        _guard?.call();
        if (generation != _generation) {
          throw const MediaServerException(MediaServerFailureKind.cancelled);
        }
        bytes.add(chunk);
        if (bytes.length > (maxBytes ?? 32 * 1024 * 1024)) {
          throw const MediaServerException(
            MediaServerFailureKind.invalidResponse,
            detail: '资源超过读取上限',
          );
        }
      }
      return bytes.takeBytes();
    }
    throw const MediaServerException(
      MediaServerFailureKind.invalidResponse,
      detail: '资源重定向无效',
    );
  }

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int? index,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) async {
    if (tag == null) {
      await getItem(itemId, cancelToken: cancelToken);
      tag = _metadata[itemId]?[type == 'Backdrop' ? 'art' : 'thumb'] as String?;
    }
    if (tag == null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: '该条目没有图片',
      );
    }
    return readAuthorizedBytes(
      resolveResource(tag),
      maxBytes: 16 * 1024 * 1024,
    );
  }

  @override
  Future<List<int>> getPrimaryImage(
    String itemId, {
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) => getItemImage(
    itemId,
    tag: tag,
    maxWidth: maxWidth,
    cancelToken: cancelToken,
  );
  @override
  Future<List<int>> getOriginalItemImage(
    String itemId, {
    String type = 'Backdrop',
    String? tag,
    int? index,
    CancelToken? cancelToken,
  }) => getItemImage(
    itemId,
    type: type,
    tag: tag,
    index: index,
    cancelToken: cancelToken,
  );
  @override
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  }) async {
    final item = await getItem(itemId, cancelToken: cancelToken);
    final chapter = item.chapters
        .where((v) => v.imageIndex == index)
        .firstOrNull;
    if (tag == null && chapter?.imageTag == null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: '该章节没有缩略图',
      );
    }
    return getItemImage(
      itemId,
      tag: tag ?? chapter?.imageTag,
      maxWidth: maxWidth,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<MediaPreview?> openPreview(String itemId) async {
    final item = await getItem(itemId);
    final media = plexList(_metadata[itemId]?['Media']).firstOrNull;
    final parts = plexList(media?['Part']);
    if (parts.isNotEmpty &&
        parts.every(
          (part) => plexString(part['indexes']).split(',').contains('sd'),
        )) {
      return _IndexPreview(this, itemId, parts);
    }
    final frames = item.chapters.where((v) => v.imageTag != null).toList();
    return frames.isEmpty ? null : _ChapterPreview(this, itemId, frames);
  }

  @override
  Future<List<PlaybackMediaSource>> getPlaybackSources({
    required String itemId,
    Duration position = Duration.zero,
  }) async {
    // Catalog discovery must not depend on a default version being playable or
    // on any previous playback negotiation.
    final root = await _get('/library/metadata/${Uri.encodeComponent(itemId)}');
    final rows = plexList(root['Metadata']);
    if (rows.length != 1 || plexString(rows.single['ratingKey']) != itemId) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final row = rows.single;
    return [
      for (final media in plexList(row['Media']))
        _playbackSourceMetadata(media, row, position),
    ];
  }

  PlaybackMediaSource _playbackSourceMetadata(
    Map<String, dynamic> media,
    Map<String, dynamic> row,
    Duration position,
  ) {
    final parts = plexList(media['Part']);
    // Use the actual playback locator. Empty resources here deliberately cannot
    // be opened and allocate no server-side lease.
    final timeline = MediaTimeline([
      for (final part in parts)
        MediaPart(
          id: plexString(part['id']),
          resource: AuthorizedMediaResource(
            url: '',
            authorization: ResourceAuthorization(headersByOrigin: const {}),
          ),
          duration: plexDuration(part['duration']),
        ),
    ]);
    final location = timeline.locate(position);
    final streams = location == null
        ? <MediaStreamInfo>[]
        : plexList(
            parts[location.index]['Stream'],
          ).map(plexPlaybackStream).toList();
    return PlaybackMediaSource(
      id: plexString(media['id']),
      name: plexString(media['videoResolution']),
      container: media['container'] as String?,
      runtime: plexDuration(media['duration'] ?? row['duration']),
      bitrate: plexInt(media['bitrate']) == null
          ? null
          : plexInt(media['bitrate'])! * 1000,
      width: plexInt(media['width']),
      height: plexInt(media['height']),
      size: parts.isEmpty || parts.any((part) => plexInt(part['size']) == null)
          ? null
          : parts.fold<int>(0, (sum, part) => sum + plexInt(part['size'])!),
      mediaStreams: streams,
      defaultAudioStreamIndex: streams
          .where((stream) => stream.isAudio && stream.isDefault)
          .firstOrNull
          ?.index,
      defaultSubtitleStreamIndex: streams
          .where((stream) => stream.isSubtitle && stream.isDefault)
          .firstOrNull
          ?.index,
    );
  }

  @override
  Future<PlaybackInfo> preparePart({
    required String itemId,
    required PlaybackMediaSource previous,
    required Duration position,
    required int? audioIndex,
    required int? subtitleIndex,
    required int maxStreamingBitrate,
    PlaybackCapabilities? capabilities,
  }) async {
    await getItem(itemId);
    final media = plexList(
      _metadata[itemId]?['Media'],
    ).where((v) => plexString(v['id']) == previous.id).firstOrNull;
    if (media == null) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final parts = plexList(media['Part']);
    final timeline = MediaTimeline([
      for (final part in parts)
        MediaPart(
          id: plexString(part['id']),
          resource: AuthorizedMediaResource(
            url: '',
            authorization: _authorization,
          ),
          duration: plexDuration(part['duration']),
        ),
    ]);
    final location = timeline.locate(position);
    if (location == null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: '分段时长未知，无法定位',
      );
    }
    final tracks = plexList(
      parts[location.index]['Stream'],
    ).map(plexPlaybackStream).toList();
    final target = PlaybackMediaSource(
      id: previous.id,
      runtime: timeline.duration,
      mediaStreams: tracks,
      defaultAudioStreamIndex: tracks
          .where((s) => s.isAudio && s.isDefault)
          .firstOrNull
          ?.index,
      defaultSubtitleStreamIndex: tracks
          .where((s) => s.isSubtitle && s.isDefault)
          .firstOrNull
          ?.index,
    );
    int? match(int? index, String type) {
      if (index == null) return null;
      final old = previous.streamByIndex(index);
      if (old == null) {
        throw StateError('Selected track identity is unavailable');
      }
      final candidates = tracks.where((s) => s.type == type).toList();
      // Plex IDs are globally unique within this source: retain an exact ID
      // only when it actually belongs to this Part, otherwise map language.
      if (candidates.any((s) => s.index == index)) return index;
      final language = old.language?.trim().toLowerCase();
      if (language == null || language.isEmpty || language == 'und') {
        throw PartTrackSelectionRequired(target);
      }
      final matching = candidates
          .where((s) => s.language?.trim().toLowerCase() == language)
          .toList();
      if (matching.length == 1) return matching.single.index;
      final titled = matching
          .where(
            (s) =>
                old.displayTitle != null && s.displayTitle == old.displayTitle,
          )
          .toList();
      if (titled.length == 1) return titled.single.index;
      throw PartTrackSelectionRequired(target);
    }

    return getPlaybackInfo(
      itemId: itemId,
      mediaSourceId: previous.id,
      startPosition: position,
      audioStreamIndex: match(audioIndex, 'Audio'),
      subtitleStreamIndex: subtitleIndex == null
          ? -1
          : match(subtitleIndex, 'Subtitle'),
      maxStreamingBitrate: maxStreamingBitrate,
      capabilities: capabilities,
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
    await getItem(itemId);
    final row = _metadata[itemId]!;
    final versions = plexList(row['Media']);
    final index = mediaSourceId == null
        ? 0
        : versions.indexWhere((v) => plexString(v['id']) == mediaSourceId);
    if (index < 0 || index >= versions.length) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidResponse,
        detail: '所选版本不存在',
      );
    }
    final media = versions[index];
    final parts = plexList(media['Part']);
    if (parts.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final auth = _authorization;
    final timeline = MediaTimeline([
      for (final part in parts)
        MediaPart(
          id: plexString(part['id']),
          resource: AuthorizedMediaResource(
            url: resolveResource(plexString(part['key'])).toString(),
            authorization: auth,
          ),
          duration: plexDuration(part['duration']),
        ),
    ]);
    final position = startPosition ?? Duration.zero;
    final location = timeline.locate(position);
    if (location == null) {
      throw const MediaServerException(
        MediaServerFailureKind.unsupported,
        detail: '分段时长不足，无法定位全片时间',
      );
    }
    final session =
        '${device.deviceId}-${DateTime.now().microsecondsSinceEpoch}-${_sessionCounter++}';
    final streams = plexList(parts[location.index]['Stream']);
    final effectiveAudio = _selectedStream(streams, 2, audioStreamIndex);
    final effectiveSubtitle = _selectedStream(streams, 3, subtitleStreamIndex);
    final audioId = plexInt(effectiveAudio?['id']);
    final subtitleId = subtitleStreamIndex != null && subtitleStreamIndex < 0
        ? -1
        : plexInt(effectiveSubtitle?['id']);
    final videoNeedsTranscode = _videoNeedsTranscode(streams, capabilities);
    final audioNeedsTranscode = _audioNeedsTranscode(
      effectiveAudio,
      capabilities,
    );
    final burnSubtitle = _subtitleRequiresTranscode(
      streams,
      subtitleStreamIndex,
      capabilities,
    );
    final transcode =
        forceTranscode ||
        burnSubtitle ||
        videoNeedsTranscode ||
        audioNeedsTranscode ||
        (maxStreamingBitrate != null &&
            (plexInt(media['bitrate']) ?? 0) * 1000 > maxStreamingBitrate);
    for (final entry in [(audioStreamIndex, 2), (subtitleStreamIndex, 3)]) {
      final selected = entry.$1;
      if (selected != null &&
          selected >= 0 &&
          !streams.any(
            (s) =>
                plexInt(s['id']) == selected &&
                plexInt(s['streamType']) == entry.$2,
          )) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidResponse,
          detail: '所选轨道不属于分段',
        );
      }
    }
    if (audioStreamIndex != null || subtitleStreamIndex != null) {
      // Official PMS stream selection is a per-user Part operation. Stream IDs
      // on decision URLs alone do not change the server-selected tracks.
      await _get(
        '/library/parts/${Uri.encodeComponent(plexString(parts[location.index]['id']))}',
        method: 'PUT',
        query: {
          'audioStreamID': ?audioStreamIndex,
          if (subtitleStreamIndex != null)
            'subtitleStreamID': subtitleStreamIndex < 0
                ? 0
                : subtitleStreamIndex,
          'allParts': 0,
        },
      );
    }
    final query = <String, Object?>{
      'path': '/library/metadata/$itemId',
      'mediaIndex': index,
      'partIndex': location.index,
      'session': session,
      'X-Plex-Session-Identifier': session,
      'X-Plex-Client-Profile-Name': 'Generic',
      'protocol': 'hls',
      'directPlay': transcode ? 0 : 1,
      'directStream': videoNeedsTranscode ? 0 : 1,
      'directStreamAudio': audioNeedsTranscode ? 0 : 1,
      'offset': location.local.inMilliseconds / 1000,
      if (maxStreamingBitrate != null)
        'videoBitrate': maxStreamingBitrate ~/ 1000,
      if (maxStreamingBitrate != null)
        'peakBitrate': maxStreamingBitrate ~/ 1000,
      'subtitles': subtitleStreamIndex != null && subtitleStreamIndex < 0
          ? 'none'
          : burnSubtitle
          ? 'burn'
          : 'auto',
      'advancedSubtitles': burnSubtitle ? 'burn' : 'text',
    };
    final cleanupUri = _uri('/video/:/transcode/universal/stop', {
      'session': session,
    });
    final cleanupHeaders = Map<String, String>.from(sessionHeaders);
    final lease = PlaybackResourceLease(
      id: session,
      itemId: itemId,
      mediaSourceId: plexString(media['id']),
      release: () async {
        final response = await plexRequest(
          _dio,
          cleanupUri,
          headers: cleanupHeaders,
        );
        if ((response.statusCode ?? 0) >= 300) {
          throw const MediaServerException(
            MediaServerFailureKind.invalidResponse,
          );
        }
        _released(session);
      },
    );
    int? outputBitrate = plexInt(media['bitrate']) == null
        ? null
        : plexInt(media['bitrate'])! * 1000;
    PlayMethod method = PlayMethod.directPlay;
    Uri url = Uri.parse(timeline.parts[location.index].resource.url);
    var playbackStreams = streams.map(plexPlaybackStream).toList();
    if (transcode) {
      try {
        final decision = await _get(
          '/video/:/transcode/universal/decision',
          query: query,
        );
        final code = plexInt(decision['generalDecisionCode']);
        if (code == null) {
          throw const MediaServerException(
            MediaServerFailureKind.invalidResponse,
          );
        }
        if (code >= 2000) {
          throw const MediaServerException(
            MediaServerFailureKind.forbidden,
            detail: '服务器拒绝此次播放协商',
          );
        }
        final decided = plexList(decision['Metadata']);
        final decidedMedia = decided.isEmpty
            ? <Map<String, dynamic>>[]
            : plexList(decided.first['Media']);
        final selected = _selectedResponse(
          decidedMedia,
          plexString(media['id']),
        );
        final bitrate = plexInt(selected['bitrate']);
        outputBitrate = bitrate == null || bitrate <= 0 ? null : bitrate * 1000;
        if (maxStreamingBitrate != null &&
            bitrate != null &&
            bitrate * 1000 < maxStreamingBitrate &&
            (plexInt(media['bitrate']) ?? 0) * 1000 > maxStreamingBitrate) {
          throw const MediaServerException(
            MediaServerFailureKind.forbidden,
            detail: '服务器返回低于所选画质的转码',
          );
        }
        final decidedPart = _selectedResponse(
          plexList(selected['Part']),
          plexString(parts[location.index]['id']),
        );
        final decidedStreams = plexList(decidedPart['Stream']);
        if (decidedPart['decision'] == 'none') {
          throw const MediaServerException(MediaServerFailureKind.forbidden);
        }
        playbackStreams = plexNegotiatedStreams(
          streams,
          decidedStreams,
          audioId: audioId,
          subtitleId: subtitleId,
          resolveUrl: (key) => resolveResource(key).toString(),
          sidecarUrl: _uri('/video/:/transcode/universal/subtitles', {
            ...query,
            'protocol': 'http',
            'subtitles': 'sidecar',
          }).toString(),
        );
        method =
            decidedStreams.any(
              (stream) =>
                  stream['decision'] == 'transcode' ||
                  stream['decision'] == 'burn',
            )
            ? PlayMethod.transcode
            : selected['videoDecision'] == 'copy'
            ? PlayMethod.directStream
            : PlayMethod.transcode;
        url = _uri('/video/:/transcode/universal/start.m3u8', query);
      } catch (error) {
        try {
          await lease.release();
        } catch (_) {
          throw PlexPlaybackPreparationException(
            lease,
            error is MediaServerException
                ? error.kind
                : MediaServerFailureKind.invalidResponse,
          );
        }
        rethrow;
      }
    }
    final source = PlaybackMediaSource(
      id: plexString(media['id']),
      name: plexString(media['videoResolution']),
      container: media['container'] as String?,
      supportsDirectPlay: method == PlayMethod.directPlay,
      supportsDirectStream: method == PlayMethod.directStream,
      // PMS permits requesting a decision; permission/codec rejection remains
      // a real negotiation failure, independent of this session's direct mode.
      supportsTranscoding: true,
      directStreamUrl: method != PlayMethod.transcode ? url.toString() : null,
      transcodingUrl: method == PlayMethod.transcode ? url.toString() : null,
      runtime: plexDuration(media['duration'] ?? row['duration']),
      bitrate: plexInt(media['bitrate']) == null
          ? null
          : plexInt(media['bitrate'])! * 1000,
      defaultAudioStreamIndex: audioId,
      defaultSubtitleStreamIndex: subtitleId,
      mediaStreams: playbackStreams,
    );
    final effectiveLease = transcode
        ? lease
        : PlaybackResourceLease(
            id: session,
            itemId: itemId,
            mediaSourceId: source.id,
            release: () async {
              _released(session);
            },
          );
    _playbacks[session] = _Playback(
      itemId,
      source,
      method,
      url,
      timeline,
      auth,
      effectiveLease,
      location,
      outputBitrate,
    );
    // Sibling version tracks must describe the same global film position.
    // First-Part IDs are not valid inputs when a saved preference resumes Part 2.
    List<MediaStreamInfo> versionStreams(Map<String, dynamic> version) {
      final versionParts = plexList(version['Part']);
      var remaining = position;
      for (final part in versionParts) {
        final duration = plexDuration(part['duration']);
        if (remaining == Duration.zero ||
            (duration != null && remaining < duration)) {
          return plexList(part['Stream']).map(plexPlaybackStream).toList();
        }
        if (duration == null) return const [];
        remaining -= duration;
      }
      return const [];
    }

    return PlaybackInfo(
      playSessionId: session,
      mediaSources: [
        source,
        for (final version in versions)
          if (plexString(version['id']) != source.id)
            PlaybackMediaSource(
              id: plexString(version['id']),
              name: plexString(version['videoResolution']),
              container: version['container'] as String?,
              runtime: plexDuration(version['duration']),
              bitrate: plexInt(version['bitrate']) == null
                  ? null
                  : plexInt(version['bitrate'])! * 1000,
              mediaStreams: versionStreams(version),
            ),
      ],
      resources: effectiveLease,
    );
  }

  @override
  ResolvedPlayback? resolvePlayback({
    required PlaybackInfo info,
    required String itemId,
    String? mediaSourceId,
    bool forceTranscode = false,
  }) {
    _guard?.call();
    if (!hasSession) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    final playback = _playbacks[info.playSessionId];
    if (playback == null ||
        playback.itemId != itemId ||
        mediaSourceId != null && playback.source.id != mediaSourceId) {
      return null;
    }
    return PlexResolvedPlayback(
      playMethod: playback.method,
      outputBitrate: playback.outputBitrate,
      streamUrl: playback.url,
      playSessionId: info.playSessionId,
      mediaSource: playback.source,
      itemId: itemId,
      // A universal start URL addresses one Part, never a concatenated film.
      timeline: playback.method == PlayMethod.directPlay
          ? playback.timeline
          : null,
      filmTimeline: playback.timeline,
      partIndex: playback.position.index,
      partStartPosition: playback.position.local,
      streamStartsAtRequestedPosition: playback.method != PlayMethod.directPlay,
      authorization: playback.auth,
      resources: playback.lease,
    );
  }

  Future<void> _report(PlaybackReport report, String state) async {
    final playback = _playbacks[report.playSessionId];
    await _get(
      '/:/timeline',
      query: {
        'ratingKey': report.itemId,
        'key': '/library/metadata/${report.itemId}',
        'state': state,
        'time': report.position.inMilliseconds,
        'duration': playback?.source.runtime?.inMilliseconds,
        'session': report.playSessionId,
        'hasMDE': 1,
        'playbackTime': report.position.inMilliseconds,
      },
    );
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) =>
      _report(report, 'playing');
  @override
  Future<void> reportProgress(PlaybackReport report) =>
      _report(report, report.isPaused ? 'paused' : 'playing');
  @override
  Future<void> reportStopped(PlaybackReport report) =>
      _report(report, 'stopped');
  @override
  Future<void> releasePlayback(PlaybackReport report) async {
    if (_releasedSessions.contains(report.playSessionId)) return;
    final playback = _playbacks[report.playSessionId];
    if (playback != null) {
      await playback.lease.release();
      _playbacks.remove(report.playSessionId);
      return;
    }
    if (report.playMethod == PlayMethod.directPlay) return;
    // Recovery ends the recorded session only; no metadata/decision/start call.
    await _get(
      '/video/:/transcode/universal/stop',
      query: {'session': report.playSessionId},
    );
    _released(report.playSessionId);
  }

  @override
  Uri subtitleStreamUrl({
    required String itemId,
    required String mediaSourceId,
    required int index,
    String format = 'srt',
  }) {
    final media = plexList(
      _metadata[itemId]?['Media'],
    ).where((v) => plexString(v['id']) == mediaSourceId).firstOrNull;
    for (final part in plexList(media?['Part'])) {
      for (final stream in plexList(part['Stream'])) {
        if (plexInt(stream['id']) == index && stream['key'] is String) {
          return resolveResource(stream['key'] as String);
        }
      }
    }
    return _uri('/library/streams/$index', {'format': format});
  }
}

/// Plex Stream IDs belong to a Part. On a Part change, the player must request
/// new PlaybackInfo with the film startPosition and select tracks by language.
/// For transcodes [timeline] is null: [streamUrl] only plays [partIndex], starting
/// at [partStartPosition]. [filmTimeline] is for global-to-local mapping only;
/// its raw resources must not replace a selected transcode.
class PlexResolvedPlayback extends ResolvedPlayback {
  const PlexResolvedPlayback({
    required super.playMethod,
    required super.streamUrl,
    required super.playSessionId,
    required super.mediaSource,
    required super.itemId,
    super.timeline,
    super.authorization,
    super.resources,
    super.canRenewUrlInPlace = false,
    super.outputBitrate,
    required MediaTimeline filmTimeline,
    required super.partIndex,
    required super.partStartPosition,
    super.streamStartsAtRequestedPosition,
  }) : super(filmTimeline: filmTimeline);
  @override
  MediaTimeline get filmTimeline => super.filmTimeline!;
}

/// A failed preflight must not lose its cleanup handle when the server is
/// temporarily unable to stop it. The owner can retry this original lease;
/// retrying getPlaybackInfo would create a different session and is incorrect.
class PlexPlaybackPreparationException extends PlaybackPreparationException {
  const PlexPlaybackPreparationException(super.resources, super.kind);
}

bool _subtitleRequiresTranscode(
  List<Map<String, dynamic>> streams,
  int? index,
  PlaybackCapabilities? caps,
) {
  if (caps == null || (index != null && index < 0)) return false;
  final selected = streams
      .where(
        (s) =>
            plexInt(s['streamType']) == 3 &&
            (index != null
                ? plexInt(s['id']) == index
                : s['selected'] == 1 || s['selected'] == true),
      )
      .firstOrNull;
  return switch (selected?['codec']) {
    'pgs' || 'hdmv_pgs_subtitle' => !caps.pgs,
    'ass' => !caps.ass,
    'ssa' => !caps.ssa,
    _ => false,
  };
}

Map<String, dynamic>? _selectedStream(
  List<Map<String, dynamic>> streams,
  int type,
  int? id,
) {
  if (id != null && id < 0) return null;
  final candidates = streams
      .where((s) => plexInt(s['streamType']) == type)
      .toList();
  if (id != null) {
    return candidates.where((s) => plexInt(s['id']) == id).firstOrNull;
  }
  return candidates
          .where((s) => s['selected'] == true || s['selected'] == 1)
          .firstOrNull ??
      (type == 3 ? null : candidates.firstOrNull);
}

Map<String, dynamic> _selectedResponse(
  List<Map<String, dynamic>> values,
  String id,
) {
  final exact = values.where((row) => plexString(row['id']) == id).toList();
  if (exact.length == 1) return exact.single;
  final marked = values
      .where((row) => row['selected'] == true || row['selected'] == 1)
      .toList();
  if (marked.length == 1) return marked.single;
  if (values.length == 1) return values.single;
  throw const MediaServerException(
    MediaServerFailureKind.invalidResponse,
    detail: '播放协商未唯一指定媒体分段',
  );
}

bool _videoNeedsTranscode(
  List<Map<String, dynamic>> streams,
  PlaybackCapabilities? caps,
) {
  if (caps == null) return false;
  final codec = _selectedStream(streams, 1, null)?['codec'];
  return (codec == 'h264' && !caps.h264) || (codec == 'hevc' && !caps.hevc);
}

bool _audioNeedsTranscode(
  Map<String, dynamic>? selected,
  PlaybackCapabilities? caps,
) {
  if (caps == null) return false;
  return switch (selected?['codec']) {
    'aac' => !caps.aac,
    'ac3' => !caps.ac3,
    'eac3' => !caps.eac3,
    'dca' || 'dts' => !caps.dts,
    'truehd' => !caps.truehd,
    _ => false,
  };
}

class _IndexPreview implements MediaPreview {
  _IndexPreview(this.client, this.itemId, this.parts);
  final PlexClient client;
  @override
  final String itemId;
  final List<Map<String, dynamic>> parts;
  bool _closed = false;
  @override
  CapabilityStatus get availability => const CapabilityStatus(
    CapabilityAvailability.available,
    reason: '服务器已生成 Plex 视频预览索引',
  );
  @override
  Future<PreviewFrame?> frameAt(Duration position) async {
    if (_closed || position < Duration.zero) return null;
    var remaining = position;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final duration = plexDuration(part['duration']);
      if (duration == null && index < parts.length - 1) return null;
      if (duration == null ||
          remaining < duration ||
          index == parts.length - 1) {
        final bytes = await client.readAuthorizedBytes(
          client.resolveResource(
            '/library/parts/${Uri.encodeComponent(plexString(part['id']))}/indexes/sd/${remaining.inMilliseconds}',
          ),
          maxBytes: 8 * 1024 * 1024,
        );
        return _closed ? null : PreviewFrame(bytes: Uint8List.fromList(bytes));
      }
      remaining -= duration;
    }
    return null;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

class _Playback {
  _Playback(
    this.itemId,
    this.source,
    this.method,
    this.url,
    this.timeline,
    this.auth,
    this.lease,
    this.position,
    this.outputBitrate,
  );
  final String itemId;
  final PlaybackMediaSource source;
  final PlayMethod method;
  final Uri url;
  final MediaTimeline timeline;
  final ResourceAuthorization auth;
  final PlaybackResourceLease lease;
  final PartPosition position;
  final int? outputBitrate;
}

class _ChapterPreview implements MediaPreview {
  _ChapterPreview(this.client, this.itemId, this.chapters);
  final PlexClient client;
  @override
  final String itemId;
  final List<ItemChapter> chapters;
  bool _closed = false;
  @override
  CapabilityStatus get availability => const CapabilityStatus(
    CapabilityAvailability.available,
    reason: '实际章节缩略图',
  );
  @override
  Future<PreviewFrame?> frameAt(Duration position) async {
    if (_closed) return null;
    final chapter = chapters
        .where((c) => c.startPosition <= position)
        .lastOrNull;
    if (chapter == null) return null;
    final bytes = await client.readAuthorizedBytes(
      client.resolveResource(chapter.imageTag!),
      maxBytes: 8 * 1024 * 1024,
    );
    return _closed ? null : PreviewFrame(bytes: Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
