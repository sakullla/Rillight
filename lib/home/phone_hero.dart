import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/media_image/media_image.dart';

/// 手机首页横幅。候选规则与桌面首页横幅相同，但不把那个组件装进手机：
/// 它依赖桌面顶栏重叠。点按画面暂停；减少动效时不轮换。
class PhoneHero extends StatefulWidget {
  const PhoneHero({super.key, required this.catalog});

  final CatalogController catalog;

  static const bannerKey = Key('phone-hero');
  static const pauseKey = Key('phone-hero-pause');
  static const openKey = Key('phone-hero-open');

  static const maxFeatured = 5;
  static const autoAdvanceInterval = Duration(seconds: 6);

  /// flutter test 默认关闭，避免周期计时拖住 pumpAndSettle。
  static bool autoAdvanceEnabled =
      Platform.environment['FLUTTER_TEST'] != 'true';

  static Key itemKey(String id) => ValueKey('phone-hero-$id');

  /// 继续观看优先，其次最新电影、最新剧集；按 id 去重，最多 [maxFeatured] 条。
  static List<EmbyItem> featuredItemsOf(CatalogController catalog) {
    final seen = <String>{};
    final items = <EmbyItem>[];
    void addAll(Iterable<EmbyItem> source, {bool playableOnly = false}) {
      for (final item in source) {
        if (items.length >= maxFeatured) {
          return;
        }
        if (playableOnly && !item.isPlayable && !item.isSeries) {
          continue;
        }
        if (seen.add(item.id)) {
          items.add(item);
        }
        if (items.length >= maxFeatured) {
          return;
        }
      }
    }

    addAll(catalog.resume.items, playableOnly: true);
    addAll(catalog.latestMovies.items);
    addAll(catalog.latestSeries.items);
    return items;
  }

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> {
  int _index = 0;
  bool _paused = false;
  Timer? _timer;

  List<EmbyItem> get _featured => PhoneHero.featuredItemsOf(widget.catalog);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _reduceMotion {
    return MediaQuery.disableAnimationsOf(context) ||
        AppMotion.durationOf(context) == Duration.zero;
  }

  bool get _canAutoAdvance {
    return PhoneHero.autoAdvanceEnabled &&
        !_paused &&
        TickerMode.valuesOf(context).enabled &&
        !_reduceMotion;
  }

  void _syncTimer(int count) {
    final want = _canAutoAdvance && count > 1;
    if (want) {
      _timer ??= Timer.periodic(PhoneHero.autoAdvanceInterval, (_) {
        _advance();
      });
      return;
    }
    _timer?.cancel();
    _timer = null;
  }

  void _advance() {
    if (!mounted || !_canAutoAdvance) {
      return;
    }
    final count = _featured.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = (_index + 1) % count);
  }

  void _pauseFromTap() {
    if (_reduceMotion || _paused || _featured.length < 2) {
      return;
    }
    setState(() => _paused = true);
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
  }

  @override
  Widget build(BuildContext context) {
    final items = _featured;
    _syncTimer(items.length);
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final index = _index % items.length;
    final item = items[index];
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    final rotating = items.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = math.max(width * 9 / 16, 260.0);
        return ClipRRect(
          key: PhoneHero.bannerKey,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pauseFromTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  KeyedSubtree(
                    key: PhoneHero.itemKey(item.id),
                    child: PhoneMotion.sharedImage(
                      itemId: item.id,
                      preferBackdrop: true,
                      child: MediaImage(
                        item: item,
                        preferBackdrop: true,
                        maxWidth: PhoneMotion.heroRequestWidth,
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.colorScheme.scrim.withValues(alpha: 0),
                          theme.colorScheme.scrim.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                  ),
                  if (rotating)
                    Positioned(
                      top: AppSpacing.xxs,
                      right: AppSpacing.xxs,
                      child: IconButton(
                        key: PhoneHero.pauseKey,
                        tooltip: _paused || _reduceMotion
                            ? l10n.resumeCarousel
                            : l10n.pauseCarousel,
                        onPressed: _reduceMotion ? null : _togglePause,
                        icon: Icon(
                          _paused || _reduceMotion
                              ? Icons.play_arrow
                              : Icons.pause,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (item.canResume) ...[
                          const SizedBox(height: AppSpacing.xs),
                          LinearProgressIndicator(
                            key: CatalogKeys.resumeProgress,
                            value: item.playbackProgress,
                            minHeight: 4,
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            l10n.playbackProgress(
                              (item.playbackProgress * 100).round(),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                        if (rotating) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              for (var i = 0; i < items.length; i++)
                                Container(
                                  key: CatalogKeys.heroDot(i),
                                  width: i == index ? 16 : 6,
                                  height: 6,
                                  margin: const EdgeInsets.only(
                                    right: AppSpacing.xs,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurface
                                        .withValues(
                                          alpha: i == index ? 1 : 0.4,
                                        ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.sm,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppSpacing.sm),
                        FilledButton.icon(
                          key: PhoneHero.openKey,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => PhoneMotion.openItem(
                            context,
                            item,
                            preferBackdrop: true,
                            maxWidth: PhoneMotion.heroRequestWidth,
                          ),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            item.canResume ? l10n.resumePlay : l10n.play,
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
      },
    );
  }
}
