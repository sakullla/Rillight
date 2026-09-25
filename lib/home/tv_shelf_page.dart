import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_sort.dart';

/// 电视首页分栏的完整列表。标题上的箭头进到这里。
class TvShelfPage extends StatefulWidget {
  const TvShelfPage({super.key, required this.source, this.title = ''});

  final String source;
  final String title;

  factory TvShelfPage.fromState(GoRouterState state) {
    return TvShelfPage(
      source: state.pathParameters['source'] ?? '',
      title: state.uri.queryParameters['title'] ?? '',
    );
  }

  static bool handles(String source) {
    return const {
      'resume',
      'nextup',
      'latest-movies',
      'latest-series',
    }.contains(source);
  }

  @override
  State<TvShelfPage> createState() => _TvShelfPageState();
}

class _TvShelfPageState extends State<TvShelfPage> {
  static const _pageSize = 60;

  List<EmbyItem> _items = const [];
  var _loading = true;
  var _loadingMore = false;
  var _refreshing = false;
  var _hasMore = false;
  EmbyException? _error, _pageError, _refreshError;
  var _fetched = 0;
  var _generation = 0;
  AuthController? _auth;
  Object? _identity;

  Object _identityOf(AuthController auth) =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (identical(auth, _auth)) return;
    _auth?.removeListener(_onAuth);
    _auth = auth;
    _identity = _identityOf(auth);
    auth.addListener(_onAuth);
  }

  void _onAuth() {
    final auth = _auth;
    if (auth == null) return;
    final next = _identityOf(auth);
    if (next == _identity) return;
    _identity = next;
    _generation++;
    setState(() {
      _items = const [];
      _fetched = 0;
      _hasMore = false;
      _error = _pageError = _refreshError = null;
    });
    if (auth.isLoggedIn) unawaited(_load());
  }

  @override
  void didUpdateWidget(TvShelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _items = const [];
      _fetched = 0;
      _hasMore = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _auth?.removeListener(_onAuth);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  String _title(AppLocalizations l10n) {
    if (widget.title.isNotEmpty) return widget.title;
    return switch (widget.source) {
      'resume' => l10n.resumeRow,
      'nextup' => l10n.nextUpRow,
      'latest-movies' => l10n.latestMoviesRow,
      'latest-series' => l10n.latestSeriesRow,
      _ => '',
    };
  }

  CatalogRequest _request(EmbyClient client, int startIndex) {
    final userId = client.userId ?? '';
    final sort = CatalogSort.initial;
    return switch (widget.source) {
      'resume' => catalogResumeRequest(
        userId: userId,
        limit: _pageSize,
        startIndex: startIndex,
        sortBy: sort.sortBy,
        sortOrder: sort.sortOrder,
      ),
      'nextup' => catalogNextUpRequest(
        userId: userId,
        limit: _pageSize,
        startIndex: startIndex,
        sortBy: sort.sortBy,
        sortOrder: sort.sortOrder,
      ),
      'latest-series' => catalogItemsRequest(
        userId: userId,
        includeItemTypes: 'Series',
        recursive: true,
        limit: _pageSize,
        startIndex: startIndex,
        sortBy: sort.sortBy,
        sortOrder: sort.sortOrder,
      ),
      _ => catalogItemsRequest(
        userId: userId,
        includeItemTypes: 'Movie',
        recursive: true,
        limit: _pageSize,
        startIndex: startIndex,
        sortBy: sort.sortBy,
        sortOrder: sort.sortOrder,
      ),
    };
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loadingMore || _refreshing || !_hasMore)) return;
    final generation = more ? _generation : ++_generation;
    final identity = _identity;
    final client = AuthScope.of(context).client;
    final cache = CatalogScope.of(context).cache;
    final start = more ? _fetched : 0;
    final request = _request(client, start);
    final keep = !more && _items.isNotEmpty;
    final network = cache.fetch(client, request);
    unawaited(network.then<void>((_) {}, onError: (Object _) {}));
    setState(() {
      if (more) {
        _loadingMore = true;
        _pageError = null;
      } else {
        _loading = !keep;
        _refreshing = keep;
        _error = _refreshError = _pageError = null;
      }
    });
    bool owns() =>
        mounted && generation == _generation && identity == _identity;
    if (!more && !keep) {
      unawaited(() async {
        try {
          final hit = await cache.lookupWhenReady(request);
          if (!owns() ||
              hit == null ||
              (_items.isNotEmpty || (!_loading && _error == null))) {
            return;
          }
          final page = parseCatalogPage(hit.json);
          if (page.items.isEmpty) return;
          setState(() {
            _items = page.items;
            _fetched = page.items.length;
            _hasMore = page.hasMore(fetched: _fetched, pageSize: _pageSize);
            _refreshError = _error;
            _error = null;
            _loading = false;
            _refreshing = _refreshError == null;
          });
        } catch (_) {
          // A damaged disk row never blocks or replaces the live request.
        }
      }());
    }
    try {
      final page = parseCatalogPage(await network);
      if (!owns()) return;
      final merged = more
          ? {
              for (final item in [..._items, ...page.items]) item.id: item,
            }.values.toList()
          : page.items;
      final grew = merged.length > _items.length;
      final fetched = start + page.items.length;
      setState(() {
        _items = merged;
        _fetched = fetched;
        _hasMore =
            page.items.isNotEmpty &&
            (more ? grew : true) &&
            page.hasMore(fetched: fetched, pageSize: _pageSize);
        _loading = false;
        _loadingMore = false;
        _refreshing = false;
      });
    } catch (error) {
      if (!owns()) return;
      setState(() {
        final failure = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
        if (more) {
          _pageError = failure;
        } else if (_items.isNotEmpty) {
          _refreshError = failure;
        } else {
          _error = failure;
        }
        _loading = false;
        _loadingMore = false;
        _refreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      body: CustomScrollView(
        key: PageStorageKey('tv-shelf-${widget.source}'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Text(
                _title(l10n),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
          if (_loading && _items.isEmpty)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (_refreshing)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (_error != null)
            SliverToBoxAdapter(
              child: TvFailure(error: _error!, retry: () => _load()),
            ),
          if (_refreshError != null)
            SliverToBoxAdapter(
              child: TvFailure(error: _refreshError!, retry: () => _load()),
            ),
          if (_items.isNotEmpty)
            TvPosterSliver(
              items: _items,
              metrics: TvGrid.metricsFor(context, width),
            ),
          if (_pageError != null)
            SliverToBoxAdapter(
              child: TvFailure(
                error: _pageError!,
                retry: () => _load(more: true),
              ),
            ),
          if (_hasMore && _pageError == null && _refreshError == null)
            SliverToBoxAdapter(
              child: TvAction(
                onPressed: _loadingMore || _refreshing
                    ? null
                    : () => _load(more: true),
                child: Text(l10n.mobileLoadMore),
              ),
            ),
        ],
      ),
    );
  }
}
