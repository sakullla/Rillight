import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/player/player_window_host.dart';

/// A continuous artwork composition with a readable, surface-toned caption.
class PhoneHero extends StatefulWidget {
  const PhoneHero({super.key, required this.catalog, this.onItem});
  final CatalogController catalog;
  final ValueChanged<EmbyItem>? onItem;
  static const bannerKey = Key('phone-hero');
  static const openKey = Key('phone-hero-open');
  static const maxFeatured = 5;
  static Key itemKey(String id) => ValueKey('phone-hero-$id');
  static List<EmbyItem> featuredItemsOf(CatalogController catalog) =>
      featuredHomeItems(catalog, limit: maxFeatured);
  static double contentHeightFor(double width, {double textScale = 1}) =>
      (width - 32) * 9 / 16 + 120 * textScale + 44;

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> {
  int _index = 0;
  String? _reportedId;
  final PageController _page = PageController();
  List<EmbyItem> get _featured => PhoneHero.featuredItemsOf(widget.catalog);

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _open(EmbyItem item) {
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    PhoneMotion.openItem(
      context,
      artwork.handoffItem(item),
      preferBackdrop: true,
      maxWidth: PhoneMotion.heroRequestWidth,
    );
  }

  void _goTo(int value) {
    _page.animateToPage(
      value,
      duration: AppMotion.durationOf(context),
      curve: AppMotion.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _featured;
    if (items.isEmpty) return const SizedBox.shrink();
    final index = _index % items.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final top = MediaQuery.viewPaddingOf(context).top + 56;
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final height =
            top + PhoneHero.contentHeightFor(width, textScale: scale);
        _report(items[index]);
        return SizedBox(
          key: PhoneHero.bannerKey,
          width: width,
          height: height,
          child: Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _page,
                    physics: items.length > 1
                        ? const PageScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    onPageChanged: (value) {
                      setState(() => _index = value);
                      _report(items[value]);
                    },
                    itemBuilder: (context, page) {
                      final item = items[page];
                      final artwork = heroArtworkSources(
                        item,
                        series: widget.catalog.latestSeries.items,
                      );
                      return ContentTheme(
                        key: PhoneHero.itemKey(item.id),
                        item: artwork.themeItem,
                        fillSurface: false,
                        child: Builder(
                          builder: (context) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Material(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(24),
                              clipBehavior: Clip.antiAlias,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: 0,
                                    height: (width - 32) * 9 / 16,
                                    child: AspectRatio(
                                      aspectRatio: 16 / 9,
                                      child: GestureDetector(
                                        key: page == index
                                            ? PhoneHero.openKey
                                            : null,
                                        onTap: () => _open(item),
                                        child: RepaintBoundary(
                                          child: PhoneMotion.sharedImage(
                                            itemId: item.id,
                                            preferBackdrop: true,
                                            child: HeroArtwork(
                                              sources: artwork,
                                              requestWidth:
                                                  PhoneMotion.heroRequestWidth,
                                              compact: true,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            stops: const [0, .30, .67, 1],
                                            colors: [
                                              Colors.transparent,
                                              Colors.transparent,
                                              Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerLow
                                                  .withValues(alpha: .94),
                                              Theme.of(
                                                context,
                                              ).colorScheme.surfaceContainerLow,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 20,
                                    right: 20,
                                    bottom: 16,
                                    child: _HeroCaption(
                                      item: item,
                                      onOpen: () => _open(item),
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
                if (items.length > 1)
                  _PageIndicator(
                    index: index,
                    count: items.length,
                    onSelect: _goTo,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _report(EmbyItem item) {
    final callback = widget.onItem;
    if (callback == null || _reportedId == item.id) return;
    _reportedId = item.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedId == item.id) callback(item);
    });
  }
}

class _HeroCaption extends StatelessWidget {
  const _HeroCaption({required this.item, required this.onOpen});
  final EmbyItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final title = item.isEpisode && item.seriesName?.isNotEmpty == true
        ? item.seriesName!
        : item.name;
    final meta = [
      if (item.isEpisode) ?seasonEpisodeCode(item),
      if (item.canResume)
        l10n.playbackProgress((item.playbackProgress * 100).round()),
      if (!item.isEpisode && item.productionYear != null)
        '${item.productionYear}',
      if (item.communityRating != null)
        item.communityRating!.toStringAsFixed(1),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              meta.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          HeroPlaybackActions(
            item: item,
            onDetails: onOpen,
            onResume: () async {
              await context.push<void>(
                '/play/${item.id}',
                extra: PlayerOpenRequest(itemId: item.id, autoResume: true),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({
    required this.index,
    required this.count,
    required this.onSelect,
  });
  final int index;
  final int count;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              selected: i == index,
              label: '${i + 1} / $count',
              child: InkResponse(
                key: CatalogKeys.heroDot(i),
                onTap: () => onSelect(i),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: AppMotion.durationOf(context, AppMotion.fast),
                      width: i == index ? 18 : 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: i == index
                            ? scheme.secondary
                            : scheme.onSurface.withValues(alpha: .25),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
