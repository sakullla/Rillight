import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/shelf_grid_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  /// 搜索输入区最大宽度,随 [AppBreakpoints] 舒展。
  static double fieldWidthFor(double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 560;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 680;
    }
    return 800;
  }

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  List<EmbyItem> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _searched = false;
  EmbyException? _error;
  String _term = '';
  int _fetched = 0;
  final ScrollController _scrollController = ScrollController();

  /// 滚动距底部不足该像素时预取下一页。
  static const _loadMoreThreshold = 600.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    _query.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_hasMore || _loading || _loadingMore || _term.isEmpty) {
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      _loadMore();
    }
  }

  Future<void> _submit([String? raw]) async {
    final term = (raw ?? _query.text).trim();
    if (term.isEmpty) {
      setState(() {
        _searched = false;
        _items = const [];
        _error = null;
        _loading = false;
        _hasMore = false;
        _term = '';
        _fetched = 0;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
      _term = term;
    });
    try {
      final items = await AuthScope.of(
        context,
      ).client.searchByName(term, startIndex: 0);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items.where((item) => item.isMovieOrSeries).toList();
        _fetched = items.length;
        _hasMore = items.length >= 50;
        _loading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _items = const [];
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final items = await AuthScope.of(
        context,
      ).client.searchByName(_term, startIndex: _fetched);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = [..._items, ...items.where((item) => item.isMovieOrSeries)];
        _fetched += items.length;
        _hasMore = items.length >= 50;
        _loadingMore = false;
      });
    } on EmbyException {
      if (!mounted) {
        return;
      }
      // 追加失败保留已有结果,滚动到底部可重试。
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: SearchPage.fieldWidthFor(screenWidth),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: CatalogKeys.searchField,
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: InputDecoration(
                        hintText: l10n.searchHint,
                        prefixIcon: const Icon(Icons.search),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                          vertical: AppSpacing.md,
                        ),
                      ),
                      onSubmitted: (value) => _submit(value),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    key: CatalogKeys.searchSubmit,
                    onPressed: _loading ? null : () => _submit(),
                    child: Text(l10n.search),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: _buildBody(l10n, screenWidth)),
      ],
    );
  }

  Widget _buildBody(AppLocalizations l10n, double screenWidth) {
    if (_loading) {
      return SkeletonPosterGrid(
        maxCrossAxisExtent: ShelfGridPage.maxCrossAxisExtentFor(screenWidth),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.xxl,
        ),
      );
    }
    if (_error != null) {
      return AppErrorView(
        message: searchFailureMessage(l10n, _error!),
        onRetry: _submit,
      );
    }
    if (!_searched) {
      return AppEmptyView(icon: Icons.search, message: l10n.searchEmptyQuery);
    }
    if (_items.isEmpty) {
      return AppEmptyView(
        key: CatalogKeys.searchNoResults,
        icon: Icons.search_off,
        message: l10n.searchNoResults,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.xxl,
          ),
          gridDelegate: ShelfGridPage.gridDelegateFor(
            screenWidth: screenWidth,
            availableWidth: constraints.maxWidth - AppSpacing.md * 2,
          ),
          itemCount: _items.length + (_loadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _items.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final item = _items[index];
            return ShelfGridPage.gridCard(
              context,
              item,
              onTap: () => context.push(AppRoutes.item(item.id)),
            );
          },
        );
      },
    );
  }
}
