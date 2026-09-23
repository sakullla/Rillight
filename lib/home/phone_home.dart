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
            height:
                250 + 35 * (MediaQuery.textScalerOf(context).scale(14) / 14),
            child: ListView.builder(
              key: PageStorageKey('row-${section.title}'),
              scrollDirection: Axis.horizontal,
              itemCount: state.items.length,
              itemBuilder: (context, index) {
                final item = state.items[index];
                final shared = sharePoster(item.id);
                if (section.resume) {
                  return _ResumePoster(
                    item: item,
                    shared: shared,
                    onRemove: () {
                      unawaited(onRemoveFromResume(item));
                    },
                  );
                }
                return _PhonePoster(item: item, shared: shared);
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
    required this.onRemove,
  });

  final EmbyItem item;
  final bool shared;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = item.playbackProgress;
    return SizedBox(
      width: 148,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: CatalogKeys.item(item.id),
                      onTap: () => PhoneMotion.openItem(context, item),
                      child: _sharedPosterImage(item, shared),
                    ),
                  ),
                  if (item.canResume)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        key: CatalogKeys.resumeProgress,
                        value: progress,
                        minHeight: 4,
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
          const SizedBox(height: AppSpacing.xs),
          Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (item.canResume)
            Text(
              l10n.playbackProgress((progress * 100).round()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class _PhonePoster extends StatelessWidget {
  const _PhonePoster({required this.item, required this.shared});

  final EmbyItem item;
  final bool shared;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: shared ? CatalogKeys.item(item.id) : null,
          onTap: () => PhoneMotion.openItem(context, item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _sharedPosterImage(item, shared)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
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
