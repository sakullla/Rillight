import 'dart:async';

import 'package:dio/dio.dart';
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
    this.initialEpisodeId,
  }) : repository = DetailRepository(auth.client, cache) {
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
  final AuthController auth;
  final DetailRepository repository;
  final String itemId;
  final String? initialEpisodeId;
  EmbyItem? item;

  void applyItem(EmbyItem next) {
    item = next;
    notifyListeners();
  }

  List<EmbyItem> seasons = const [], episodes = const [];
  String? seasonId, mediaSourceId;
  int episodeTotal = 0;
  int windowStart = 0;
  EmbyException? error, seasonError, episodeError;
  bool loading = true,
      seasonsLoading = false,
      episodesLoading = false,
      hasMore = false;

  /// 续播集在已加载页之外时记住它。列表仍停在当前页，主操作不退回第一条。
  EmbyItem? resumeBeyondPage;
  Future<void>? _resumeScan;
  CancelToken? _resumeCancel;
  bool playedBusy = false;
  int _revision = 0, _seasonRevision = 0, _offset = 0;
  bool _disposed = false;
  late Object _identity;
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _resumeCancel?.cancel('detail-identity-changed');
    _identity = _currentIdentity;
    _revision++;
    _seasonRevision++;
    item = null;
    seasons = episodes = const [];
    seasonId = mediaSourceId = null;
    resumeBeyondPage = null;
    error = seasonError = episodeError = null;
    loading = seasonsLoading = episodesLoading = hasMore = false;
    _offset = 0;
    notifyListeners();
  }

  Future<void> load() async {
    _resumeCancel?.cancel('detail-reloaded');
    final revision = ++_revision;
    _seasonRevision++;
    seasonsLoading = false;
    episodesLoading = false;
    final identity = _identity;
    loading = true;
    error = null;
    notifyListeners();
    final network = repository.item(itemId);
    if (item == null) {
      unawaited(() async {
        try {
          final cached = await repository.cachedItem(itemId);
          if (_disposed || revision != _revision || identity != _identity) {
            return;
          }
          if (cached != null && item == null) {
            item = cached;
            mediaSourceId ??= cached.mediaSources.firstOrNull?.id;
            loading = false;
            notifyListeners();
            if (cached.isSeries) unawaited(loadSeasons());
          }
        } catch (_) {
          // A damaged cache entry does not hide the live response.
        }
      }());
    }
    try {
      final result = await network;
      if (_disposed || revision != _revision || identity != _identity) return;
      item = result;
      mediaSourceId ??= result.mediaSources.firstOrNull?.id;
      loading = false;
      notifyListeners();
      if (result.isSeries && !seasonsLoading) {
        // Season and episode requests do not hold the already ready header.
        unawaited(loadSeasons());
      }
    } catch (failure) {
      if (_disposed || revision != _revision || identity != _identity) return;
      error = _failure(failure);
    }
    if (_disposed || revision != _revision) return;
    loading = false;
    notifyListeners();
  }

  Future<void> loadSeasons() async {
    final revision = _revision;
    final identity = _identity;
    final current = item;
    if (current == null || !current.isSeries) return;
    seasonsLoading = true;
    seasonError = null;
    notifyListeners();
    final network = repository.seasons(current.id);
    if (seasons.isEmpty) {
      unawaited(() async {
        try {
          final cached = await repository.cachedSeasons(current.id);
          if (_disposed || revision != _revision || identity != _identity) {
            return;
          }
          if (cached != null && seasons.isEmpty && seasonsLoading) {
            seasons = cached;
            notifyListeners();
            if ((initialEpisodeId?.trim().isEmpty ?? true) &&
                cached.isNotEmpty) {
              final selected = cached.any((s) => s.id == seasonId)
                  ? seasonId
                  : cached.first.id;
              if (selected != null) unawaited(selectSeason(selected));
            }
          }
        } catch (_) {
          // Fall through to live season data.
        }
      }());
    }
    try {
      final loaded = await network;
      if (_disposed || revision != _revision || identity != _identity) return;
      seasons = loaded;
      seasonsLoading = false;
      notifyListeners();
      if (seasons.isEmpty) {
        _resumeCancel?.cancel('seasons-removed');
        _seasonRevision++;
        seasonId = null;
        episodes = const [];
        episodeTotal = windowStart = _offset = 0;
        episodesLoading = hasMore = false;
        resumeBeyondPage = null;
        episodeError = null;
        notifyListeners();
        return;
      }
      final episodeId = initialEpisodeId?.trim();
      if (episodeId != null && episodeId.isNotEmpty) {
        try {
          final episode = await repository.item(episodeId);
          if (_disposed || revision != _revision || identity != _identity) {
            return;
          }
          final selected = episode.seasonId ?? episode.parentId;
          if (selected != null && selected.isNotEmpty) {
            await selectSeason(
              selected,
              startAt: ((episode.indexNumber ?? 1) - 1).clamp(0, 1 << 30),
            );
            return;
          }
        } catch (_) {
          // Keep the normal season selection when the deep link is stale.
        }
      }
      final selected = seasons.any((s) => s.id == seasonId)
          ? seasonId
          : seasons.firstOrNull?.id;
      if (selected != null && (!episodesLoading || seasonId != selected)) {
        await selectSeason(selected);
      }
      if (_disposed || revision != _revision || identity != _identity) return;
      if (initialEpisodeId?.trim().isEmpty ?? true) {
        // Resolve the preferred play action after the header and first season
        // are available. It must not hold the detail page's initial display.
        unawaited(retainOffPageResume().catchError((Object _) {}));
      }
    } catch (failure) {
      if (_disposed || revision != _revision || identity != _identity) return;
      seasonError = _failure(failure);
      seasonsLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectSeason(
    String id, {
    bool more = false,
    int startAt = 0,
  }) async {
    _resumeCancel?.cancel('season-changed');
    if (more && (episodesLoading || !hasMore)) return;
    final revision = ++_seasonRevision;
    final identity = _identity;
    final start = more ? _offset : startAt;
    if (!more) {
      _offset = 0;
      hasMore = false;
      windowStart = startAt;
    }
    if (seasonId != id) {
      episodes = const [];
      resumeBeyondPage = null;
    }
    seasonId = id;
    episodesLoading = true;
    episodeError = null;
    notifyListeners();
    final network = repository.episodes(id, start: start);
    if (!more && episodes.isEmpty) {
      unawaited(() async {
        try {
          final cached = await repository.cachedEpisodes(id, start: start);
          if (_disposed ||
              revision != _seasonRevision ||
              identity != _identity) {
            return;
          }
          if (cached != null && episodes.isEmpty && episodesLoading) {
            episodes = cached.items;
            _offset = start + cached.items.length;
            episodeTotal = cached.totalRecordCount ?? _offset;
            hasMore = cached.totalRecordCount == null
                ? cached.items.length == 50
                : _offset < cached.totalRecordCount!;
            notifyListeners();
          }
        } catch (_) {
          // A damaged cache entry does not prevent live episodes from loading.
        }
      }());
    }
    try {
      final page = await network;
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
      episodeTotal = page.totalRecordCount ?? _offset;
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

  /// Scan across seasons only when the user starts series playback. The
  /// currently visible first page remains ready while this work runs.
  Future<void> retainOffPageResume() => _resumeScan ??= _scanPreferredEpisode()
      .whenComplete(() => _resumeScan = null);

  Future<void> _scanPreferredEpisode() async {
    if (_disposed || item?.isSeries != true || seasons.isEmpty) return;
    final cancelToken = CancelToken();
    _resumeCancel = cancelToken;
    final revision = _seasonRevision;
    final identity = _identity;
    EmbyItem? resume, firstUnwatched;
    String? resumeSeason, firstUnwatchedSeason;
    try {
      for (final season in seasons) {
        var start = 0;
        while (true) {
          final visiblePage =
              season.id == seasonId &&
              start == 0 &&
              windowStart == 0 &&
              episodes.isNotEmpty &&
              !episodesLoading;
          final page = visiblePage
              ? EmbyItemPage(items: episodes)
              : await repository.scanEpisodes(
                  season.id,
                  start: start,
                  cancelToken: cancelToken,
                );
          if (_disposed ||
              revision != _seasonRevision ||
              identity != _identity) {
            return;
          }
          for (final episode in page.items) {
            if (episode.canResume) {
              resume = episode;
              resumeSeason = season.id;
              break;
            }
            if (firstUnwatched == null && !episode.userData.played) {
              firstUnwatched = episode;
              firstUnwatchedSeason = season.id;
            }
          }
          if (resume != null || page.items.isEmpty) break;
          start += page.items.length;
          if (visiblePage
              ? !hasMore
              : !page.hasMore(fetched: start, pageSize: 50)) {
            break;
          }
        }
        if (resume != null) break;
      }
    } catch (failure) {
      if (!_disposed && revision == _seasonRevision && identity == _identity) {
        episodeError = _failure(failure);
        notifyListeners();
      }
      rethrow;
    } finally {
      if (identical(_resumeCancel, cancelToken)) _resumeCancel = null;
    }
    if (_disposed || revision != _seasonRevision || identity != _identity) {
      return;
    }
    final preferredSeason = resumeSeason ?? firstUnwatchedSeason;
    if (preferredSeason != null && preferredSeason != seasonId) {
      final episode = resume ?? firstUnwatched;
      final startAt = episode?.indexNumber == null
          ? 0
          : (episode!.indexNumber! - 1).clamp(0, 1 << 30);
      await selectSeason(preferredSeason, startAt: startAt);
    } else if (resume == null &&
        firstUnwatched != null &&
        episodes.every((episode) => episode.id != firstUnwatched!.id)) {
      await selectSeason(
        preferredSeason!,
        startAt: ((firstUnwatched.indexNumber ?? 1) - 1).clamp(0, 1 << 30),
      );
    }
    if (_disposed || identity != _identity) return;
    resumeBeyondPage =
        resume != null &&
            _inSelectedSeason(resume) &&
            episodes.every((episode) => episode.id != resume!.id)
        ? resume
        : null;
    notifyListeners();
  }

  void selectSource(String id) {
    mediaSourceId = id;
    notifyListeners();
  }

  /// 乐观更新已看状态:本地立即生效,失败回滚。手机与 TV 详情共用。
  void applyPlayed(EmbyItem target, {required bool played}) {
    applyItem(
      target.copyWith(
        userData: target.userData.copyWith(
          played: played,
          playbackPositionTicks: 0,
          playedPercentage: played ? 100 : 0,
        ),
      ),
    );
  }

  /// 切换当前条目已看状态。成功返回 true(调用方给可见反馈),失败回滚并返回 false。
  Future<bool> togglePlayed() async {
    final current = item;
    if (current == null || playedBusy) return false;
    final next = !current.userData.played;
    playedBusy = true;
    applyPlayed(current, played: next);
    try {
      if (next) {
        await auth.client.markPlayed(current.id);
      } else {
        await auth.client.markUnplayed(current.id);
      }
      await load();
      final reloaded = item;
      if (reloaded != null &&
          reloaded.id == current.id &&
          reloaded.userData.played != next) {
        applyPlayed(reloaded, played: next);
      }
      return true;
    } catch (_) {
      final reloaded = item;
      if (reloaded != null && reloaded.id == current.id) {
        applyPlayed(reloaded, played: current.userData.played);
      }
      return false;
    } finally {
      playedBusy = false;
      notifyListeners();
    }
  }

  EmbyException _failure(Object value) => value is EmbyException
      ? value
      : EmbyException(EmbyFailureKind.unknown, cause: value);
  @override
  void dispose() {
    _resumeCancel?.cancel('detail-disposed');
    _disposed = true;
    _revision++;
    _seasonRevision++;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
