import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_image/media_image.dart';

const _phoneSorts = <CatalogSort>[
  CatalogSort.dateCreated,
  CatalogSort.name,
  CatalogSort.communityRating,
  CatalogSort.premiereDate,
];

String _sortLabel(AppLocalizations l10n, String sortBy) {
  if (sortBy == CatalogSort.dateCreated.sortBy) {
    return l10n.mobileDateSort;
  }
  if (sortBy == CatalogSort.name.sortBy) {
    return l10n.mobileNameSort;
  }
  for (final sort in _phoneSorts) {
    if (sort.sortBy == sortBy) {
      return sort.label(l10n);
    }
  }
  return l10n.mobileNameSort;
}

bool _hasCriteria(BrowseController controller) {
  return controller.type != null ||
      controller.watch != null ||
      controller.year != null ||
      controller.genre != null ||
      controller.sortBy != CatalogSort.name.sortBy;
}

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({super.key, required this.viewId});

  final String viewId;

  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  static const double _loadMoreThreshold = 480;

  final ScrollController _scroll = ScrollController();
  bool _nearEndLoadArmed = true;
  final Set<int> _years = {};
  final Set<String> _genres = {};
  BrowseController? _controller;
  AuthController? _auth;
  CatalogCache? _cache;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = AuthScope.of(context);
    _cache = CatalogScope.of(context).cache;
    if (_controller != null) {
      return;
    }
    _controller = _newController()..load();
  }

  @override
  void didUpdateWidget(MobileLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewId == widget.viewId) {
      return;
    }
    _controller?.removeListener(_rememberDimensions);
    _controller?.dispose();
    _years.clear();
    _genres.clear();
    _controller = _newController()..load();
  }

  BrowseController _newController() {
    return BrowseController(
      auth: _auth!,
      cache: _cache!,
      parentId: widget.viewId,
    )..addListener(_rememberDimensions);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _controller?.removeListener(_rememberDimensions);
    _controller?.dispose();
    super.dispose();
  }

  void _rememberDimensions() {
    final items = _controller?.items;
    if (items == null) {
      return;
    }
    for (final item in items) {
      final year = item.productionYear;
      if (year != null) {
        _years.add(year);
      }
      for (final genre in item.genres) {
        final name = genre.trim();
        if (name.isNotEmpty) {
          _genres.add(name);
        }
      }
    }
  }

  void _maybeLoadMore() {
    final controller = _controller;
    if (controller == null || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (!position.hasContentDimensions) {
      return;
    }
    final nearEnd =
        position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - _loadMoreThreshold;
    if (!nearEnd) {
      _nearEndLoadArmed = true;
      return;
    }
    if (controller.loading || !controller.hasMore || controller.error != null) {
      return;
    }
    if (!_nearEndLoadArmed) {
      return;
    }
    _nearEndLoadArmed = false;
    controller.load(more: true);
  }

  void _clearFilters() {
    _controller?.filter(sortBy: CatalogSort.name.sortBy);
  }

  Future<void> _openFilters() async {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }
    final years = [..._years]..sort((a, b) => b.compareTo(a));
    final genres = [..._genres]..sort();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _FilterSheet(
        type: controller.type,
        watch: controller.watch,
        year: controller.year,
        genre: controller.genre,
        sortBy: controller.sortBy,
        years: years,
        genres: genres,
        onApply:
            ({
              required String? type,
              required String? watch,
              required int? year,
              required String? genre,
              required String sortBy,
            }) {
              controller.filter(
                type: type,
                watch: watch,
                year: year,
                genre: genre,
                sortBy: sortBy,
              );
            },
        onClear: _clearFilters,
      ),
    );
  }

  String _libraryTitle(AppLocalizations l10n) {
    for (final library in CatalogScope.of(context).libraries) {
      if (library.id != widget.viewId) {
        continue;
      }
      final name = library.name.trim();
      if (name.isNotEmpty) {
        return name;
      }
    }
    return l10n.libraries;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _controller!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_libraryTitle(l10n), key: const Key('phone-library-title')),
        actions: [
          IconButton(
            key: const Key('phone-library-filter'),
            tooltip: l10n.libraryFilter,
            onPressed: _openFilters,
            icon: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => RefreshIndicator(
            onRefresh: controller.load,
            child: CustomScrollView(
              controller: _scroll,
              key: PageStorageKey('library-${widget.viewId}'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (controller.loading && controller.items.isEmpty)
                  const SliverPadding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    sliver: SliverToBoxAdapter(child: _LibrarySkeleton()),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _ActiveFilters(
                            controller: controller,
                            onClear: _clearFilters,
                          ),
                        ),
                        if (controller.loading)
                          const SliverToBoxAdapter(
                            child: LinearProgressIndicator(),
                          ),
                        if (controller.error != null)
                          SliverToBoxAdapter(
                            child: MobileFailureState(
                              message: catalogFailureMessage(
                                l10n,
                                controller.error!,
                              ),
                              onRetry: () => controller.load(
                                more:
                                    controller.items.isNotEmpty &&
                                    controller.hasMore,
                              ),
                            ),
                          ),
                        if (!controller.loading &&
                            controller.error == null &&
                            controller.items.isEmpty)
                          SliverToBoxAdapter(
                            child: MobileEmptyState(
                              message: l10n.mobileEmpty,
                              actionLabel: _hasCriteria(controller)
                                  ? l10n.libraryFilterClear
                                  : l10n.mobileRefresh,
                              onAction: _hasCriteria(controller)
                                  ? _clearFilters
                                  : () => controller.load(),
                            ),
                          ),
                        if (controller.items.isNotEmpty)
                          _PhonePosterSliver(items: controller.items),
                        if (controller.hasMore && controller.error == null)
                          SliverToBoxAdapter(
                            child: Align(
                              alignment: Alignment.center,
                              child: FilledButton(
                                key: const Key('phone-library-more'),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                onPressed: controller.loading
                                    ? null
                                    : () => controller.load(more: true),
                                child: Text(l10n.mobileLoadMore),
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
    );
  }
}

class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.controller, required this.onClear});

  final BrowseController controller;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            key: const Key('phone-library-active-sort'),
            label: Text(_sortLabel(l10n, controller.sortBy)),
            visualDensity: VisualDensity.compact,
          ),
          if (controller.type == 'Movie')
            Chip(
              key: const Key('phone-library-active-type'),
              label: Text(l10n.mobileMovies),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.type == 'Series')
            Chip(
              key: const Key('phone-library-active-type'),
              label: Text(l10n.mobileSeries),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.watch == 'IsPlayed')
            Chip(
              key: const Key('phone-library-active-watch'),
              label: Text(l10n.mobileWatched),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.watch == 'IsUnplayed')
            Chip(
              key: const Key('phone-library-active-watch'),
              label: Text(l10n.mobileUnwatched),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.year != null)
            Chip(
              key: const Key('phone-library-active-year'),
              label: Text('${controller.year}'),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.genre != null)
            Chip(
              key: const Key('phone-library-active-genre'),
              label: Text(controller.genre!),
              visualDensity: VisualDensity.compact,
            ),
          if (_hasCriteria(controller) && controller.items.isNotEmpty)
            TextButton(
              key: const Key('phone-library-reset'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onClear,
              child: Text(l10n.libraryFilterClear),
            ),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.type,
    required this.watch,
    required this.year,
    required this.genre,
    required this.sortBy,
    required this.years,
    required this.genres,
    required this.onApply,
    required this.onClear,
  });

  final String? type;
  final String? watch;
  final int? year;
  final String? genre;
  final String sortBy;
  final List<int> years;
  final List<String> genres;
  final void Function({
    required String? type,
    required String? watch,
    required int? year,
    required String? genre,
    required String sortBy,
  })
  onApply;
  final VoidCallback onClear;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _type = widget.type;
  late String? _watch = widget.watch;
  late int? _year = widget.year;
  late String? _genre = widget.genre;
  late String _sortBy = widget.sortBy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg + bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.libraryFilter,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.md),
            _dimension(
              label: l10n.libraryFilterType,
              children: [
                _choice(
                  key: const Key('phone-library-type-all'),
                  label: l10n.libraryFilterAll,
                  selected: _type == null,
                  onSelected: () => setState(() => _type = null),
                ),
                _choice(
                  key: const Key('phone-library-type-Movie'),
                  label: l10n.mobileMovies,
                  selected: _type == 'Movie',
                  onSelected: () => setState(() => _type = 'Movie'),
                ),
                _choice(
                  key: const Key('phone-library-type-Series'),
                  label: l10n.mobileSeries,
                  selected: _type == 'Series',
                  onSelected: () => setState(() => _type = 'Series'),
                ),
              ],
            ),
            _dimension(
              label: l10n.libraryFilterWatch,
              children: [
                _choice(
                  key: const Key('phone-library-watch-all'),
                  label: l10n.libraryFilterAll,
                  selected: _watch == null,
                  onSelected: () => setState(() => _watch = null),
                ),
                _choice(
                  key: const Key('phone-library-watch-IsPlayed'),
                  label: l10n.mobileWatched,
                  selected: _watch == 'IsPlayed',
                  onSelected: () => setState(() => _watch = 'IsPlayed'),
                ),
                _choice(
                  key: const Key('phone-library-watch-IsUnplayed'),
                  label: l10n.mobileUnwatched,
                  selected: _watch == 'IsUnplayed',
                  onSelected: () => setState(() => _watch = 'IsUnplayed'),
                ),
              ],
            ),
            if (widget.years.isNotEmpty)
              _dimension(
                key: const Key('phone-library-year-section'),
                label: l10n.libraryFilterYear,
                children: [
                  _choice(
                    key: const Key('phone-library-year-all'),
                    label: l10n.libraryFilterAll,
                    selected: _year == null,
                    onSelected: () => setState(() => _year = null),
                  ),
                  for (final year in widget.years)
                    _choice(
                      key: Key('phone-library-year-$year'),
                      label: '$year',
                      selected: _year == year,
                      onSelected: () => setState(() => _year = year),
                    ),
                ],
              ),
            if (widget.genres.isNotEmpty)
              _dimension(
                key: const Key('phone-library-genre-section'),
                label: l10n.libraryFilterGenre,
                children: [
                  _choice(
                    key: const Key('phone-library-genre-all'),
                    label: l10n.libraryFilterAll,
                    selected: _genre == null,
                    onSelected: () => setState(() => _genre = null),
                  ),
                  for (final genre in widget.genres)
                    _choice(
                      key: Key('phone-library-genre-$genre'),
                      label: genre,
                      selected: _genre == genre,
                      onSelected: () => setState(() => _genre = genre),
                    ),
                ],
              ),
            _dimension(
              label: l10n.mobileSort,
              children: [
                for (final sort in _phoneSorts)
                  _choice(
                    key: Key('phone-library-sort-${sort.sortBy}'),
                    label: _sortLabel(l10n, sort.sortBy),
                    selected: _sortBy == sort.sortBy,
                    onSelected: () => setState(() => _sortBy = sort.sortBy),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              key: const Key('phone-library-apply'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                widget.onApply(
                  type: _type,
                  watch: _watch,
                  year: _year,
                  genre: _genre,
                  sortBy: _sortBy,
                );
                Navigator.pop(context);
              },
              child: Text(l10n.libraryFilter),
            ),
            TextButton(
              key: const Key('phone-library-clear'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                widget.onClear();
                Navigator.pop(context);
              },
              child: Text(l10n.libraryFilterClear),
            ),
            TextButton(
              key: const Key('phone-library-cancel'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.libraryFilterCancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dimension({
    Key? key,
    required String label,
    required List<Widget> children,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: children,
          ),
        ],
      ),
    );
  }

  Widget _choice({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / 2;
        return Wrap(
          children: [
            for (var i = 0; i < 4; i++)
              SkeletonBlock(width: width, height: width * 1.5, animated: false),
          ],
        );
      },
    );
  }
}

class _PhonePosterSliver extends StatelessWidget {
  const _PhonePosterSliver({required this.items});

  final List<EmbyItem> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.md;
        final columns = mobileGridColumnCount(constraints.crossAxisExtent);
        final cellWidth =
            (constraints.crossAxisExtent - spacing * (columns - 1)) / columns;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: cellWidth / (cellWidth * 1.5 + 52 * textScale),
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final item = items[index];
            return _PhonePoster(
              key: ValueKey('phone-library-poster-${item.id}'),
              item: item,
              progressLabel: item.canResume
                  ? l10n.playbackProgress((item.playbackProgress * 100).round())
                  : null,
            );
          }, childCount: items.length),
        );
      },
    );
  }
}

class _PhonePoster extends StatelessWidget {
  const _PhonePoster({
    super.key,
    required this.item,
    required this.progressLabel,
  });

  final EmbyItem item;
  final String? progressLabel;

  bool get _hasImage {
    bool tagged(String? tag) => tag != null && tag.isNotEmpty;
    return tagged(item.primaryImageTag) ||
        tagged(item.thumbImageTag) ||
        tagged(item.backdropImageTag);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MobilePressable(
      onTap: () => context.push(AppRoutes.item(item.id)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final artHeight = constraints.maxWidth * 1.5;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: ValueKey('phone-library-art-${item.id}'),
                height: artHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    boxShadow: const [
                      BoxShadow(
                        color: Color.fromRGBO(
                          0,
                          0,
                          0,
                          AppMobileCard.shadowAlpha,
                        ),
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
                        if (_hasImage)
                          MediaImage(item: item, maxWidth: 400)
                        else
                          ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.xs),
                                child: Text(
                                  item.name,
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        if (progressLabel != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Semantics(
                              label: progressLabel,
                              child: LinearProgressIndicator(
                                key: ValueKey(
                                  'phone-library-progress-${item.id}',
                                ),
                                value: item.playbackProgress,
                                minHeight: 4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          );
        },
      ),
    );
  }
}
