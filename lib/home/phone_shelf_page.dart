import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_sort.dart';

/// 手机货架。查询与桌面 shelf 的默认排序、分页一致，画面用海报网格。
class PhoneShelfPage extends StatefulWidget {
  const PhoneShelfPage({
    super.key,
    required this.source,
    this.parentId,
    this.includeItemTypes,
    this.title = '',
    this.recursive = false,
  });

  final String source;
  final String? parentId;
  final String? includeItemTypes;
  final String title;
  final bool recursive;

  /// 与桌面货架每页条数相同。
  static const pageSize = 60;

  static const loadMoreKey = Key('phone-shelf-load-more');

  factory PhoneShelfPage.fromState(GoRouterState state) {
    final query = state.uri.queryParameters;
    return PhoneShelfPage(
      source: state.pathParameters['source'] ?? '',
      parentId: query['parentId'],
      includeItemTypes: query['includeItemTypes'],
      title: query['title'] ?? '',
      recursive: query['recursive'] == '1',
    );
  }

  @override
  State<PhoneShelfPage> createState() => _PhoneShelfPageState();
}

class _PhoneShelfPageState extends State<PhoneShelfPage> {
  List<EmbyItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  EmbyException? _error;
  EmbyException? _pageError;
  int _fetched = 0;
  int _loadGen = 0;
  CatalogCache? _fallbackCache;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_load());
      }
    });
  }

  @override
  void didUpdateWidget(PhoneShelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.parentId != widget.parentId ||
        oldWidget.includeItemTypes != widget.includeItemTypes ||
        oldWidget.recursive != widget.recursive) {
      unawaited(_load());
    }
  }

  CatalogCache get _cache {
    return CatalogScope.maybeOf(context)?.cache ??
        (_fallbackCache ??= CatalogCache());
  }

  String _title(AppLocalizations l10n) {
    if (widget.title.isNotEmpty) {
      return widget.title;
    }
    return switch (widget.source) {
      'resume' => l10n.resumeRow,
      'nextup' => l10n.nextUpRow,
      'latest-movies' => l10n.latestMoviesRow,
      'latest-series' => l10n.latestSeriesRow,
      'similar' => l10n.similarRow,
      _ => '',
    };
  }

  CatalogRequest _request(EmbyClient client, int startIndex, int limit) {
    final userId = client.userId ?? '';
    final sort = CatalogSort.initial;
    switch (widget.source) {
      case 'resume':
        return catalogResumeRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      case 'nextup':
        return catalogNextUpRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      case 'latest-movies':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Movie',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      case 'latest-series':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Series',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      default:
        return catalogItemsRequest(
          userId: userId,
          parentId: widget.parentId,
          includeItemTypes: widget.includeItemTypes,
          recursive: widget.recursive,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
    }
  }

  Future<EmbyItemPage> _fetch(int startIndex) async {
    final client = AuthScope.of(context).client;
    final json = await _cache.fetch(
      client,
      _request(client, startIndex, PhoneShelfPage.pageSize),
    );
    return parseCatalogPage(json);
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _pageError = null;
      _items = const [];
      _hasMore = false;
      _fetched = 0;
    });
    try {
      final page = await _fetch(0);
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = page.items;
        _fetched = page.items.length;
        _hasMore = page.hasMore(
          fetched: _fetched,
          pageSize: PhoneShelfPage.pageSize,
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loading = false;
        _error = _asEmby(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loading || _loadingMore) {
      return;
    }
    final gen = _loadGen;
    final start = _fetched;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await _fetch(start);
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = _merge(_items, page.items);
        _fetched = start + page.items.length;
        _hasMore = page.hasMore(
          fetched: _fetched,
          pageSize: PhoneShelfPage.pageSize,
        );
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = _asEmby(error);
      });
    }
  }

  EmbyException _asEmby(Object error) {
    if (error is EmbyException) {
      return error;
    }
    return EmbyException(EmbyFailureKind.unknown, cause: error);
  }

  List<EmbyItem> _merge(List<EmbyItem> existing, List<EmbyItem> incoming) {
    final merged = [...existing];
    final seen = {for (final item in merged) item.id};
    for (final item in incoming) {
      if (seen.add(item.id)) {
        merged.add(item);
      }
    }
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = _title(l10n);
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _body(l10n),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_loading && _items.isEmpty) {
      return const MobileLoadingPlaceholder.row();
    }
    if (_error != null && _items.isEmpty) {
      return MobileFailureState(
        message: catalogFailureMessage(l10n, _error!),
        onRetry: () => unawaited(_load()),
      );
    }
    if (_items.isEmpty) {
      return MobileEmptyState(message: l10n.mobileEmpty);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = (constraints.maxWidth / 165).floor().clamp(2, 6);
        final tileWidth = constraints.maxWidth / columns;
        final tileHeight = tileWidth * 1.5 + 52 * scale;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.md),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: tileWidth / tileHeight,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => MobilePoster(item: _items[index]),
                  childCount: _items.length,
                ),
              ),
            ),
            if (_pageError != null)
              SliverToBoxAdapter(
                child: MobileFailureState(
                  message: catalogFailureMessage(l10n, _pageError!),
                  onRetry: () => unawaited(_loadMore()),
                ),
              )
            else if (_hasMore)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton(
                    key: PhoneShelfPage.loadMoreKey,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _loadingMore
                        ? null
                        : () => unawaited(_loadMore()),
                    child: Text(l10n.episodesLoadMore),
                  ),
                ),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }
}
