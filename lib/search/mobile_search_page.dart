import 'dart:async';

import 'package:flutter/material.dart' hide SearchController;
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
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
          padding: const EdgeInsets.all(AppSpacing.md),
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
              suffixIcon: IconButton(
                tooltip: l.search,
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
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
    // 搜索失败整页换掉；下一页失败留在海报下面，四种画面互不混用。
    if (!c.searched) {
      return MobileEmptyState(
        key: const Key('mobile-search-idle'),
        message: label.searchEmptyQuery,
      );
    }
    if (c.error != null) {
      return MobileFailureState(
        key: const Key('mobile-search-failure'),
        message: searchFailureMessage(label, c.error!),
        onRetry: onRetry,
      );
    }
    if (c.loading && c.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(key: Key('mobile-search-loading')),
      );
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
      child: ListView(
        key: const PageStorageKey<String>('mobile-search-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (c.loading || c.loadingMore) const LinearProgressIndicator(),
          _ResultGrid(items: c.items),
          if (c.pageError != null)
            _PageFailure(
              key: const Key('mobile-search-page-failure'),
              message: searchFailureMessage(label, c.pageError!),
              onRetry: c.loadMore,
            ),
          if (c.pageError == null && c.hasMore)
            FilledButton(
              key: const Key('mobile-search-load-more'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(AppSpacing.huge, AppSpacing.huge),
              ),
              onPressed: c.loadingMore ? null : c.loadMore,
              child: Text(label.mobileLoadMore),
            ),
        ],
      ),
    );
  }
}

class _PageFailure extends StatelessWidget {
  const _PageFailure({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
              key: const Key('mobile-search-page-retry'),
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
  const _ResultGrid({required this.items});

  final List<EmbyItem> items;

  @override
  Widget build(BuildContext context) {
    return MobileGrid(
      items: items,
      itemBuilder: (context, item) =>
          _ResultPoster(key: Key('mobile-search-item-${item.id}'), item: item),
    );
  }
}

class _ResultPoster extends StatelessWidget {
  const _ResultPoster({super.key, required this.item});

  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final progress = item.playbackProgress;
    final showProgress = item.canResume && progress > 0;
    return MobilePressable(
      onTap: () => context.push(AppRoutes.item(item.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                boxShadow: const [
                  BoxShadow(
                    color: Color.fromRGBO(0, 0, 0, AppMobileCard.shadowAlpha),
                    blurRadius: AppMobileCard.shadowBlur,
                    spreadRadius: AppMobileCard.shadowSpread,
                    offset: Offset(0, AppMobileCard.shadowOffsetY),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.md),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(item: item, maxWidth: 400),
                    if (showProgress)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(
                              value: progress,
                              minHeight: 4,
                            ),
                            ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.84),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.xxs,
                                  vertical: 2,
                                ),
                                child: Text(
                                  l.playbackProgress((progress * 100).round()),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
