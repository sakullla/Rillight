import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
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
  var _hasMore = false;
  EmbyException? _error;
  var _fetched = 0;

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
    if (more && (_loadingMore || !_hasMore)) return;
    final client = AuthScope.of(context).client;
    final cache = CatalogScope.of(context).cache;
    final start = more ? _fetched : 0;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final page = parseCatalogPage(
        await cache.fetch(client, _request(client, start)),
      );
      if (!mounted) return;
      final merged = more ? [..._items, ...page.items] : page.items;
      final fetched = start + page.items.length;
      setState(() {
        _items = merged;
        _fetched = fetched;
        _hasMore = page.hasMore(fetched: fetched, pageSize: _pageSize);
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      body: CustomScrollView(
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
          if (_error != null)
            SliverToBoxAdapter(
              child: TvFailure(error: _error!, retry: () => _load()),
            ),
          if (_items.isNotEmpty)
            TvPosterSliver(
              items: _items,
              metrics: TvGrid.metricsFor(context, width),
            ),
          if (_hasMore)
            SliverToBoxAdapter(
              child: TvAction(
                onPressed: _loadingMore ? null : () => _load(more: true),
                child: Text(l10n.mobileLoadMore),
              ),
            ),
        ],
      ),
    );
  }
}
