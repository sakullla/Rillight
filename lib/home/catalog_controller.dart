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
  String? _sessionKey;

  EmbyClient get client => auth.client;

  Future<void> reload({bool includeLibraries = true}) async {
    if (!auth.isLoggedIn) {
      return;
    }
    final gen = ++_loadGen;
    _sessionKey = _currentSessionKey;
    resume = const CatalogRowState(loading: true);
    nextUp = const CatalogRowState(loading: true);
    latestMovies = const CatalogRowState(loading: true);
    latestSeries = const CatalogRowState(loading: true);
    if (includeLibraries) {
      librariesLoading = true;
      librariesError = null;
    }
    notifyListeners();

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
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      resume = CatalogRowState(error: _asEmby(error));
    }
    notifyListeners();
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
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      final mapped = _asEmby(error);
      if (_isNextUpUnsupported(mapped)) {
        nextUp = const CatalogRowState(hidden: true);
      } else {
        nextUp = CatalogRowState(error: mapped);
      }
    }
    notifyListeners();
  }

  Future<void> _loadLatestMovies(int gen) async {
    try {
      final items = (await client.getLatestItems(
        includeItemTypes: 'Movie',
      )).where((item) => item.isMovie).toList();
      if (gen != _loadGen) {
        return;
      }
      latestMovies = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      latestMovies = CatalogRowState(error: _asEmby(error));
    }
    notifyListeners();
  }

  Future<void> _loadLatestSeries(int gen) async {
    try {
      final items = (await client.getLatestItems(
        includeItemTypes: 'Episode',
        groupItems: true,
      )).where((item) => item.isSeries || item.isEpisode).toList();
      if (gen != _loadGen) {
        return;
      }
      latestSeries = items.isEmpty
          ? const CatalogRowState(hidden: true)
          : CatalogRowState(items: items);
    } catch (error) {
      if (gen != _loadGen) {
        return;
      }
      latestSeries = CatalogRowState(error: _asEmby(error));
    }
    notifyListeners();
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
    notifyListeners();
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

  bool _isNextUpUnsupported(EmbyException error) {
    final code = error.statusCode;
    return code == 404 || code == 400 || code == 501;
  }

  @override
  void dispose() {
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
