import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/library/shelf_sort.dart';

/// A staged filter editor. Categories and actions stay visible while options
/// scroll; the host commits exactly once on Apply and cancellation is harmless.
class LibraryFilterPanel extends StatefulWidget {
  const LibraryFilterPanel({
    super.key,
    required this.initial,
    required this.onApply,
    this.years = const [],
    this.genres = const [],
    this.sort,
    this.typeFilterable = true,
    this.television = false,
    this.keyPrefix = 'catalog-grid-filter',
    this.loadGenres,
  });
  final ShelfFilters initial;
  final List<int> years;
  final List<String> genres;
  final CatalogSort? sort;
  final bool typeFilterable, television;
  final String keyPrefix;
  final void Function(ShelfFilters, CatalogSort?) onApply;
  final Future<List<String>> Function()? loadGenres;
  @override
  State<LibraryFilterPanel> createState() => _LibraryFilterPanelState();
}

class _LibraryFilterPanelState extends State<LibraryFilterPanel> {
  late ShelfFilters _draft = widget.initial;
  late CatalogSort? _sort = widget.sort;
  late String _section = widget.typeFilterable ? 'type' : 'watch';
  final _search = TextEditingController();
  late final Set<String> _genres = {...widget.genres, ...widget.initial.genres};
  bool _loadingGenres = false, _genreFailed = false;
  int get _count =>
      (_draft.type == CatalogTypeFilter.all ? 0 : 1) +
      (_draft.watch == CatalogWatchFilter.all ? 0 : 1) +
      _draft.years.length +
      _draft.genres.length;

  @override
  void initState() {
    super.initState();
    _loadGenres();
  }

  Future<void> _loadGenres() async {
    if (widget.loadGenres == null || _loadingGenres) return;
    setState(() {
      _loadingGenres = true;
      _genreFailed = false;
    });
    try {
      final result = await widget.loadGenres!();
      if (mounted) setState(() => _genres.addAll(result));
    } catch (_) {
      if (mounted) setState(() => _genreFailed = true);
    } finally {
      if (mounted) setState(() => _loadingGenres = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<(String, String, IconData)> _sections(AppLocalizations l) => [
    if (widget.typeFilterable)
      ('type', l.libraryFilterType, Icons.video_library_outlined),
    ('watch', l.libraryFilterWatch, Icons.visibility_outlined),
    ('genre', l.libraryFilterGenre, Icons.category_outlined),
    ('year', l.libraryFilterYear, Icons.calendar_month_outlined),
    if (_sort != null) ('sort', l.mobileSort, Icons.sort_rounded),
  ];
  void _chooseSection(String section) {
    setState(() {
      _section = section;
      _search.clear();
    });
  }

  Key _key(String suffix) => Key('${widget.keyPrefix}-$suffix');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final wide = widget.television || size.width >= 700;
    final sections = _sections(l);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final compactSection = _section == 'type' || _section == 'watch';
    final naturalHeight = wide
        ? (widget.television ? 760.0 : 680.0)
        : (compactSection ? 440.0 : 620.0) * textScale;
    final height = math.min(
      naturalHeight,
      (size.height - MediaQuery.viewInsetsOf(context).bottom) * .88,
    );

    return SizedBox(
      width: widget.television ? 980 : 760,
      height: height,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.filterBrowseTitle,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.filterSelectedCount(_count),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.television)
                    IconButton(
                      key: _key('cancel'),
                      tooltip: l.libraryFilterCancel,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            if (_count > 0)
              SizedBox(
                height: 44 * textScale,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    if (_draft.type != CatalogTypeFilter.all)
                      _summary(
                        _draft.type.label,
                        () => _draft = _draft.copyWith(
                          type: CatalogTypeFilter.all,
                        ),
                      ),
                    if (_draft.watch != CatalogWatchFilter.all)
                      _summary(
                        _watchLabel(l, _draft.watch),
                        () => _draft = _draft.copyWith(
                          watch: CatalogWatchFilter.all,
                        ),
                      ),
                    for (final year in _draft.years)
                      _summary(
                        '$year',
                        () => _draft = _draft.copyWith(
                          years: [..._draft.years]..remove(year),
                        ),
                      ),
                    for (final genre in _draft.genres)
                      _summary(
                        genre,
                        () => _draft = _draft.copyWith(
                          genres: [..._draft.genres]..remove(genre),
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: widget.television ? 230 : 180,
                          child: ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              for (final section in sections)
                                _category(section, wide: true),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _options(context)),
                      ],
                    )
                  : Column(
                      children: [
                        SizedBox(
                          height: math.max(60, 44 * textScale + 12),
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            children: [
                              for (final section in sections)
                                _category(section, wide: false),
                            ],
                          ),
                        ),
                        Expanded(child: _options(context)),
                      ],
                    ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    if (widget.television) ...[
                      Expanded(
                        child: TvAction(
                          key: _key('clear'),
                          onPressed: _reset,
                          child: Text(l.filterReset),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TvAction(
                          key: _key('cancel'),
                          onPressed: () => Navigator.pop(context),
                          child: Text(l.libraryFilterCancel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TvAction(
                          key: _key('apply'),
                          emphasized: true,
                          onPressed: _apply,
                          child: Text(l.filterApply),
                        ),
                      ),
                    ] else ...[
                      TextButton(
                        key: _key('clear'),
                        onPressed: _reset,
                        child: Text(l.filterReset),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton.icon(
                          key: _key('apply'),
                          onPressed: _apply,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.check_rounded),
                          label: Text(l.filterApply),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _reset() => setState(() {
    _draft = const ShelfFilters();
    if (_sort != null) _sort = CatalogSort.initial;
    _search.clear();
  });
  void _apply() {
    widget.onApply(_draft, _sort);
    Navigator.pop(context);
  }

  Widget _summary(String label, VoidCallback change) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InputChip(label: Text(label), onDeleted: () => setState(change)),
  );

  Widget _category((String, String, IconData) entry, {required bool wide}) {
    final selected = _section == entry.$1;
    final scheme = Theme.of(context).colorScheme;
    if (widget.television) {
      return TvAction(
        key: _key('section-${entry.$1}'),
        autofocus: selected,
        selected: selected,
        onPressed: () => _chooseSection(entry.$1),
        child: Row(
          children: [
            Icon(entry.$3, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(entry.$2)),
          ],
        ),
      );
    }
    final style = TextButton.styleFrom(
      alignment: wide ? Alignment.centerLeft : Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 10),
      minimumSize: const Size(48, 48),
      backgroundColor: selected ? scheme.primaryContainer : Colors.transparent,
      foregroundColor: selected
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    return Semantics(
      selected: selected,
      child: Padding(
        padding: EdgeInsets.only(right: wide ? 0 : 4, bottom: wide ? 8 : 0),
        child: wide
            ? TextButton.icon(
                key: _key('section-${entry.$1}'),
                onPressed: () => _chooseSection(entry.$1),
                style: style,
                icon: Icon(entry.$3, size: 20),
                label: Text(entry.$2),
              )
            : TextButton(
                key: _key('section-${entry.$1}'),
                onPressed: () => _chooseSection(entry.$1),
                style: style,
                child: Text(entry.$2),
              ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final label = _sections(l).firstWhere((s) => s.$1 == _section).$2;
    final searchable = _section == 'year' || _section == 'genre';
    final query = _search.text.trim().toLowerCase();
    final options = <(String, String, bool, VoidCallback)>[];
    void option(
      String value,
      String label,
      bool selected,
      VoidCallback change,
    ) {
      if (value == 'all' ||
          query.isEmpty ||
          label.toLowerCase().contains(query)) {
        options.add((value, label, selected, change));
      }
    }

    switch (_section) {
      case 'type':
        for (final value in CatalogTypeFilter.values) {
          option(
            value.itemType ?? 'all',
            value.label,
            _draft.type == value,
            () => _draft = _draft.copyWith(type: value),
          );
        }
      case 'watch':
        for (final value in CatalogWatchFilter.values) {
          option(
            value.param ?? 'all',
            _watchLabel(l, value),
            _draft.watch == value,
            () => _draft = _draft.copyWith(watch: value),
          );
        }
      case 'year':
        option(
          'all',
          l.libraryFilterAll,
          _draft.years.isEmpty,
          () => _draft = _draft.copyWith(years: []),
        );
        final years = {
          ...widget.years,
          ..._draft.years,
          for (var y = DateTime.now().year; y >= 1900; y--) y,
        }.toList()..sort((a, b) => b.compareTo(a));
        for (final year in years) {
          option('$year', '$year', _draft.years.contains(year), () {
            final values = [..._draft.years];
            values.contains(year) ? values.remove(year) : values.add(year);
            _draft = _draft.copyWith(years: values);
          });
        }
      case 'genre':
        option(
          'all',
          l.libraryFilterAll,
          _draft.genres.isEmpty,
          () => _draft = _draft.copyWith(genres: []),
        );
        final genres = _genres.toList()..sort();
        for (final genre in genres) {
          option(genre, genre, _draft.genres.contains(genre), () {
            final values = [..._draft.genres];
            values.contains(genre) ? values.remove(genre) : values.add(genre);
            _draft = _draft.copyWith(genres: values);
          });
        }
      case 'sort':
        for (final sort in CatalogSort.optionsFor(const [])) {
          option(sort.sortBy, sort.label(l), _sort == sort, () => _sort = sort);
        }
    }
    return Padding(
      padding: EdgeInsets.all(widget.television ? 24 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          if (searchable) ...[
            const SizedBox(height: 8),
            if (widget.television)
              TvInput(
                label: l.filterSearchOptions,
                controller: _search,
                onSubmitted: () => setState(() {}),
              )
            else
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: l.filterSearchOptions,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l.filterReset,
                          onPressed: () => setState(_search.clear),
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              l.filterChooseHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_section == 'genre' && _loadingGenres)
            const LinearProgressIndicator(),
          if (_section == 'genre' && _genreFailed)
            TextButton.icon(
              onPressed: _loadGenres,
              icon: const Icon(Icons.refresh),
              label: Text(l.retry),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              key: _key('$_section-section'),
              child: Wrap(
                spacing: widget.television ? 12 : 8,
                runSpacing: widget.television ? 12 : 8,
                children: [
                  for (final option in options)
                    if (widget.television)
                      SizedBox(
                        width: _section == 'year' ? 120 : 270,
                        child: TvAction(
                          key: _key('$_section-${option.$1}'),
                          selected: option.$3,
                          onPressed: () => setState(option.$4),
                          child: Row(
                            children: [
                              Expanded(child: Text(option.$2)),
                              if (option.$3) const Icon(Icons.check, size: 20),
                            ],
                          ),
                        ),
                      )
                    else
                      FilterChip(
                        key: _key('$_section-${option.$1}'),
                        label: Text(option.$2),
                        selected: option.$3,
                        selectedColor: theme.colorScheme.primaryContainer,
                        checkmarkColor: theme.colorScheme.onPrimaryContainer,
                        showCheckmark: true,
                        onSelected: (_) => setState(option.$4),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                  if (options.isEmpty ||
                      (_section == 'genre' &&
                          options.length == 1 &&
                          !_loadingGenres))
                    Text(l.filterNoOptions),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _watchLabel(AppLocalizations l, CatalogWatchFilter value) =>
      switch (value) {
        CatalogWatchFilter.all => l.libraryFilterAll,
        CatalogWatchFilter.played => l.mobileWatched,
        CatalogWatchFilter.unplayed => l.mobileUnwatched,
        CatalogWatchFilter.resumable => l.filterResumable,
        CatalogWatchFilter.favorite => l.filterFavorite,
      };
}
