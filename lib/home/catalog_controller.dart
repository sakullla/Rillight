import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

class CatalogRowState {
  const CatalogRowState({
    this.items = const [],
    this.loading = false,
    this.hidden = false,
    this.error,
    this.notice,
  });

  final List<EmbyItem> items;
  final bool loading;
  final bool hidden;
  final EmbyException? error;

  /// 已有内容仍可用时的局部刷新提示;不改变 [error] 的失败态契约。
  final EmbyException? notice;
}

class CatalogController extends ChangeNotifier {
  CatalogController({required this.auth, CatalogCache? cache})
    : cache = cache ?? CatalogCache() {
    _sessionKey = _currentSessionKey;
    _syncCacheSession();
    auth.addListener(_onAuthChanged);
  }

  final AuthController auth;

  /// 目录数据缓存层:先显后刷、TTL 兜底、磁盘持久化。
  final CatalogCache cache;

  CatalogRowState resume = const CatalogRowState(loading: true);
  CatalogRowState nextUp = const CatalogRowState(loading: true);
  CatalogRowState latestMovies = const CatalogRowState(loading: true);
  CatalogRowState latestSeries = const CatalogRowState(loading: true);
  List<EmbyItem> libraries = const [];
  EmbyException? librariesError;
  EmbyException? librariesNotice;
  bool librariesLoading = true;

  int _loadGen = 0;
  bool _disposed = false;
  String? _sessionKey;
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryCounts = {};

  EmbyClient get client => auth.client;

  /// 重拉全部/首页行数据。
  ///
  /// [showCachedFirst] 为「先显后刷」:先显命中缓存立即渲染,同时后台重拉,
  /// 完成后无感更新;手动刷新入口传 false 绕过缓存先显直接重拉。
  /// 无论如何 [CatalogCache.fetch] 总是走网络并写穿缓存。
  Future<void> reload({
    bool includeLibraries = true,
    bool showCachedFirst = true,
  }) async {
    if (_disposed || !auth.isLoggedIn) {
      return;
    }
    final gen = ++_loadGen;
    _clearRetries();
    final sameSession = _sessionKey == _currentSessionKey;
    _sessionKey = _currentSessionKey;
    _syncCacheSession();
    CatalogRowState refreshing(CatalogRowState current) =>
        !sameSession || current.items.isEmpty
        ? const CatalogRowState(loading: true)
        : CatalogRowState(items: current.items);
    resume = refreshing(resume);
    nextUp = refreshing(nextUp);
    latestMovies = refreshing(latestMovies);
    latestSeries = refreshing(latestSeries);
    if (includeLibraries) {
      if (!sameSession) libraries = const [];
      librariesLoading = true;
      librariesError = null;
      librariesNotice = null;
    }
    _notify();

    final tasks = <Future<void>>[
      _loadResume(gen, showCachedFirst),
      _loadNextUp(gen, showCachedFirst),
      _loadLatestMovies(gen, showCachedFirst),
      _loadLatestSeries(gen, showCachedFirst),
    ];
    if (includeLibraries) {
      tasks.add(_loadLibraries(gen, showCachedFirst));
    }
    await Future.wait(tasks);
  }

  /// 刷新首页行(不含片库列表)。播放器关闭/标记已看等事件走此路径,
  /// 属刷新事件:直接重拉,不做缓存先显。
  Future<void> reloadHomeRows() =>
      reload(includeLibraries: false, showCachedFirst: false);

  Future<void> hideFromResume(EmbyItem item) async {
    await client.hideFromResume(item.id);
    final remaining = [
      for (final entry in resume.items)
        if (entry.id != item.id) entry,
    ];
    resume = remaining.isEmpty
        ? const CatalogRowState(hidden: true)
        : CatalogRowState(items: remaining);
    _notify();
  }

  void _onAuthChanged() {
    if (!auth.isLoggedIn) {
      _sessionKey = null;
      _syncCacheSession();
      return;
    }
    final key = _currentSessionKey;
    if (key != _sessionKey) {
      reload();
    }
  }

  void _syncCacheSession() {
    final session = auth.session;
    if (session == null) {
      cache.detachSession();
      return;
    }
    cache.attachSession(serverId: session.server.id, userId: session.userId);
  }

  String get _currentSessionKey {
    final session = auth.session;
    if (session == null) {
      return '';
    }
    final line = session.server.activeLine;
    return '${session.server.id}|${session.userId}|${line?.id ?? ''}|${line?.address ?? session.server.baseUrl}';
  }

  bool _rowHasContent(CatalogRowState state) => state.items.isNotEmpty;

  /// 先显:命中缓存且当前行没有可显示内容时立即渲染,后台重拉随后无感更新。
  Future<void> _showCachedRow(
    String key,
    CatalogRequest request,
    bool Function(EmbyItem item) filter,
    int gen,
    CatalogRowState Function() current,
    void Function(CatalogRowState) assign,
  ) async {
    if (gen != _loadGen || _rowHasContent(current())) {
      return;
    }
    final hit = await cache.lookup(request);
    if (gen != _loadGen || hit == null || _rowHasContent(current())) {
      return;
    }
    final items = parseCatalogPage(hit.json).items.where(filter).toList();
    assign(
      items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items),
    );
    _clearRetry(key);
    _notify();
  }

  Future<void> _loadResume(int gen, bool showCachedFirst) async {
    final request = catalogResumeRequest(userId: client.userId ?? '');
    if (showCachedFirst) {
      await _showCachedRow(
        'resume',
        request,
        (item) => item.isResumeMedia,
        gen,
        () => resume,
        (state) => resume = state,
      );
    }
    try {
      final items = parseCatalogPage(
        await cache.fetch(client, request),
      ).items.where((item) => item.isResumeMedia).toList();
      if (gen != _loadGen) {
        return;
      }
      resume = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
      _clearRetry('resume');
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      resume = _failRow(
        'resume',
        error,
        resume,
        (gen) => _loadResume(gen, false),
      );
    }
    _notify();
  }

  Future<void> _loadNextUp(int gen, bool showCachedFirst) async {
    final request = catalogNextUpRequest(userId: client.userId ?? '');
    if (showCachedFirst) {
      await _showCachedRow(
        'nextUp',
        request,
        (item) => item.isEpisode,
        gen,
        () => nextUp,
        (state) => nextUp = state,
      );
    }
    try {
      final items = parseCatalogPage(
        await cache.fetch(client, request),
      ).items.where((item) => item.isEpisode).toList();
      if (gen != _loadGen) {
        return;
      }
      nextUp = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
      _clearRetry('nextUp');
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      final mapped = _asEmby(error);
      if (_isNextUpUnsupported(mapped)) {
        nextUp = const CatalogRowState(hidden: true);
        _clearRetry('nextUp');
      } else {
        nextUp = _failRow(
          'nextUp',
          mapped,
          nextUp,
          (gen) => _loadNextUp(gen, false),
        );
      }
    }
    _notify();
  }

  Future<void> _loadLatestMovies(int gen, bool showCachedFirst) async {
    final request = catalogItemsRequest(
      userId: client.userId ?? '',
      includeItemTypes: 'Movie',
      recursive: true,
      limit: 24,
      sortBy: 'DateLastContentAdded',
      sortOrder: 'Descending',
      fields: EmbyClient.gridFields,
    );
    if (showCachedFirst) {
      await _showCachedRow(
        'latestMovies',
        request,
        (item) => item.isMovie,
        gen,
        () => latestMovies,
        (state) => latestMovies = state,
      );
    }
    try {
      final items = parseCatalogPage(
        await cache.fetch(client, request),
      ).items.where((item) => item.isMovie).toList();
      if (gen != _loadGen) {
        return;
      }
      latestMovies = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
      _clearRetry('latestMovies');
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      latestMovies = _failRow(
        'latestMovies',
        error,
        latestMovies,
        (gen) => _loadLatestMovies(gen, false),
      );
    }
    _notify();
  }

  Future<void> _loadLatestSeries(int gen, bool showCachedFirst) async {
    final request = catalogItemsRequest(
      userId: client.userId ?? '',
      includeItemTypes: 'Series',
      recursive: true,
      limit: 24,
      sortBy: 'DateLastContentAdded',
      sortOrder: 'Descending',
      fields: EmbyClient.gridFields,
    );
    if (showCachedFirst) {
      await _showCachedRow(
        'latestSeries',
        request,
        (item) => item.isSeries,
        gen,
        () => latestSeries,
        (state) => latestSeries = state,
      );
    }
    try {
      final items = parseCatalogPage(
        await cache.fetch(client, request),
      ).items.where((item) => item.isSeries).toList();
      if (gen != _loadGen) {
        return;
      }
      latestSeries = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
      _clearRetry('latestSeries');
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      latestSeries = _failRow(
        'latestSeries',
        error,
        latestSeries,
        (gen) => _loadLatestSeries(gen, false),
      );
    }
    _notify();
  }

  Future<void> _loadLibraries(int gen, bool showCachedFirst) async {
    final request = catalogViewsRequest(userId: client.userId ?? '');
    if (showCachedFirst) {
      final hit = await cache.lookup(request);
      if (gen == _loadGen &&
          hit != null &&
          librariesLoading &&
          libraries.isEmpty) {
        final views = parseCatalogPage(hit.json).items;
        final cached = <EmbyItem>[];
        for (final view in views) {
          if (view.isMovieOrTvCollection) {
            cached.add(view);
          }
        }
        // 缓存的 Views 只能恢复可判定的媒体库;探测类结果留给网络刷新。
        if (cached.isNotEmpty || views.every(_isDeterministicView)) {
          libraries = cached;
          librariesError = null;
          librariesLoading = false;
          _notify();
        }
      }
    }
    try {
      final views = parseCatalogPage(await cache.fetch(client, request)).items;
      final libraries = <EmbyItem>[];
      for (final view in views) {
        if (await _isMovieOrTvLibrary(view)) {
          libraries.add(view);
        }
      }
      if (gen != _loadGen) {
        return;
      }
      this.libraries = libraries;
      librariesError = null;
      librariesNotice = null;
      librariesLoading = false;
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      if (libraries.isEmpty) {
        librariesError = _asEmby(error);
        librariesLoading = false;
      } else {
        librariesNotice = _asEmby(error);
        librariesLoading = false;
      }
      // 已有缓存内容时保留显示,不打断导航。
    }
    _notify();
  }

  /// Views 缓存恢复用:类型可本地判定的视图(媒体库/排除集合),
  /// 无需依赖 _isMovieOrTvLibrary 的网络探测。
  bool _isDeterministicView(EmbyItem view) {
    return view.isMovieOrTvCollection ||
        view.isExcludedCollection ||
        !view.isUntypedCollection;
  }

  EmbyException _asEmby(Object error) {
    if (error is EmbyException) {
      return error;
    }
    return EmbyException(EmbyFailureKind.unknown, cause: error);
  }

  Future<bool> _isMovieOrTvLibrary(EmbyItem view) async {
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

  /// 首页行请求失败后的状态:已有可显示内容时原样保留并静默重试;
  /// 否则在 [quietRetryDelays] 未耗尽前保持骨架屏,耗尽后转为 `error`,
  /// 由货架渲染错误与「重试」入口(重试走 [reloadHomeRows])。
  CatalogRowState _failRow(
    String key,
    Object error,
    CatalogRowState current,
    Future<void> Function(int gen) load,
  ) {
    final scheduled = _scheduleRetry(key, load);
    if (_rowHasContent(current)) {
      return CatalogRowState(items: current.items, notice: _asEmby(error));
    }
    if (scheduled) {
      return const CatalogRowState(loading: true);
    }
    return CatalogRowState(error: _asEmby(error));
  }

  /// 静默重试节拍:三次后耗尽,不再自动重试。
  static const List<Duration> quietRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 6),
    Duration(seconds: 20),
  ];

  /// 为 [key] 安排下一次静默重试;计划已耗尽时返回 false 并清除计数,
  /// 下一次 [reload] 从头开始节拍。
  bool _scheduleRetry(String key, Future<void> Function(int gen) load) {
    _retryTimers.remove(key)?.cancel();
    final attempt = (_retryCounts[key] ?? 0) + 1;
    if (attempt > quietRetryDelays.length) {
      _retryCounts.remove(key);
      return false;
    }
    _retryCounts[key] = attempt;
    _retryTimers[key] = Timer(quietRetryDelays[attempt - 1], () {
      if (_disposed || !auth.isLoggedIn) {
        return;
      }
      unawaited(load(_loadGen));
    });
    return true;
  }

  void _clearRetry(String key) {
    _retryTimers.remove(key)?.cancel();
    _retryCounts.remove(key);
  }

  void _clearRetries() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryCounts.clear();
  }

  bool _isNextUpUnsupported(EmbyException error) {
    final code = error.statusCode;
    return code == 404 || code == 400 || code == 501;
  }

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGen++;
    _clearRetries();
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
