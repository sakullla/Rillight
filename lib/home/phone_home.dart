import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页行请求的 Limit。满这一页说明货架查询后面还有条目。
const int phoneHomeRowLimit = 24;

/// 每个片库在首页只预览一屏多一点，完整列表从「更多」进入。
const int phoneHomeLibraryPreview = 12;

/// 片库预览同时最多打两条请求，避免和首屏四行抢连接。
final _homeLibraryLoads = _LoadGate(2);

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
  EmbyItem? _heroItem;

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
        final watching = continueWatchingItems(
          catalog.resume.items,
          catalog.nextUp.items,
        );
        final watchingIds = {for (final item in watching) item.id};
        final nextUpItems = [
          for (final item in catalog.nextUp.items)
            if (!watchingIds.contains(item.id)) item,
        ];
        final byId = {
          PhoneHomeSectionId.resume: _HomeSection(
            title: l10n.resumeRow,
            state: CatalogRowState(
              items: watching,
              loading: catalog.resume.loading && watching.isEmpty,
              hidden: watching.isEmpty,
              error: watching.isEmpty ? catalog.resume.error : null,
              notice: catalog.resume.notice,
            ),
            shelfId: CatalogKeys.shelfResume,
            location: AppRoutes.shelfResume,
            rowKey: CatalogKeys.resumeRow,
            wide: true,
            resume: true,
          ),
          PhoneHomeSectionId.nextUp: _HomeSection(
            title: l10n.nextUpRow,
            state: CatalogRowState(
              items: nextUpItems,
              loading: catalog.nextUp.loading && nextUpItems.isEmpty,
              hidden: nextUpItems.isEmpty,
              error: nextUpItems.isEmpty ? catalog.nextUp.error : null,
              notice: catalog.nextUp.notice,
            ),
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
        // 片库入口单独不算「已有海报」。四行仍在安静重试时要保持整页骨架，
        // 重试耗尽后仍是整页失败，而不是被片库入口换成空页或行内占位。
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
        if (!hasItems && !hasBanner && firstError == null && loading) {
          body = const MobileLoadingPlaceholder.home();
        } else if (!hasItems && !hasBanner && firstError != null && !loading) {
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
          const sectionPadding = EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            0,
          );
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final id in visible)
                if (id == PhoneHomeSectionId.banner)
                  PhoneHero(
                    catalog: catalog,
                    onItem: (item) {
                      if (_heroItem?.id == item.id) {
                        return;
                      }
                      setState(() => _heroItem = item);
                    },
                  )
                else if (byId[id] != null)
                  Padding(
                    padding: sectionPadding,
                    child: _PhoneHomeRow(
                      section: byId[id]!,
                      retry: () {
                        catalog.reloadHomeRows();
                      },
                      onRemoveFromResume: catalog.hideFromResume,
                      sharePoster: sharedPosterIds.add,
                    ),
                  )
                else if (id == PhoneHomeSectionId.libraries)
                  Padding(
                    padding: sectionPadding,
                    child: _PhoneLibraryEntry(libraries: catalog.libraries),
                  )
                else if (PhoneHomeSectionId.libraryIdOf(id) != null &&
                    librariesById[PhoneHomeSectionId.libraryIdOf(id)!] != null)
                  Padding(
                    padding: sectionPadding,
                    child: _PhoneLibraryLatest(
                      library:
                          librariesById[PhoneHomeSectionId.libraryIdOf(id)!]!,
                      sharePoster: sharedPosterIds.add,
                    ),
                  ),
            ],
          );
        }
        final fullBleed =
            body is Column ||
            (body is MobileLoadingPlaceholder &&
                body.variant == MobileLoadingVariant.home);
        final navClearance = phoneScrollClearance(context);
        final page = RefreshIndicator(
          onRefresh: () => catalog.reload(showCachedFirst: false),
          child: ListView(
            key: const PageStorageKey('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: fullBleed
                ? EdgeInsets.only(bottom: AppSpacing.lg + navClearance)
                : EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md + navClearance,
                  ),
            children: [body],
          ),
        );
        final hero = _heroItem;
        if (hero == null) {
          return page;
        }
        return ContentTheme(
          item: hero,
          preferBackdrop: true,
          fillSurface: true,
          child: page,
        );
      },
    );
  }
}

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

String _resumeTitle(EmbyItem item) {
  final series = item.seriesName?.trim();
  if (item.isEpisode && series != null && series.isNotEmpty) {
    return series;
  }
  return item.name;
}

String _resumeMeta(EmbyItem item, String title) {
  if (!item.isEpisode) {
    final year = item.productionYear;
    return year != null && year > 0 ? '$year' : '';
  }
  final code = seasonEpisodeCode(item);
  final name = item.name.trim();
  if (code == null) {
    return name == title ? '' : name;
  }
  if (name.isEmpty || name == title) {
    return code;
  }
  return '$code · $name';
}

/// 行高 = 图区 + 图下标题。横卡的进度在画面底边，移除按钮叠在画面角上。
double _rowHeightOf(BuildContext context, {required bool wide}) {
  final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
  final width = _cardWidthOf(context, wide: wide);
  if (!wide) {
    final line = 14 * 1.45 * textScale;
    final yearLine = 12 * 1.2 * textScale;
    final titleBlock = AppSpacing.xs * 2 + line + 2 + yearLine;
    return width * 1.5 + titleBlock;
  }
  final titleLine = 14 * 1.2 * textScale;
  final meta = 12 * 1.2 * textScale;
  return width * 9 / 16 + 6 + titleLine + meta + 4;
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

/// 分栏标题。能进入完整列表时，箭头贴在标题右侧，整段都可点。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.onMore, this.moreKey});

  final String title;
  final VoidCallback? onMore;
  final Key? moreKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
        if (onMore != null)
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: onMore == null
            ? label
            : Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: moreKey,
                  onTap: onMore,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: label,
                ),
              ),
      ),
    );
  }
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
        state.error == null &&
        (section.resume
            ? state.items.isNotEmpty
            : state.items.length >= phoneHomeRowLimit);
    return Column(
      key: section.rowKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: section.title,
          onMore: hasMore ? () => context.push(section.location) : null,
          moreKey: hasMore ? CatalogKeys.shelfMore(section.shelfId) : null,
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
            height: _rowHeightOf(context, wide: section.wide),
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
                    onRemove: section.resume && item.canResume
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
    final title = _resumeTitle(item);
    final meta = _resumeMeta(item, title);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(
        width: width,
        child: MobilePressable(
          key: CatalogKeys.item(item.id),
          onTap: () => PhoneMotion.openItem(context, item),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      _sharedPosterImage(item, shared),
                      if (item.canResume)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SizedBox(
                            key: CatalogKeys.resumeProgress,
                            height: 4,
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.45),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: progress.clamp(0.0, 1.0),
                                child: ColoredBox(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (onRemove != null)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Tooltip(
                            message: l10n.removeFromResume,
                            child: GestureDetector(
                              key: CatalogKeys.removeFromResume(item.id),
                              behavior: HitTestBehavior.opaque,
                              onTap: onRemove,
                              child: const SizedBox(
                                width: 48,
                                height: 48,
                                child: Center(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Color(0x8C000000),
                                      shape: BoxShape.circle,
                                    ),
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: Icon(
                                        Icons.close,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              Row(
                children: [
                  if (meta.isNotEmpty)
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.2,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (item.canResume)
                    Text(
                      l10n.playbackProgress((progress * 100).round()),
                      maxLines: 1,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.2,
                      ),
                    ),
                ],
              ),
            ],
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                if (item.productionYear != null && item.productionYear! > 0)
                  Text(
                    '${item.productionYear}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报卡外壳:AppRadii 圆角 + AppMobileCard 阴影 + MobilePressable 按压反馈。
/// [footer] 为空时 [image] 铺满整卡,否则图区按 2:3。
class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.shared,
    required this.image,
    this.footer,
    this.pressKey,
  });

  final EmbyItem item;
  final bool shared;
  final Widget image;
  final Widget? footer;
  final Key? pressKey;

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
                      AspectRatio(aspectRatio: 2 / 3, child: image),
                      footer!,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

bool _libraryHasImage(EmbyItem library) {
  bool tagged(String? tag) => tag != null && tag.isNotEmpty;
  return tagged(library.primaryImageTag) ||
      tagged(library.backdropImageTag) ||
      tagged(library.thumbImageTag);
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
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    final available = screen - AppSpacing.md * 2;
    final cardWidth = (available - AppSpacing.sm) / 2.15;
    final cardHeight = cardWidth * 9 / 16;
    return Column(
      key: const Key('phone-home-libraries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Text(
            l10n.phoneHomeSectionLibraries,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: libraries.length,
            itemBuilder: (context, index) {
              final library = libraries[index];
              final hasImage = _libraryHasImage(library);
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: SizedBox(
                  width: cardWidth,
                  height: cardHeight,
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: Key('phone-home-library-${library.id}'),
                      onTap: () => context.push(AppRoutes.library(library.id)),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (hasImage)
                            MediaImage(
                              item: library,
                              preferBackdrop: true,
                              maxWidth: 320,
                            ),
                          if (hasImage)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    theme.colorScheme.scrim.withValues(
                                      alpha: 0,
                                    ),
                                    theme.colorScheme.scrim.withValues(
                                      alpha: 0.72,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          Align(
                            alignment: hasImage
                                ? Alignment.bottomLeft
                                : Alignment.center,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: Text(
                                library.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ],
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
    final request = catalogItemsRequest(
      userId: catalog.client.userId ?? '',
      parentId: widget.library.id,
      includeItemTypes: _latestTypes(widget.library),
      recursive: true,
      limit: phoneHomeLibraryPreview,
      sortBy: 'DateCreated',
      sortOrder: 'Descending',
      fields: EmbyClient.homePosterFields,
    );
    final hit = await catalog.cache.lookup(request);
    if (!mounted) {
      return;
    }
    if (hit != null) {
      final cached = parseCatalogPage(hit.json).items;
      if (cached.isNotEmpty) {
        setState(() {
          _items = cached;
          _loading = false;
          _error = null;
        });
      }
    }
    try {
      final items = await _homeLibraryLoads.run(
        () => catalog.cache.fetch(catalog.client, request),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _items = parseCatalogPage(items).items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (_items.isNotEmpty) {
        setState(() => _loading = false);
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
        _SectionTitle(
          title: title,
          moreKey: CatalogKeys.shelfMore('library-${widget.library.id}'),
          onMore: () => context.push(AppRoutes.library(widget.library.id)),
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
            height: _rowHeightOf(context, wide: false),
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

/// 限制同时进行的首页片库请求。完成一条再放行下一条。
class _LoadGate {
  _LoadGate(this._limit);

  final int _limit;
  var _active = 0;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_active >= _limit) {
      final ticket = Completer<void>();
      _waiters.add(ticket);
      await ticket.future;
    }
    _active++;
    try {
      return await job();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
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
