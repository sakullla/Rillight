import 'package:flutter/foundation.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/shelf_sort.dart';

/// 横排首屏条数，与首页继续观看的默认 Limit 一致。
const aggregationRowLimit = 24;

/// 剧集写出季集，电影和其它条目写出年份。
String? aggregationContinueCaption(EmbyItem item) {
  if (item.isEpisode) {
    return seasonEpisodeCode(item);
  }
  final year = item.productionYear;
  if (year == null) {
    return null;
  }
  return '$year';
}

/// 一台服务器上的继续播放、收藏或媒体库。
class ServerSectionSlice {
  const ServerSectionSlice({
    this.items = const [],
    this.error,
    this.loading = false,
  });

  final List<EmbyItem> items;
  final EmbyException? error;
  final bool loading;

  ServerSectionSlice copyWith({
    List<EmbyItem>? items,
    EmbyException? error,
    bool clearError = false,
    bool? loading,
  }) {
    return ServerSectionSlice(
      items: items ?? this.items,
      error: clearError ? null : error ?? this.error,
      loading: loading ?? this.loading,
    );
  }
}

/// 一台已登录普通服务器的三段数据。
class ServerSections {
  const ServerSections({
    required this.serverId,
    required this.serverName,
    this.account,
    this.continueWatching = const ServerSectionSlice(),
    this.favorites = const ServerSectionSlice(),
    this.libraries = const ServerSectionSlice(),
  });

  final String serverId;
  final String serverName;
  final SourceAccount? account;
  final ServerSectionSlice continueWatching;
  final ServerSectionSlice favorites;
  final ServerSectionSlice libraries;

  bool get failed =>
      continueWatching.error != null ||
      favorites.error != null ||
      libraries.error != null;

  ServerSections copyWith({
    SourceAccount? account,
    ServerSectionSlice? continueWatching,
    ServerSectionSlice? favorites,
    ServerSectionSlice? libraries,
  }) {
    return ServerSections(
      serverId: serverId,
      serverName: serverName,
      account: account ?? this.account,
      continueWatching: continueWatching ?? this.continueWatching,
      favorites: favorites ?? this.favorites,
      libraries: libraries ?? this.libraries,
    );
  }
}

/// 按已登录普通服务器分别取继续播放、收藏和电影剧集库。
///
/// 不读取 participates、scopeKnown 或 libraryIds。某一台或其中一段失败时，
/// 其它服务器已有结果保留，[retry] 只重拉这一台。
class ServerSectionsLoader extends ChangeNotifier {
  ServerSectionsLoader({required this.registry});

  final SourceSessionRegistry registry;

  List<ServerSections> _servers = const [];
  List<String> _order = const [];
  final Map<String, int> _attempt = {};
  int _generation = 0;
  bool _disposed = false;
  bool loading = false;

  List<ServerSections> get servers => List.unmodifiable(_servers);

  /// 重新拉取当前全部已登录普通服务器。未登录的不占结果。
  Future<void> load() async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    await registry.load();
    if (_disposed || generation != _generation) {
      return;
    }
    final targets = registry.project(AccessRegion.ordinary);
    _order = [for (final server in targets) server.id];
    _attempt
      ..clear()
      ..addEntries(targets.map((server) => MapEntry(server.id, 0)));
    _servers = const [];
    loading = true;
    _notify();
    await Future.wait(targets.map((server) => _publish(server, generation, 0)));
    if (_disposed || generation != _generation) {
      return;
    }
    loading = false;
    _notify();
  }

  /// 只重拉 [serverId]。其它服务器的结果保持不动。
  Future<void> retry(String serverId) async {
    if (_disposed) {
      return;
    }
    final generation = _generation;
    final server = registry
        .project(AccessRegion.ordinary)
        .where((item) => item.id == serverId)
        .firstOrNull;
    if (server == null) {
      return;
    }
    final attempt = (_attempt[serverId] ?? 0) + 1;
    _attempt[serverId] = attempt;
    _markLoading(serverId);
    await _publish(server, generation, attempt);
  }

  Future<void> _publish(SavedServer server, int generation, int attempt) async {
    final result = await _fetch(server);
    if (!_current(generation, server.id, attempt)) {
      return;
    }
    if (result == null) {
      _servers = [
        for (final item in _servers)
          if (item.serverId != server.id) item,
      ];
    } else {
      _replace(result);
    }
    _notify();
  }

  void _replace(ServerSections section) {
    final map = {for (final item in _servers) item.serverId: item};
    map[section.serverId] = section;
    final order = _order.contains(section.serverId)
        ? _order
        : [..._order, section.serverId];
    _servers = [
      for (final id in order)
        if (map.containsKey(id)) map[id]!,
    ];
  }

  void _markLoading(String serverId) {
    final index = _servers.indexWhere((item) => item.serverId == serverId);
    if (index < 0) {
      return;
    }
    final current = _servers[index];
    final next = current.copyWith(
      continueWatching: current.continueWatching.copyWith(
        loading: true,
        clearError: true,
      ),
      favorites: current.favorites.copyWith(loading: true, clearError: true),
      libraries: current.libraries.copyWith(loading: true, clearError: true),
    );
    _servers = [..._servers]..[index] = next;
    _notify();
  }

  Future<ServerSections?> _fetch(SavedServer server) async {
    final SourceSession session;
    try {
      session = await registry.authenticate(server.id);
    } on StateError catch (error) {
      if (error.message == 'Login required') {
        return null;
      }
      return _failed(server, error);
    } catch (error) {
      return _failed(server, error);
    }
    final slices = await Future.wait([
      _continueWatching(session.client),
      _favorites(session.client),
      _libraries(session.client),
    ]);
    return ServerSections(
      serverId: server.id,
      serverName: server.displayName,
      account: session.account,
      continueWatching: slices[0],
      favorites: slices[1],
      libraries: slices[2],
    );
  }

  ServerSections _failed(SavedServer server, Object error) {
    final slice = ServerSectionSlice(error: _asEmby(error));
    return ServerSections(
      serverId: server.id,
      serverName: server.displayName,
      continueWatching: slice,
      favorites: slice,
      libraries: slice,
    );
  }

  Future<ServerSectionSlice> _continueWatching(EmbyClient client) async {
    Object? resumeError;
    Object? nextError;
    var resume = const <EmbyItem>[];
    var nextUp = const <EmbyItem>[];
    await Future.wait([
      () async {
        try {
          resume = (await client.getResumeItems(
            limit: aggregationRowLimit,
          )).where((item) => item.isResumeMedia).toList();
        } catch (error) {
          resumeError = error;
        }
      }(),
      () async {
        try {
          nextUp = (await client.getNextUp(
            limit: aggregationRowLimit,
          )).where((item) => item.isEpisode).toList();
        } on EmbyException catch (error) {
          if (!_nextUpUnsupported(error)) {
            nextError = error;
          }
        } catch (error) {
          nextError = error;
        }
      }(),
    ]);
    final items = continueWatchingItems(resume, nextUp);
    if (items.isEmpty) {
      final failure = resumeError ?? nextError;
      if (failure != null) {
        return ServerSectionSlice(error: _asEmby(failure));
      }
    }
    return ServerSectionSlice(items: items);
  }

  Future<ServerSectionSlice> _favorites(EmbyClient client) async {
    try {
      final page = await client.queryItems(
        includeItemTypes: 'Movie,Series',
        recursive: true,
        limit: aggregationRowLimit,
        filters: [CatalogWatchFilter.favorite.param!],
        fields: EmbyClient.gridFields,
      );
      return ServerSectionSlice(
        items: [
          for (final item in page.items)
            if (item.isMovieOrSeries) item,
        ],
      );
    } catch (error) {
      return ServerSectionSlice(error: _asEmby(error));
    }
  }

  Future<ServerSectionSlice> _libraries(EmbyClient client) async {
    try {
      final views = await client.getViews();
      final libraries = <EmbyItem>[];
      for (var start = 0; start < views.length; start += 3) {
        final group = views.skip(start).take(3).toList();
        final accepted = await Future.wait(
          group.map((view) => _isMovieOrTvLibrary(client, view)),
        );
        for (var index = 0; index < group.length; index++) {
          if (accepted[index]) {
            libraries.add(group[index]);
          }
        }
      }
      return ServerSectionSlice(items: libraries);
    } catch (error) {
      return ServerSectionSlice(error: _asEmby(error));
    }
  }

  /// 与首页 Views 的电影剧集判定相同。照片和音乐不进入聚合视界。
  Future<bool> _isMovieOrTvLibrary(EmbyClient client, EmbyItem view) async {
    if (view.isMovieOrTvCollection) {
      return true;
    }
    if (view.isExcludedCollection || !view.isUntypedCollection) {
      return false;
    }
    try {
      final children = await client.getItems(
        parentId: view.id,
        recursive: true,
        limit: 40,
      );
      if (children.isEmpty) {
        return false;
      }
      const allowed = {
        'Movie',
        'Series',
        'Season',
        'Episode',
        'Folder',
        'CollectionFolder',
        'BoxSet',
      };
      const video = {'Movie', 'Series', 'Episode'};
      return children.every((item) => allowed.contains(item.type)) &&
          children.any((item) => video.contains(item.type));
    } on EmbyException {
      return false;
    }
  }

  bool _nextUpUnsupported(EmbyException error) {
    final code = error.statusCode;
    return code == 404 || code == 400 || code == 501;
  }

  EmbyException _asEmby(Object error) {
    if (error is EmbyException) {
      return error;
    }
    return EmbyException(EmbyFailureKind.unknown, cause: error);
  }

  bool _current(int generation, String serverId, int attempt) =>
      !_disposed && generation == _generation && _attempt[serverId] == attempt;

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
