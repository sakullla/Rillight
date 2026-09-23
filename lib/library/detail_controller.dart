import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/detail_repository.dart';

class DetailController extends ChangeNotifier {
  DetailController({
    required this.auth,
    required CatalogCache cache,
    required this.itemId,
    this.seasonId,
  }) : repository = DetailRepository(auth.client, cache) {
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
  final AuthController auth;
  final DetailRepository repository;
  final String itemId;
  EmbyItem? item;
  List<EmbyItem> seasons = const [], episodes = const [];
  String? seasonId, mediaSourceId;
  EmbyException? error, episodeError;
  bool loading = true, episodesLoading = false, hasMore = false;

  /// 续播集在已加载页之外时记住它。列表仍停在当前页，主操作不退回第一条。
  EmbyItem? resumeBeyondPage;
  int _revision = 0, _seasonRevision = 0, _offset = 0;
  bool _disposed = false;
  late Object _identity;
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _revision++;
    _seasonRevision++;
    item = null;
    seasons = episodes = const [];
    seasonId = mediaSourceId = null;
    resumeBeyondPage = null;
    error = episodeError = null;
    loading = episodesLoading = hasMore = false;
    _offset = 0;
    notifyListeners();
  }

  Future<void> load() async {
    final revision = ++_revision;
    _seasonRevision++;
    episodesLoading = false;
    final identity = _identity;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await repository.item(itemId);
      if (_disposed || revision != _revision || identity != _identity) return;
      item = result;
      mediaSourceId ??= result.mediaSources.firstOrNull?.id;
      if (result.isSeries) {
        final loaded = await repository.seasons(result.id);
        if (_disposed || revision != _revision || identity != _identity) return;
        seasons = loaded;
        final selected = seasons.any((s) => s.id == seasonId)
            ? seasonId
            : seasons.firstOrNull?.id;
        if (selected != null) await selectSeason(selected);
      }
    } catch (failure) {
      if (_disposed || revision != _revision || identity != _identity) return;
      error = _failure(failure);
    }
    if (_disposed || revision != _revision) return;
    loading = false;
    notifyListeners();
  }

  Future<void> selectSeason(String id, {bool more = false}) async {
    if (more && (episodesLoading || !hasMore)) return;
    final revision = ++_seasonRevision;
    final identity = _identity;
    final start = more ? _offset : 0;
    if (!more) {
      _offset = 0;
      hasMore = false;
    }
    if (seasonId != id) {
      episodes = const [];
      resumeBeyondPage = null;
    }
    seasonId = id;
    episodesLoading = true;
    episodeError = null;
    notifyListeners();
    try {
      final page = await repository.episodes(id, start: start);
      if (_disposed || revision != _seasonRevision || identity != _identity) {
        return;
      }
      episodes = {
        for (final episode in [
          ...(more ? episodes : <EmbyItem>[]),
          ...page.items,
        ])
          episode.id: episode,
      }.values.toList();
      _offset = start + page.items.length;
      hasMore = page.totalRecordCount == null
          ? page.items.length == 50
          : _offset < page.totalRecordCount!;
    } catch (failure) {
      if (_disposed || revision != _seasonRevision || identity != _identity) {
        return;
      }
      episodeError = _failure(failure);
    }
    if (_disposed || revision != _seasonRevision) return;
    episodesLoading = false;
    notifyListeners();
  }

  EmbyItem? get playTarget {
    final current = item;
    if (current == null) return null;
    if (!current.isSeries) return current;
    for (final episode in episodes) {
      if (episode.canResume) return episode;
    }
    final beyond = resumeBeyondPage;
    if (beyond != null &&
        beyond.canResume &&
        _inSelectedSeason(beyond) &&
        episodes.every((episode) => episode.id != beyond.id)) {
      return beyond;
    }
    return episodes.where((e) => !e.userData.played).firstOrNull ??
        episodes.firstOrNull;
  }

  bool _inSelectedSeason(EmbyItem episode) {
    final season = seasonId;
    if (season == null || season.isEmpty) return false;
    return episode.seasonId == season || episode.parentId == season;
  }

  /// 当前页没有续播集、且后面还有分集时，向后查找并记住那一集。
  /// 不把后续页并进 [episodes]。
  Future<void> retainOffPageResume() async {
    final season = seasonId;
    if (_disposed || season == null || item?.isSeries != true) return;
    if (episodes.any((episode) => episode.canResume) || !hasMore) {
      if (resumeBeyondPage != null) {
        resumeBeyondPage = null;
        notifyListeners();
      }
      return;
    }
    final revision = _seasonRevision;
    final identity = _identity;
    var start = _offset;
    EmbyItem? found;
    while (found == null) {
      final page = await repository.episodes(season, start: start);
      if (_disposed || revision != _seasonRevision || identity != _identity) {
        return;
      }
      found = page.items.where((episode) => episode.canResume).firstOrNull;
      final loaded = page.items.length;
      if (found != null || loaded == 0) break;
      start += loaded;
      final total = page.totalRecordCount;
      final more = total == null ? loaded == 50 : start < total;
      if (!more) break;
    }
    if (_disposed || revision != _seasonRevision || identity != _identity) {
      return;
    }
    resumeBeyondPage = found;
    notifyListeners();
  }

  void selectSource(String id) {
    mediaSourceId = id;
    notifyListeners();
  }

  EmbyException _failure(Object value) => value is EmbyException
      ? value
      : EmbyException(EmbyFailureKind.unknown, cause: value);
  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _seasonRevision++;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
