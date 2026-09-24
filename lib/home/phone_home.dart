import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页行请求的 Limit。满这一页说明货架查询后面还有条目。
const int phoneHomeRowLimit = 24;

/// 手机首页：横幅、可配置区块，以及行后还有内容时的货架入口。
class PhoneHome extends StatefulWidget {
  const PhoneHome({super.key, this.sections});

  final PhoneHomeSectionController? sections;

  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<PhoneHome> {
  PhoneHomeSectionController? _sections;
  var _loadedServerId = '';

  PhoneHomeSectionController get _controller =>
      _sections ?? PhoneHomeSectionController.app();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.sections ?? PhoneHomeSectionController.app();
    if (!identical(next, _sections)) {
      _sections = next;
      _loadedServerId = '';
    }
    final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
    if (_loadedServerId == serverId) {
      return;
    }
    _loadedServerId = serverId;
    unawaited(_controller.load(serverId));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([catalog, _controller]),
      builder: (context, _) {
        final byId = {
          PhoneHomeSectionId.resume: _HomeSection(
            title: l10n.resumeRow,
            state: catalog.resume,
            shelfId: CatalogKeys.shelfResume,
            location: AppRoutes.shelfResume,
            rowKey: CatalogKeys.resumeRow,
            wide: true,
            resume: true,
          ),
          PhoneHomeSectionId.nextUp: _HomeSection(
            title: l10n.nextUpRow,
            state: catalog.nextUp,
            shelfId: CatalogKeys.shelfNextUp,
            location: AppRoutes.shelfNextUp,
            rowKey: CatalogKeys.nextUpRow,
            wide: true,
          ),
          PhoneHomeSectionId.latestMovies: _HomeSection(
            title: l10n.latestMoviesRow,
            state: catalog.latestMovies,
            shelfId: CatalogKeys.shelfLatestMovies,
            location: AppRoutes.shelfLatestMovies,
            rowKey: CatalogKeys.latestMoviesRow,
          ),
          PhoneHomeSectionId.latestSeries: _HomeSection(
            title: l10n.latestSeriesRow,
            state: catalog.latestSeries,
            shelfId: CatalogKeys.shelfLatestSeries,
            location: AppRoutes.shelfLatestSeries,
            rowKey: CatalogKeys.latestSeriesRow,
          ),
        };
        final visible = _controller.visibleIds(catalog.libraries);
        final sections = [
          for (final id in visible)
            if (byId[id] != null) byId[id]!,
        ];
        final states = [for (final section in sections) section.state];
        final hasItems = states.any((state) => state.items.isNotEmpty);
        final loading = states.any((state) => state.loading);
        final hasBanner =
            visible.contains(PhoneHomeSectionId.banner) &&
            PhoneHero.featuredItemsOf(catalog).isNotEmpty;
        final wantsLibraries =
            catalog.libraries.isNotEmpty &&
            visible.any(
              (id) =>
                  id == PhoneHomeSectionId.libraries ||
                  PhoneHomeSectionId.libraryIdOf(id) != null,
            );
        final pageHasContent = hasItems || hasBanner || wantsLibraries;
        EmbyException? firstError;
        for (final state in states) {
          if (state.error != null) {
            firstError = state.error;
            break;
          }
        }
        // 四行、横幅、片库入口和最近添加都没有可展示内容时才用整页占位、失败或空。
        // 横幅候选来自被隐藏的行时，仍要画出横幅。
        final Widget body;
        if (!pageHasContent && firstError == null && loading) {
          body = const MobileLoadingPlaceholder.home();
        } else if (!pageHasContent && firstError != null && !loading) {
          body = MobileFailureState(
            message: catalogFailureMessage(l10n, firstError),
            onRetry: () {
              catalog.reloadHomeRows();
            },
          );
        } else if (!pageHasContent && !loading) {
          body = MobileEmptyState(
            message: l10n.mobileEmpty,
            actionLabel: l10n.mobileRefresh,
            onAction: () {
              catalog.reload(showCachedFirst: false);
            },
          );
        } else {
          final sharedPosterIds = <String>{};
          final librariesById = {
            for (final library in catalog.libraries) library.id: library,
          };
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final id in visible)
                if (id == PhoneHomeSectionId.banner)
                  PhoneHero(catalog: catalog)
                else if (byId[id] != null)
                  _PhoneHomeRow(
                    section: byId[id]!,
                    retry: () {
                      catalog.reloadHomeRows();
                    },
                    onRemoveFromResume: catalog.hideFromResume,
                    sharePoster: sharedPosterIds.add,
                  )
                else if (id == PhoneHomeSectionId.libraries)
                  _PhoneLibraryEntry(libraries: catalog.libraries)
                else if (PhoneHomeSectionId.libraryIdOf(id) != null &&
                    librariesById[PhoneHomeSectionId.libraryIdOf(id)!] != null)
                  _PhoneLibraryLatest(
                    library:
                        librariesById[PhoneHomeSectionId.libraryIdOf(id)!]!,
                    sharePoster: sharedPosterIds.add,
                  ),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: _refreshHit),
                onPressed: () {
                  catalog.reload(showCachedFirst: false);
                },
                icon: const Icon(Icons.refresh),
                label: Text(l10n.mobileRefresh),
              ),
            ],
          );
        }
        return RefreshIndicator(
          onRefresh: () => catalog.reload(showCachedFirst: false),
          child: ListView(
            key: const PageStorageKey('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [body],
          ),
        );
      },
    );
  }
}

const Size _refreshHit = Size(AppSpacing.huge, AppSpacing.huge);

/// 最近电影/剧集卡宽：一屏约 3 张完整 2:3 海报，再露出下一张。
double phoneHomePosterCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return (available - AppSpacing.sm * 3) / 3.3;
}

/// 继续观看/下一集横卡宽：一屏并排约两张 16:9，并露出下一张。
double phoneHomeWideCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return (available - AppSpacing.sm * 2) / 2.3;
}

double _cardWidthOf(BuildContext context, {required bool wide}) {
  final screen = MediaQuery.sizeOf(context).width;
  return wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
}

/// 行高 = 图区 + 卡下标题；横卡另留进度行，移除按钮在标题行而不压住画面。
double _rowHeightOf(
  BuildContext context, {
  required bool wide,
  required bool resume,
}) {
  final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
  final width = _cardWidthOf(context, wide: wide);
  if (!wide) {
    final titleBlock = AppSpacing.sm + 2 * 20 * textScale + AppSpacing.sm;
    return width * 1.5 + titleBlock;
  }
  final titleLine = resume ? 48.0 : 22 * textScale;
  final progress = AppSpacing.xxs + 16 * textScale + AppSpacing.xxs + 4;
  return width * 9 / 16 + AppSpacing.xs + titleLine + progress + AppSpacing.sm;
}

class _HomeSection {
  const _HomeSection({
    required this.title,
    required this.state,
    required this.shelfId,
    required this.location,
    required this.rowKey,
    this.wide = false,
    this.resume = false,
  });

  final String title;
  final CatalogRowState state;
  final String shelfId;
  final String location;
  final Key rowKey;
  final bool wide;
  final bool resume;
}

class _PhoneHomeRow extends StatelessWidget {
  const _PhoneHomeRow({
    required this.section,
    required this.retry,
    required this.onRemoveFromResume,
    required this.sharePoster,
  });

  final _HomeSection section;
  final VoidCallback retry;
  final Future<void> Function(EmbyItem item) onRemoveFromResume;

  /// 同一条目只让第一张海报参与飞行，避免同一路由里标签重复。
  final bool Function(String id) sharePoster;

  @override
  Widget build(BuildContext context) {
    final state = section.state;
    if (state.hidden) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final problem = state.error ?? state.notice;
    final hasMore =
        state.error == null && state.items.length >= phoneHomeRowLimit;
    return Column(
      key: section.rowKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (hasMore)
                TextButton(
                  key: CatalogKeys.shelfMore(section.shelfId),
                  style: TextButton.styleFrom(minimumSize: _refreshHit),
                  onPressed: () => context.push(section.location),
                  child: Text(l10n.more),
                ),
            ],
          ),
        ),
        if (state.loading && state.items.isEmpty)
          const MobileLoadingPlaceholder.row(),
        if (problem != null)
          MobileFailureState(
            message: catalogFailureMessage(l10n, problem),
            onRetry: retry,
          ),
        if (state.items.isNotEmpty)
          SizedBox(
            height: _rowHeightOf(
              context,
              wide: section.wide,
              resume: section.resume,
            ),
            child: ListView.builder(
              key: PageStorageKey('row-${section.title}'),
              scrollDirection: Axis.horizontal,
              itemCount: state.items.length,
              itemBuilder: (context, index) {
                final item = state.items[index];
                final shared = sharePoster(item.id);
                final cardWidth = _cardWidthOf(context, wide: section.wide);
                if (section.wide) {
                  return _WideCard(
                    item: item,
                    shared: shared,
                    width: cardWidth,
                    onRemove: section.resume
                        ? () {
                            unawaited(onRemoveFromResume(item));
                          }
                        : null,
                  );
                }
                return _PhonePoster(
                  item: item,
                  shared: shared,
                  width: cardWidth,
                );
              },
            ),
          ),
      ],
    );
  }
}

class _WideCard extends StatelessWidget {
  const _WideCard({
    required this.item,
    required this.shared,
    required this.width,
    this.onRemove,
  });

  final EmbyItem item;
  final bool shared;
  final double width;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final progress = item.playbackProgress;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(
        width: width,
        child: _PosterCard(
          pressKey: CatalogKeys.item(item.id),
          item: item,
          shared: shared,
          aspectRatio: 16 / 9,
          image: _sharedPosterImage(item, shared),
          footer: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onRemove != null)
                      IconButton(
                        key: CatalogKeys.removeFromResume(item.id),
                        tooltip: l10n.removeFromResume,
                        visualDensity: VisualDensity.compact,
                        onPressed: onRemove,
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                if (item.canResume) ...[
                  Text(
                    l10n.playbackProgress((progress * 100).round()),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  LinearProgressIndicator(
                    key: CatalogKeys.resumeProgress,
                    value: progress,
                    minHeight: 3,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhonePoster extends StatelessWidget {
  const _PhonePoster({
    required this.item,
    required this.shared,
    required this.width,
  });

  final EmbyItem item;
  final bool shared;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(
        width: width,
        child: _PosterCard(
          pressKey: shared ? CatalogKeys.item(item.id) : null,
          item: item,
          shared: shared,
          image: _sharedPosterImage(item, shared),
          footer: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报卡外壳:AppRadii 圆角 + AppMobileCard 阴影 + MobilePressable 按压反馈。
/// [footer] 为空时 [image] 铺满整卡,否则图区使用 [aspectRatio]。
class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.shared,
    required this.image,
    this.footer,
    this.pressKey,
    this.aspectRatio = 2 / 3,
  });

  final EmbyItem item;
  final bool shared;
  final Widget image;
  final Widget? footer;
  final Key? pressKey;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MobilePressable(
      key: pressKey,
      onTap: () => PhoneMotion.openItem(context, item),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.scrim.withValues(
                alpha: AppMobileCard.shadowAlpha,
              ),
              blurRadius: AppMobileCard.shadowBlur,
              spreadRadius: AppMobileCard.shadowSpread,
              offset: const Offset(0, AppMobileCard.shadowOffsetY),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          // 图缺失时 MediaImage 落主题化占位,底衬与页面分层。
          child: ColoredBox(
            color: theme.colorScheme.surfaceContainerLow,
            child: footer == null
                ? image
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(aspectRatio: aspectRatio, child: image),
                      footer!,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _PhoneLibraryEntry extends StatelessWidget {
  const _PhoneLibraryEntry({required this.libraries});

  final List<EmbyItem> libraries;

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final width = phoneHomeWideCardWidth(MediaQuery.sizeOf(context).width);
    return Column(
      key: const Key('phone-home-libraries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text(
            l10n.phoneHomeSectionLibraries,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        SizedBox(
          height: width * 9 / 16,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: libraries.length,
            itemBuilder: (context, index) {
              final library = libraries[index];
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: SizedBox(
                  width: width,
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: Key('phone-home-library-${library.id}'),
                      onTap: () => context.push(AppRoutes.library(library.id)),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Text(
                            library.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PhoneLibraryLatest extends StatefulWidget {
  const _PhoneLibraryLatest({required this.library, required this.sharePoster});

  final EmbyItem library;
  final bool Function(String id) sharePoster;

  @override
  State<_PhoneLibraryLatest> createState() => _PhoneLibraryLatestState();
}

class _PhoneLibraryLatestState extends State<_PhoneLibraryLatest> {
  List<EmbyItem> _items = const [];
  var _loading = true;
  EmbyException? _error;
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final catalog = CatalogScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await catalog.auth.client.getItems(
        parentId: widget.library.id,
        includeItemTypes: _latestTypes(widget.library),
        recursive: true,
        limit: phoneHomeRowLimit,
        sortBy: 'DateCreated',
        sortOrder: 'Descending',
        fields: EmbyClient.gridFields,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loading && _error == null && _items.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final title = l10n.phoneHomeLibraryLatest(widget.library.name);
    return Column(
      key: Key('phone-home-library-latest-${widget.library.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (_loading && _items.isEmpty) const MobileLoadingPlaceholder.row(),
        if (_error != null)
          MobileFailureState(
            message: catalogFailureMessage(l10n, _error!),
            onRetry: () {
              unawaited(_load());
            },
          ),
        if (_items.isNotEmpty)
          SizedBox(
            height: _rowHeightOf(context, wide: false, resume: false),
            child: ListView.builder(
              key: PageStorageKey('row-$title'),
              scrollDirection: Axis.horizontal,
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return _PhonePoster(
                  item: item,
                  shared: widget.sharePoster(item.id),
                  width: _cardWidthOf(context, wide: false),
                );
              },
            ),
          ),
      ],
    );
  }
}

String _latestTypes(EmbyItem library) {
  return switch (library.collectionTypeNormalized) {
    'movies' => 'Movie',
    'tvshows' => 'Series',
    _ => 'Movie,Series',
  };
}

Widget _sharedPosterImage(EmbyItem item, bool shared) {
  final image = MediaImage(
    item: item,
    maxWidth: PhoneMotion.posterRequestWidth,
  );
  if (!shared) {
    return image;
  }
  return PhoneMotion.sharedImage(
    itemId: item.id,
    preferBackdrop: false,
    child: image,
  );
}
