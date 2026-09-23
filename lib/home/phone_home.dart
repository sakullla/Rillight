import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页行请求的 Limit。满这一页说明货架查询后面还有条目。
const int phoneHomeRowLimit = 24;

/// 手机首页：横幅、四行，以及行后还有内容时的货架入口。
class PhoneHome extends StatelessWidget {
  const PhoneHome({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        final sections = [
          _HomeSection(
            title: l10n.resumeRow,
            state: catalog.resume,
            shelfId: CatalogKeys.shelfResume,
            location: AppRoutes.shelfResume,
            rowKey: CatalogKeys.resumeRow,
            resume: true,
          ),
          _HomeSection(
            title: l10n.nextUpRow,
            state: catalog.nextUp,
            shelfId: CatalogKeys.shelfNextUp,
            location: AppRoutes.shelfNextUp,
            rowKey: CatalogKeys.nextUpRow,
          ),
          _HomeSection(
            title: l10n.latestMoviesRow,
            state: catalog.latestMovies,
            shelfId: CatalogKeys.shelfLatestMovies,
            location: AppRoutes.shelfLatestMovies,
            rowKey: CatalogKeys.latestMoviesRow,
          ),
          _HomeSection(
            title: l10n.latestSeriesRow,
            state: catalog.latestSeries,
            shelfId: CatalogKeys.shelfLatestSeries,
            location: AppRoutes.shelfLatestSeries,
            rowKey: CatalogKeys.latestSeriesRow,
          ),
        ];
        final states = [for (final section in sections) section.state];
        final hasItems = states.any((state) => state.items.isNotEmpty);
        final loading = states.any((state) => state.loading);
        EmbyException? firstError;
        for (final state in states) {
          if (state.error != null) {
            firstError = state.error;
            break;
          }
        }
        // 没有海报时只留一种画面：占位、失败或空。已有海报则保留各行。
        final Widget body;
        if (!hasItems && firstError == null && loading) {
          body = const MobileLoadingPlaceholder.home();
        } else if (!hasItems && firstError != null && !loading) {
          body = MobileFailureState(
            message: catalogFailureMessage(l10n, firstError),
            onRetry: () {
              catalog.reloadHomeRows();
            },
          );
        } else if (!hasItems && !loading) {
          body = MobileEmptyState(
            message: l10n.mobileEmpty,
            actionLabel: l10n.mobileRefresh,
            onAction: () {
              catalog.reload(showCachedFirst: false);
            },
          );
        } else {
          final sharedPosterIds = <String>{};
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PhoneHero(catalog: catalog),
              for (final section in sections)
                _PhoneHomeRow(
                  section: section,
                  retry: () {
                    catalog.reloadHomeRows();
                  },
                  onRemoveFromResume: catalog.hideFromResume,
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

/// 海报卡宽:按屏宽留一页约 2.6 张,不再写死;窄屏收敛到 2 张上下。
double _cardWidthOf(BuildContext context) {
  final available = MediaQuery.sizeOf(context).width - AppSpacing.md * 2;
  return (available / 2.6).clamp(120.0, 180.0);
}

/// 行高 = 2:3 海报区 + 卡下标题块(继续观看卡的信息叠在图内,不占行高)。
double _rowHeightOf(BuildContext context, bool resume) {
  final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
  final titleBlock = AppSpacing.sm + 2 * 20 * textScale + AppSpacing.sm;
  return _cardWidthOf(context) * 1.5 + (resume ? 0 : titleBlock);
}

class _HomeSection {
  const _HomeSection({
    required this.title,
    required this.state,
    required this.shelfId,
    required this.location,
    required this.rowKey,
    this.resume = false,
  });

  final String title;
  final CatalogRowState state;
  final String shelfId;
  final String location;
  final Key rowKey;
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
            height: _rowHeightOf(context, section.resume),
            child: ListView.builder(
              key: PageStorageKey('row-${section.title}'),
              scrollDirection: Axis.horizontal,
              itemCount: state.items.length,
              itemBuilder: (context, index) {
                final item = state.items[index];
                final shared = sharePoster(item.id);
                final cardWidth = _cardWidthOf(context);
                if (section.resume) {
                  return _ResumePoster(
                    item: item,
                    shared: shared,
                    width: cardWidth,
                    onRemove: () {
                      unawaited(onRemoveFromResume(item));
                    },
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

class _ResumePoster extends StatelessWidget {
  const _ResumePoster({
    required this.item,
    required this.shared,
    required this.width,
    required this.onRemove,
  });

  final EmbyItem item;
  final bool shared;
  final double width;
  final VoidCallback onRemove;

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
          image: Stack(
            fit: StackFit.expand,
            children: [
              _sharedPosterImage(item, shared),
              // 渐变信息区:标题/进度压在图片下缘,叠在 AppScrim token 渐变上。
              Align(
                alignment: Alignment.bottomCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        theme.colorScheme.scrim.withValues(alpha: 0),
                        theme.colorScheme.scrim.withValues(
                          alpha: AppScrim.of(context, AppScrim.textStart),
                        ),
                      ],
                      stops: const [
                        AppMobileHero.bottomStart,
                        AppMobileHero.bottomEnd,
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.xl,
                      AppSpacing.sm,
                      AppSpacing.xs,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (item.canResume) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            l10n.playbackProgress((progress * 100).round()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.85,
                              ),
                            ),
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
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  key: CatalogKeys.removeFromResume(item.id),
                  tooltip: l10n.removeFromResume,
                  onPressed: onRemove,
                  icon: const Icon(Icons.close),
                ),
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
/// [footer] 为空时 [image] 铺满整卡(继续观看卡),否则占上方 2:3 区。
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
