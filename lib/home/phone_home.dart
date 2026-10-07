import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/home/library_latest_row.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 首页行请求的 Limit。满这一页说明货架查询后面还有条目。
const int phoneHomeRowLimit = 24;

/// 手机首页：轮播图、继续观看、下一集、片库入口和每个片库的最近添加。
/// 拖动手柄排序，关掉的行归到「未显示」。片库页仍列出全部片库。
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
              hidden:
                  watching.isEmpty &&
                  !catalog.resume.loading &&
                  catalog.resume.error == null,
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
              hidden:
                  nextUpItems.isEmpty &&
                  !catalog.nextUp.loading &&
                  catalog.nextUp.error == null,
              error: nextUpItems.isEmpty ? catalog.nextUp.error : null,
              notice: catalog.nextUp.notice,
            ),
            shelfId: CatalogKeys.shelfNextUp,
            location: AppRoutes.shelfNextUp,
            rowKey: CatalogKeys.nextUpRow,
            wide: true,
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
        // 片库入口单独不算「已有海报」。可见行仍在安静重试时要保持整页骨架，
        // 重试耗尽后仍是整页失败，而不是被片库入口换成空页。
        final pageHasContent = hasItems || hasBanner || wantsLibraries;
        EmbyException? firstError;
        for (final state in states) {
          if (state.error != null) {
            firstError = state.error;
            break;
          }
        }
        // 可见行、轮播图和片库都没有可展示内容时才用整页占位、失败或空。
        final Widget body;
        List<Widget>? sectionChildren;
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
          // Keep each item's route hero owned by the same rail across lazy
          // disposal and reconstruction when the user scrolls back.
          final sharedPosterOwners = <String, String>{};
          final librariesById = {
            for (final library in catalog.libraries) library.id: library,
          };
          const sectionMargin = EdgeInsets.symmetric(horizontal: AppSpacing.md);
          // 区块之间统一 24 的垂直节奏；隐藏的区块不占位。横幅全出血,
          // 排在第一位时伸进状态栏与透明顶栏之下。
          final children = <Widget>[];
          for (final id in visible) {
            if (id == PhoneHomeSectionId.banner) {
              children.add(
                PhoneHero(
                  catalog: catalog,
                  extendBehindTopBar:
                      visible.first == PhoneHomeSectionId.banner,
                ),
              );
              continue;
            }
            final section = byId[id];
            if (section != null) {
              if (section.state.hidden) {
                continue;
              }
              children.add(
                Padding(
                  key: section.rowKey,
                  padding: sectionMargin,
                  child: _PhoneHomeRow(
                    section: section,
                    retry: () {
                      catalog.reloadHomeRows();
                    },
                    onRemoveFromResume: catalog.hideFromResume,
                    sharePoster: (itemId) =>
                        sharedPosterOwners.putIfAbsent(itemId, () => id) == id,
                  ),
                ),
              );
              continue;
            }
            if (id == PhoneHomeSectionId.libraries) {
              if (catalog.libraries.isEmpty) {
                continue;
              }
              children.add(
                Padding(
                  key: const ValueKey('home-section-libraries'),
                  padding: sectionMargin,
                  child: _PhoneLibraryEntry(libraries: catalog.libraries),
                ),
              );
              continue;
            }
            final libraryId = PhoneHomeSectionId.libraryIdOf(id);
            final library = libraryId == null ? null : librariesById[libraryId];
            if (library != null) {
              children.add(
                Padding(
                  key: ValueKey('home-section-library-$libraryId'),
                  padding: sectionMargin,
                  child: _PhoneLibraryLatest(
                    library: library,
                    sharePoster: (itemId) =>
                        sharedPosterOwners.putIfAbsent(
                          itemId,
                          () => 'library-$libraryId',
                        ) ==
                        'library-$libraryId',
                  ),
                ),
              );
            }
          }
          sectionChildren = children;
          body = const SizedBox.shrink();
        }
        final fullBleed =
            sectionChildren != null ||
            (body is MobileLoadingPlaceholder &&
                body.variant == MobileLoadingVariant.home);
        final navClearance = phoneScrollClearance(context);
        // 只有轮播图排在第一并且真有画面时，才让它伸进状态栏。
        // 用户把它调到后面时，第一行仍要躲开透明顶栏。
        final bannerLeads =
            visible.isNotEmpty &&
            visible.first == PhoneHomeSectionId.banner &&
            hasBanner;
        final topInset = sectionChildren != null && !bannerLeads
            ? MediaQuery.viewPaddingOf(context).top + 56 + AppSpacing.md
            : 0.0;
        final page = RefreshIndicator(
          onRefresh: () => catalog.reload(showCachedFirst: false),
          child: ListView.builder(
            key: const PageStorageKey('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
            padding: fullBleed
                ? EdgeInsets.only(
                    top: topInset,
                    bottom: AppSpacing.lg + navClearance,
                  )
                : EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md + navClearance,
                  ),
            itemCount: sectionChildren == null
                ? 1
                : sectionChildren.isEmpty
                ? 0
                : sectionChildren.length * 2 - 1,
            itemBuilder: (context, index) {
              final sections = sectionChildren;
              if (sections == null) return body;
              if (index.isOdd) {
                return const SizedBox(height: AppSpacing.xl);
              }
              return sections[index ~/ 2];
            },
          ),
        );
        return MediaImageScrollListener(child: page);
      },
    );
  }
}

double _cardWidthOf(BuildContext context, {required bool wide}) {
  final screen = MediaQuery.sizeOf(context).width;
  return wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
}

/// 海报卡角标组的定位键。实现已迁入 mobile_widgets(ADR-2),此处保留入口,
/// 既有测试与调用方的 import 不变。
Key phoneHomeBadgesKey(String itemId) => phoneCardBadgesKey(itemId);

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
double _rowHeightOf(BuildContext context, {required bool wide}) =>
    phoneHomeRailHeight(context, wide: wide);

double _wideBadgeHeight(BuildContext context) =>
    phoneHomeWideBadgeHeight(context);

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
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
        if (onMore != null)
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
      ],
    );
    // 区块之间的垂直节奏由首页统一负责，标题只留与卡片的下间距。
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
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
        ((section.resume || section.shelfId == CatalogKeys.shelfLatestSeries)
            ? state.items.isNotEmpty
            : state.items.length >= phoneHomeRowLimit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: section.title,
          onMore: hasMore ? () => context.push(section.location) : null,
          moreKey: hasMore ? CatalogKeys.shelfMore(section.shelfId) : null,
        ),
        if (state.loading && state.items.isEmpty)
          MobileLoadingPlaceholder.row(wide: section.wide),
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
                return PhonePosterCard(
                  item: item,
                  width: cardWidth,
                  hero: shared,
                  pressKey: shared ? CatalogKeys.item(item.id) : null,
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
    final badges = phoneCardBadgeLabels(l10n, item);
    final badgeHeight = _wideBadgeHeight(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: SizedBox(
        width: width,
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: MobilePressable(
            key: CatalogKeys.item(item.id),
            onTap: () => PhoneMotion.openItem(
              context,
              item,
              preferBackdrop: !item.isEpisode,
              maxWidth: PhoneMotion.posterRequestWidth,
            ),
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
                            left: 8,
                            bottom: 8,
                            child: IconButton.filled(
                              key: Key('phone-resume-play-${item.id}'),
                              tooltip: l10n.resumePlay,
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                              ),
                              onPressed: () => context.push<void>(
                                '/play/${item.id}',
                                extra: PlayerOpenRequest(
                                  itemId: item.id,
                                  autoResume: true,
                                ),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                            ),
                          ),

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
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (badges.isNotEmpty)
                        SizedBox(
                          height: badgeHeight,
                          child: ClipRect(
                            child: PhoneCardBadges(
                              itemId: item.id,
                              labels: badges,
                            ),
                          ),
                        ),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      // 进度百分比由角标承载,页脚只保留季集/集名或年份。
                      if (meta.isNotEmpty)
                        Text(
                          meta,
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
    // 与继续观看横卡同宽：一屏一张多，露出下一张。
    final cardWidth = phoneHomeWideCardWidth(screen);
    final cardHeight = cardWidth * 9 / 16;
    return Column(
      key: const Key('phone-home-libraries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: l10n.phoneHomeSectionLibraries),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: libraries.length,
            itemBuilder: (context, index) {
              final library = libraries[index];
              final hasImage = _libraryHasImage(library);
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: SizedBox(
                  width: cardWidth,
                  height: cardHeight,
                  child: MobilePressable(
                    key: Key('phone-home-library-${library.id}'),
                    onTap: () => context.push(AppRoutes.library(library.id)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      child: ColoredBox(
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (hasImage)
                              MediaImage(
                                item: library,
                                preferBackdrop: true,
                                maxWidth: 480,
                              ),
                            if (hasImage)
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x00000000),
                                      Color(0xB3000000),
                                    ],
                                  ),
                                ),
                              ),
                            Align(
                              alignment: hasImage
                                  ? Alignment.bottomLeft
                                  : Alignment.center,
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.md),
                                child: Text(
                                  library.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: hasImage
                                        ? Colors.white
                                        : theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ],
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

class _PhoneLibraryLatest extends StatelessWidget {
  const _PhoneLibraryLatest({required this.library, required this.sharePoster});

  final EmbyItem library;
  final bool Function(String id) sharePoster;

  @override
  Widget build(BuildContext context) {
    return LibraryLatestData(
      library: library,
      builder: (context, snapshot) {
        if (!snapshot.loading &&
            snapshot.error == null &&
            snapshot.items.isEmpty) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final title = l10n.phoneHomeLibraryLatest(library.name);
        return Column(
          key: Key('phone-home-library-latest-${library.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(
              title: title,
              moreKey: CatalogKeys.shelfMore('library-${library.id}'),
              onMore: () => context.push(AppRoutes.library(library.id)),
            ),
            if (snapshot.loading && snapshot.items.isEmpty)
              const MobileLoadingPlaceholder.row(),
            if (snapshot.error != null)
              MobileFailureState(
                message: catalogFailureMessage(l10n, snapshot.error!),
                onRetry: snapshot.retry,
              ),
            if (snapshot.items.isNotEmpty)
              SizedBox(
                height: _rowHeightOf(context, wide: false),
                child: ListView.builder(
                  key: PageStorageKey('row-$title'),
                  scrollDirection: Axis.horizontal,
                  itemCount: snapshot.items.length,
                  itemBuilder: (context, index) {
                    final item = snapshot.items[index];
                    final shared = sharePoster(item.id);
                    return PhonePosterCard(
                      item: item,
                      width: _cardWidthOf(context, wide: false),
                      hero: shared,
                      pressKey: shared ? CatalogKeys.item(item.id) : null,
                      includePlaybackBadges: false,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

Widget _sharedPosterImage(EmbyItem item, bool shared) {
  final image = MediaImage(
    item: item,
    fit: BoxFit.cover,
    preferBackdrop: !item.isEpisode,
    preferThumb: item.isEpisode,
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
