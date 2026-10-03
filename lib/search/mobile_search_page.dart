import 'dart:async';

import 'package:flutter/material.dart' hide SearchController;
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/search/search_controller.dart';

/// 手机搜索：输入即搜。剧集和电影都走 [AppRoutes.item]，由详情页按类型分画面。
class MobileSearchPage extends StatefulWidget {
  const MobileSearchPage({super.key});

  @override
  State<MobileSearchPage> createState() => _MobileSearchPageState();
}

class _MobileSearchPageState extends State<MobileSearchPage> {
  static const _termId = ValueKey<String>('mobile-search-term');
  static const _debounceDelay = Duration(milliseconds: 350);

  final _text = TextEditingController();
  final _focus = FocusNode();
  SearchController? _controller;
  Timer? _debounce;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= SearchController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
    );
    if (_restored) {
      return;
    }
    final storage = PageStorage.maybeOf(context);
    if (storage == null) {
      return;
    }
    _restored = true;
    final stored = storage.readState(context, identifier: _termId);
    if (stored is String && stored.isNotEmpty && _text.text.isEmpty) {
      _text.text = stored;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller?.submit(stored);
        }
      });
    }
  }

  void _remember(String value) {
    PageStorage.maybeOf(
      context,
    )?.writeState(context, value, identifier: _termId);
  }

  void _onChanged(String value) {
    _remember(value);
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) {
        return;
      }
      _controller?.submit(_text.text);
    });
  }

  void _submit() {
    _debounce?.cancel();
    _remember(_text.text);
    FocusScope.of(context).unfocus();
    _controller!.submit(_text.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller?.dispose();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('mobile-search-field'),
                  controller: _text,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  scrollPadding: const EdgeInsets.all(20),
                  onSubmitted: (_) => _submit(),
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: l.searchHint,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _text,
                      builder: (context, value, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (value.text.isNotEmpty)
                            IconButton(
                              key: const Key('mobile-search-clear'),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).deleteButtonTooltip,
                              onPressed: () {
                                _text.clear();
                                _onChanged('');
                                _focus.requestFocus();
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                          IconButton(
                            tooltip: l.search,
                            onPressed: _submit,
                            icon: const Icon(Icons.arrow_forward),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              CatalogFilterButton(watch: c.watch, onChanged: c.setWatch),
            ],
          ),
        ),
        if (c.watch != null)
          CatalogWatchChip(watch: c.watch!, onClear: () => c.setWatch(null)),
        Expanded(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => _SearchBody(
              controller: c,
              label: l,
              onRetry: _submit,
              onFocusQuery: _focus.requestFocus,
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchBody extends StatelessWidget {
  const _SearchBody({
    required this.controller,
    required this.label,
    required this.onRetry,
    required this.onFocusQuery,
  });

  final SearchController controller;
  final AppLocalizations label;
  final VoidCallback onRetry;
  final VoidCallback onFocusQuery;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    // 已显示缓存结果时，实时刷新失败保留列表和局部重试。
    if (!c.searched) {
      return MobileEmptyState(
        key: const Key('mobile-search-idle'),
        message: label.searchEmptyQuery,
      );
    }
    if (c.error != null && c.items.isEmpty) {
      return MobileFailureState(
        key: const Key('mobile-search-failure'),
        message: searchFailureMessage(label, c.error!),
        onRetry: onRetry,
      );
    }
    if (c.refreshingFirstPage && c.items.isEmpty) {
      // 骨架屏替代 spinner,与全仓加载占位规范一致(ADR-4)。
      return const _SearchSkeleton();
    }
    if (c.items.isEmpty) {
      return MobileEmptyState(
        key: const Key('mobile-search-empty'),
        message: label.searchNoResults,
        actionLabel: label.search,
        onAction: onFocusQuery,
      );
    }
    return RefreshIndicator(
      onRefresh: () => c.submit(c.term),
      child: MediaImageScrollListener(
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(
            key: const PageStorageKey<String>('mobile-search-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md + phoneScrollClearance(context),
                ),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    if (c.refreshingFirstPage)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(
                          key: Key('mobile-search-refreshing'),
                        ),
                      ),
                    if (c.error != null)
                      SliverToBoxAdapter(
                        child: _PageFailure(
                          key: const Key('mobile-search-refresh-failure'),
                          message: searchFailureMessage(label, c.error!),
                          onRetry: () => c.submit(c.term),
                          retryKey: const Key('mobile-search-refresh-retry'),
                        ),
                      ),
                    _ResultGrid(
                      items: c.items,
                      width: constraints.maxWidth - AppSpacing.md * 2,
                    ),
                    if (c.loadingMore)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    if (c.pageError != null)
                      SliverToBoxAdapter(
                        child: _PageFailure(
                          key: const Key('mobile-search-page-failure'),
                          message: searchFailureMessage(label, c.pageError!),
                          onRetry: c.loadMore,
                        ),
                      ),
                    if (c.pageError == null &&
                        c.hasMore &&
                        c.liveFirstPageReady)
                      SliverToBoxAdapter(
                        child: FilledButton(
                          key: const Key('mobile-search-load-more'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(
                              AppSpacing.huge,
                              AppSpacing.huge,
                            ),
                          ),
                          onPressed: c.loadingMore ? null : c.loadMore,
                          child: Text(label.mobileLoadMore),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索加载骨架与结果 [_ResultGrid] 同几何:同列数([mobileGridColumnCount])、
/// 同 [MobileGrid] 按 [phonePosterCardLabelExtent] 推导的宽高比,消除
/// 骨架→结果切换时的布局跳动。
class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 结果网格在 ListView 的水平 padding 之内取宽,这里先扣同样边距再算列。
        final gridWidth = constraints.maxWidth - AppSpacing.md * 2;
        const spacing = AppSpacing.md;
        final columns = mobileGridColumnCount(
          gridWidth,
          textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
        );
        final cellWidth = (gridWidth - spacing * (columns - 1)) / columns;
        final labelExtent = phonePosterCardLabelExtent(context);
        return SkeletonPosterGrid(
          key: const Key('mobile-search-loading'),
          crossAxisCount: columns,
          childAspectRatio: cellWidth / (cellWidth * 1.5 + labelExtent),
        );
      },
    );
  }
}

class _PageFailure extends StatelessWidget {
  const _PageFailure({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryKey = const Key('mobile-search-page-retry'),
  });

  final String message;
  final VoidCallback onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message),
            const SizedBox(height: 8),
            FilledButton(
              key: retryKey,
              style: FilledButton.styleFrom(
                minimumSize: const Size(AppSpacing.huge, AppSpacing.huge),
              ),
              onPressed: onRetry,
              child: Text(l.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.items, required this.width});

  final List<EmbyItem> items;
  final double width;

  @override
  Widget build(BuildContext context) {
    const spacing = AppSpacing.md;
    final columns = mobileGridColumnCount(
      width,
      textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
    );
    final cellWidth = (width - spacing * (columns - 1)) / columns;
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        mainAxisExtent: cellWidth * 1.5 + phonePosterCardLabelExtent(context),
      ),
      itemCount: items.length,
      // 结果卡与首页同规范(ADR-3);搜索 tab 与首页同导航栈共存,且同一
      // 条目可能同时出现在首页飞行海报里,这里不走 Hero、直 push 详情。
      itemBuilder: (context, index) {
        final item = items[index];
        return PhoneGridPosterCard(
          key: Key('mobile-search-item-${item.id}'),
          item: item,
          hero: false,
          onTap: () => context.push(AppRoutes.item(item.id)),
        );
      },
    );
  }
}
