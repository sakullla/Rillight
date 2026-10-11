import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/desktop_scroll.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/person_works_controller.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_host_command.dart';

/// 人物作品。加载、失败和空结果沿用当前端的货架，不提供排序或职务筛选。
class PersonWorksPage extends StatefulWidget {
  const PersonWorksPage({
    super.key,
    required this.personId,
    required this.name,
  });

  final String personId;
  final String name;

  static const titleKey = Key('person-works-title');
  static const loadingKey = Key('person-works-loading');
  static const loadMoreKey = Key('person-works-load-more');

  static Key posterKey(String itemId) => Key('person-works-poster-$itemId');

  @override
  State<PersonWorksPage> createState() => _PersonWorksPageState();
}

class _PersonWorksPageState extends State<PersonWorksPage> {
  PersonWorksController? _works;
  Object? _identity;
  final _scroll = DesktopScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = DetailSourceScope.clientOf(context);
    final cache = DetailSourceScope.cacheOf(context);
    final identity = (
      client.baseUrl?.toString(),
      client.userId,
      client.accessToken,
      widget.personId,
      identityHashCode(cache),
    );
    if (_identity == identity) return;
    _identity = identity;
    final previous = _works;
    final next = PersonWorksController(
      client: client,
      cache: cache,
      personId: widget.personId,
    );
    previous?.removeListener(_onWorks);
    _works = next;
    next.addListener(_onWorks);
    previous?.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_works, next)) return;
      unawaited(next.load());
    });
  }

  void _onWorks() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _works?.removeListener(_onWorks);
    _works?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open(BuildContext context, EmbyItem item) {
    final origin = DetailSourceScope.maybeOf(context);
    if (origin == null) {
      context.push(AppRoutes.item(item.id));
      return;
    }
    origin.permit.requireValid();
    final parent = item.parentId?.trim() ?? '';
    context.push(
      DetailSourceScope.itemLocation(context, item.id),
      extra: PlayerHostOpenItemCommand(
        itemId: item.id,
        source: SourceReference(
          account: origin.source.account,
          itemId: item.id,
        ),
        libraryId: parent.isNotEmpty ? parent : origin.libraryId,
        regionGeneration: origin.permit.regionGeneration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final works = _works;
    if (works == null) {
      return const SizedBox.shrink();
    }
    final environment = PresentationScope.maybeOf(context);
    if (environment?.isTv == true) {
      return _PersonTvWorks(name: widget.name, works: works, onOpen: _open);
    }
    if (PresentationScope.isPhoneOf(context)) {
      return _PersonPhoneWorks(name: widget.name, works: works, onOpen: _open);
    }
    return _PersonDesktopWorks(
      name: widget.name,
      works: works,
      scroll: _scroll,
      onOpen: _open,
    );
  }
}

class _PersonDesktopWorks extends StatelessWidget {
  const _PersonDesktopWorks({
    required this.name,
    required this.works,
    required this.scroll,
    required this.onOpen,
  });

  final String name;
  final PersonWorksController works;
  final ScrollController scroll;
  final void Function(BuildContext context, EmbyItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.page,
            _headerInset(context),
            AppSpacing.page,
            AppSpacing.sm,
          ),
          child: Text(
            name,
            key: PersonWorksPage.titleKey,
            style: Theme.of(context).textTheme.headlineMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(child: _body(context, l10n)),
      ],
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (works.loading && works.items.isEmpty) {
      return SkeletonPosterGrid(
        key: PersonWorksPage.loadingKey,
        maxCrossAxisExtent: ShelfGridPage.maxCrossAxisExtentFor(
          MediaQuery.sizeOf(context).width,
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.xs,
          AppSpacing.page,
          AppSpacing.xxl,
        ),
      );
    }
    if (works.error != null && works.items.isEmpty) {
      return AppErrorView(
        message: catalogFailureMessage(l10n, works.error!),
        onRetry: () => unawaited(works.load()),
      );
    }
    if (works.items.isEmpty) {
      return AppEmptyView(message: l10n.browseEmpty);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final delegate = ShelfGridPage.gridDelegateFor(
          screenWidth: screenWidth,
          availableWidth: math.max(
            1,
            constraints.maxWidth - AppSpacing.page * 2,
          ),
          labelExtent: MediaShelf.posterLabelExtentFor(context),
        );
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (works.pageError == null &&
                notification.metrics.axis == Axis.vertical &&
                notification.metrics.maxScrollExtent > 0 &&
                notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent -
                        ShelfGridPage.loadMoreThreshold) {
              unawaited(works.loadMore());
            }
            return false;
          },
          child: MediaImageScrollListener(
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                if (works.pageError != null)
                  SliverToBoxAdapter(
                    child: CatalogInlineFailure(
                      message: catalogFailureMessage(l10n, works.pageError!),
                      onRetry: () => unawaited(works.loadMore()),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    AppSpacing.xs,
                    AppSpacing.page,
                    AppSpacing.xxl,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: delegate,
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = works.items[index];
                      return KeyedSubtree(
                        key: PersonWorksPage.posterKey(item.id),
                        child: ShelfGridPage.gridCard(
                          context,
                          item,
                          onTap: () => onOpen(context, item),
                        ),
                      );
                    }, childCount: works.items.length),
                  ),
                ),
                if (works.loadingMore)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: AppSpacing.xxl),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

double _headerInset(BuildContext context) {
  var inset = AppSpacing.xl;
  if (context.findAncestorWidgetOfExactType<AppShell>() == null) {
    return inset;
  }
  final hasChrome =
      context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
  if (!hasChrome) return inset + AppShell.topBarHeight;
  final barHeight = kWindowChromeHeight > AppShell.topBarHeight
      ? kWindowChromeHeight
      : AppShell.topBarHeight;
  return inset + barHeight;
}

class _PersonPhoneWorks extends StatelessWidget {
  const _PersonPhoneWorks({
    required this.name,
    required this.works,
    required this.onOpen,
  });

  final String name;
  final PersonWorksController works;
  final void Function(BuildContext context, EmbyItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          name,
          key: PersonWorksPage.titleKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _body(context, l10n),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (works.loading && works.items.isEmpty) {
      return const _PersonPhoneSkeleton();
    }
    if (works.error != null && works.items.isEmpty) {
      return MobileFailureState(
        message: catalogFailureMessage(l10n, works.error!),
        onRetry: () => unawaited(works.load()),
      );
    }
    if (works.items.isEmpty) {
      return MobileEmptyState(message: l10n.mobileEmpty);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelExtent = phonePosterCardLabelExtent(context);
        final metrics = _phoneMetrics(constraints.maxWidth, labelExtent);
        if (metrics.tileWidth <= 0 || metrics.tileHeight <= 0) {
          return const SizedBox.shrink();
        }
        final imageWidth = catalogPosterMaxWidth(
          metrics.tileWidth,
          MediaQuery.devicePixelRatioOf(context),
        );
        return MediaImageScrollListener(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(AppSpacing.md),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: metrics.columns,
                    mainAxisSpacing: metrics.spacing,
                    crossAxisSpacing: metrics.spacing,
                    childAspectRatio: metrics.tileWidth / metrics.tileHeight,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = works.items[index];
                    return PhoneGridPosterCard(
                      key: PersonWorksPage.posterKey(item.id),
                      item: item,
                      hero: false,
                      imageMaxWidth: imageWidth,
                      onTap: () => onOpen(context, item),
                    );
                  }, childCount: works.items.length),
                ),
              ),
              if (works.pageError != null)
                SliverToBoxAdapter(
                  child: MobileFailureState(
                    message: catalogFailureMessage(l10n, works.pageError!),
                    onRetry: () => unawaited(works.loadMore()),
                  ),
                )
              else if (works.hasMore)
                SliverToBoxAdapter(
                  child: Center(
                    child: TextButton(
                      key: PersonWorksPage.loadMoreKey,
                      onPressed: works.loadingMore
                          ? null
                          : () => unawaited(works.loadMore()),
                      child: Text(l10n.episodesLoadMore),
                    ),
                  ),
                ),
              if (works.loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PhoneMetrics {
  const _PhoneMetrics({
    required this.columns,
    required this.spacing,
    required this.tileWidth,
    required this.tileHeight,
  });

  final int columns;
  final double spacing;
  final double tileWidth;
  final double tileHeight;
}

_PhoneMetrics _phoneMetrics(double outerWidth, double labelExtent) {
  const spacing = AppSpacing.md;
  final columns = PhoneShelfPage.columnCountFor(outerWidth);
  final content = math.max(0.0, outerWidth - AppSpacing.md * 2);
  final gaps = spacing * math.max(0, columns - 1);
  final tileWidth = columns <= 0 || content <= gaps
      ? 0.0
      : (content - gaps) / columns;
  return _PhoneMetrics(
    columns: columns,
    spacing: spacing,
    tileWidth: tileWidth,
    tileHeight: tileWidth * 1.5 + labelExtent,
  );
}

class _PersonPhoneSkeleton extends StatelessWidget {
  const _PersonPhoneSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _phoneMetrics(
          constraints.maxWidth,
          phonePosterCardLabelExtent(context),
        );
        if (metrics.columns <= 0 ||
            metrics.tileWidth <= 0 ||
            metrics.tileHeight <= 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          key: PersonWorksPage.loadingKey,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              mainAxisSpacing: metrics.spacing,
              crossAxisSpacing: metrics.spacing,
              childAspectRatio: metrics.tileWidth / metrics.tileHeight,
            ),
            itemCount: metrics.columns * 3,
            itemBuilder: (context, index) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AspectRatio(
                    aspectRatio: 2 / 3,
                    child: SkeletonBlock(animated: false),
                  ),
                  const SizedBox(height: 6),
                  SkeletonBlock(
                    width: metrics.tileWidth * 0.72,
                    height: 14,
                    animated: false,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _PersonTvWorks extends StatelessWidget {
  const _PersonTvWorks({
    required this.name,
    required this.works,
    required this.onOpen,
  });

  final String name;
  final PersonWorksController works;
  final void Function(BuildContext context, EmbyItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final padding = TvFrame.contentPadding(context);
    return TvFrame(
      title: name,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - padding.horizontal;
          final metrics = TvGrid.metricsFor(context, width);
          Widget box(Widget child) => SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: padding.left),
            sliver: SliverToBoxAdapter(child: child),
          );
          final showFailure = works.error != null && works.items.isEmpty;
          final showEmpty =
              !works.loading && works.error == null && works.items.isEmpty;
          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: SizedBox(key: PersonWorksPage.titleKey, height: 0),
              ),
              if (works.loading && works.items.isEmpty)
                box(
                  const LinearProgressIndicator(
                    key: PersonWorksPage.loadingKey,
                  ),
                ),
              if (showFailure)
                box(
                  TvFailure(
                    error: works.error!,
                    retry: () => unawaited(works.load()),
                  ),
                ),
              if (showEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 240 * s,
                    child: TvEmptyState(message: l10n.mobileEmpty),
                  ),
                ),
              if (works.items.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    padding.left,
                    10 * s,
                    padding.right,
                    0,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: metrics.delegate,
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = works.items[index];
                      return KeyedSubtree(
                        key: PersonWorksPage.posterKey(item.id),
                        child: TvPoster(
                          item: item,
                          imageMaxWidth: metrics.imageMaxWidth,
                          onPressed: () => onOpen(context, item),
                        ),
                      );
                    }, childCount: works.items.length),
                  ),
                ),
              if (works.pageError != null)
                box(
                  TvFailure(
                    error: works.pageError!,
                    retry: () => unawaited(works.loadMore()),
                  ),
                ),
              if (works.hasMore && works.pageError == null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    padding.left,
                    20 * s,
                    padding.right,
                    padding.bottom,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TvAction(
                        key: PersonWorksPage.loadMoreKey,
                        pill: true,
                        leading: const Icon(Icons.expand_more_rounded),
                        onPressed: works.loadingMore
                            ? null
                            : () => unawaited(works.loadMore()),
                        child: Text(l10n.mobileLoadMore),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
