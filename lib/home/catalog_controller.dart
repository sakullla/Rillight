import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

class CatalogRowState {
  const CatalogRowState({
    this.items = const [],
    this.loading = false,
    this.hidden = false,
    this.error,
  });

  final List<EmbyItem> items;
  final bool loading;
  final bool hidden;
  final EmbyException? error;
}

class CatalogController extends ChangeNotifier {
  CatalogController({required this.auth}) {
    _sessionKey = _currentSessionKey;
    auth.addListener(_onAuthChanged);
  }

  final AuthController auth;

  CatalogRowState resume = const CatalogRowState(loading: true);
  CatalogRowState nextUp = const CatalogRowState(loading: true);
  CatalogRowState latestMovies = const CatalogRowState(loading: true);
  CatalogRowState latestSeries = const CatalogRowState(loading: true);
  List<EmbyItem> libraries = const [];
  EmbyException? librariesError;
  bool librariesLoading = true;

  int _loadGen = 0;
  bool _disposed = false;
  String? _sessionKey;
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryCounts = {};

  EmbyClient get client => auth.client;

  Future<void> reload({bool includeLibraries = true}) async {
    if (_disposed || !auth.isLoggedIn) {
      return;
    }
    final gen = ++_loadGen;
    _clearRetries();
    _sessionKey = _currentSessionKey;
    resume = const CatalogRowState(loading: true);
    nextUp = const CatalogRowState(loading: true);
    latestMovies = const CatalogRowState(loading: true);
    latestSeries = const CatalogRowState(loading: true);
    if (includeLibraries) {
      librariesLoading = true;
      librariesError = null;
    }
    _notify();

    final tasks = <Future<void>>[
      _loadResume(gen),
      _loadNextUp(gen),
      _loadLatestMovies(gen),
      _loadLatestSeries(gen),
    ];
    if (includeLibraries) {
      tasks.add(_loadLibraries(gen));
    }
    await Future.wait(tasks);
  }

  Future<void> reloadHomeRows() => reload(includeLibraries: false);

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
      return;
    }
    final key = _currentSessionKey;
    if (key != _sessionKey) {
      reload();
    }
  }

  String get _currentSessionKey {
    final session = auth.session;
    if (session == null) {
      return '';
    }
    final line = session.server.activeLine;
    return '${session.server.id}|${session.userId}|${line?.id ?? ''}|${line?.address ?? session.server.baseUrl}';
  }

  Future<void> _loadResume(int gen) async {
    try {
      final items = (await client.getResumeItems())
          .where((item) => item.isResumeMedia)
          .toList();
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
      resume = const CatalogRowState(loading: true);
      _scheduleRetry('resume', _loadResume);
    }
    _notify();
  }

  Future<void> _loadNextUp(int gen) async {
    try {
      final items = (await client.getNextUp())
          .where((item) => item.isEpisode)
          .toList();
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
        nextUp = const CatalogRowState(loading: true);
        _scheduleRetry('nextUp', _loadNextUp);
      }
    }
    _notify();
  }

  Future<void> _loadLatestMovies(int gen) async {
    try {
      final items = (await client.getItems(
        includeItemTypes: 'Movie',
        recursive: true,
        limit: 24,
        sortBy: 'DateLastContentAdded',
        sortOrder: 'Descending',
        fields: EmbyClient.gridFields,
      )).where((item) => item.isMovie).toList();
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
      latestMovies = const CatalogRowState(loading: true);
      _scheduleRetry('latestMovies', _loadLatestMovies);
    }
    _notify();
  }

  Future<void> _loadLatestSeries(int gen) async {
    try {
      final items = (await client.getItems(
        includeItemTypes: 'Series',
        recursive: true,
        limit: 24,
        sortBy: 'DateLastContentAdded',
        sortOrder: 'Descending',
        fields: EmbyClient.gridFields,
      )).where((item) => item.isSeries).toList();
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
      latestSeries = const CatalogRowState(loading: true);
      _scheduleRetry('latestSeries', _loadLatestSeries);
    }
    _notify();
  }

  Future<void> _loadLibraries(int gen) async {
    try {
      final views = await client.getViews();
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
      librariesLoading = false;
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      libraries = const [];
      librariesError = _asEmby(error);
      librariesLoading = false;
    }
    _notify();
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

  void _scheduleRetry(String key, Future<void> Function(int gen) load) {
    _retryTimers[key]?.cancel();
    final attempt = (_retryCounts[key] ?? 0) + 1;
    _retryCounts[key] = attempt;
    final seconds = attempt == 1
        ? 2
        : attempt == 2
        ? 6
        : 20;
    _retryTimers[key] = Timer(Duration(seconds: seconds), () {
      if (_disposed || !auth.isLoggedIn) {
        return;
      }
      unawaited(load(_loadGen));
    });
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
