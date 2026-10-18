import 'dart:math' as math;

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_server/capabilities.dart';

/// 一页式多维平铺标签筛选与排序面板（R3、R4、R5）。
///
/// 手机端（底部圆角抽屉）、桌面端（居中模态框）、Android TV 端（大屏平铺模态框）
/// 共用同一纵向分组平铺结构（排序、类型、观看状态、流派、年份），草稿态修改在点击
/// 「应用筛选」时一次性提交；点击取消或返回键丢弃未提交修改。
class LibraryFilterPanel extends StatefulWidget {
  const LibraryFilterPanel({
    super.key,
    required this.initial,
    required this.onApply,
    this.years = const [],
    this.genres = const [],
    this.sort,
    this.sortOrder,
    this.onApplyWithOrder,
    this.capabilities = const ServiceCapabilities({}),
    this.typeFilterable = true,
    this.television = false,
    this.keyPrefix = 'catalog-grid-filter',
    this.loadGenres,
  });

  final ShelfFilters initial;
  final List<int> years;
  final List<String> genres;
  final CatalogSort? sort;
  final String? sortOrder;
  final ServiceCapabilities capabilities;
  final bool typeFilterable, television;
  final String keyPrefix;
  final void Function(ShelfFilters, CatalogSort?) onApply;
  final void Function(ShelfFilters, CatalogSort?, String?)? onApplyWithOrder;
  final Future<List<String>> Function()? loadGenres;

  @override
  State<LibraryFilterPanel> createState() => _LibraryFilterPanelState();
}

class _LibraryFilterPanelState extends State<LibraryFilterPanel> {
  static const int _recentYearWindow = 15;
  static const int _genreSearchThreshold = 16;

  late ShelfFilters _draft = widget.initial;
  late CatalogSort? _sort = widget.sort;
  late String _sortOrder = CatalogSort.normalizeSortOrder(
    widget.sortOrder,
    fallback: widget.sort ?? CatalogSort.initialFor(widget.capabilities),
  );
  late String _activeSection = widget.typeFilterable ? 'type' : 'watch';
  bool _allYearsExpanded = false;
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _sectionAnchorKeys = {
    'sort': GlobalKey(),
    'type': GlobalKey(),
    'watch': GlobalKey(),
    'genre': GlobalKey(),
    'year': GlobalKey(),
  };

  late final Set<String> _genres = {...widget.genres, ...widget.initial.genres};
  bool _loadingGenres = false, _genreFailed = false;

  int get _count => _draft.activeCount;

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
    _scrollController.dispose();
    super.dispose();
  }

  Key _key(String suffix) => Key('${widget.keyPrefix}-$suffix');

  bool _phoneSheet(BuildContext context) =>
      !widget.television && PresentationScope.isPhoneOf(context);

  void _chooseSection(String section) {
    setState(() {
      _activeSection = section;
    });
    final anchorContext = _sectionAnchorKeys[section]?.currentContext;
    if (anchorContext != null && anchorContext.mounted) {
      Scrollable.ensureVisible(
        anchorContext,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
      );
    }
  }

  void _reset() => setState(() {
    _draft = const ShelfFilters();
    if (_sort != null) {
      final def = CatalogSort.initialFor(widget.capabilities);
      _sort = def;
      _sortOrder = def.sortOrder;
    }
    _search.clear();
  });

  void _apply() {
    if (widget.onApplyWithOrder != null) {
      widget.onApplyWithOrder!(
        _draft,
        _sort,
        _sort == null ? null : _sortOrder,
      );
    } else {
      widget.onApply(_draft, _sort);
    }
    Navigator.pop(context);
  }

  void _selectSort(CatalogSort target) {
    setState(() {
      if (_sort == target && target.supportsOrderToggle) {
        _sortOrder = CatalogSort.flipSortOrder(_sortOrder);
      } else {
        _sort = target;
        _sortOrder = target.sortOrder;
      }
    });
  }

  void _toggleSortOrder() {
    final current = _sort;
    if (current == null || !current.supportsOrderToggle) return;
    setState(() {
      _sortOrder = CatalogSort.flipSortOrder(_sortOrder);
    });
  }

  List<int> _visibleYears() {
    final currentYear = DateTime.now().year;
    final recentCutoff = currentYear - (_recentYearWindow - 1);
    if (_allYearsExpanded) {
      final all = <int>{
        ...widget.years,
        ..._draft.years,
        for (var y = currentYear; y >= 1900; y--) y,
      }.toList()..sort((a, b) => b.compareTo(a));
      return all;
    }
    final defaultSet = <int>{
      ...widget.years,
      ..._draft.years,
      for (var y = currentYear; y >= recentCutoff; y--) y,
    }.toList()..sort((a, b) => b.compareTo(a));
    return defaultSet;
  }

  bool get _showSearchField => _genres.length > _genreSearchThreshold;

  String _applyButtonLabel(AppLocalizations l) =>
      _count > 0 ? '${l.filterApply} ($_count)' : l.filterApply;

  @override
  Widget build(BuildContext context) {
    if (_phoneSheet(context)) return _buildPhone(context);
    final l = AppLocalizations.of(context), theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final wide = widget.television || size.width >= 700;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final compactSection =
        _activeSection == 'type' || _activeSection == 'watch';
    final panelScale = widget.television || wide
        ? AppViewport.scaleOf(size)
        : 1.0;
    final naturalHeight = widget.television
        ? 760.0 * panelScale
        : wide
        ? (compactSection ? 420.0 : 520.0) * panelScale
        : (compactSection ? 440.0 : 620.0) * textScale;
    final height = math.min(
      naturalHeight,
      (size.height - MediaQuery.viewInsetsOf(context).bottom) * .88,
    );
    final width = widget.television
        ? math.min(980.0 * panelScale, size.width - 48)
        : wide
        ? math.min(600.0 * panelScale, size.width - 48)
        : size.width;

    return AnimatedSize(
      duration: AppMotion.durationOf(context),
      curve: AppMotion.standard,
      alignment: Alignment.center,
      child: SizedBox(
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(24),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.filter,
                      fill: AppIcons.filled,
                      color: scheme.onSurface,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.filterBrowseTitle,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 2),
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
                      AppIconButton(
                        key: _key('cancel'),
                        tooltip: l.libraryFilterCancel,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                      ),
                  ],
                ),
              ),
              _buildQuickAnchorRail(context, l, phone: false),
              if (_count > 0)
                SizedBox(
                  height: 40 * textScale,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: _buildSummaryPills(l),
                  ),
                ),
              const AppDivider(height: 1),
              Expanded(child: _buildFlatBody(context, phone: false)),
              if (!widget.television) ...[
                _footerHairline(context),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                    child: Row(
                      children: [
                        AppButton(
                          key: _key('clear'),
                          onPressed: _reset,
                          variant: AppButtonVariant.plain,
                          child: Text(l.filterReset),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: AppButton.icon(
                            key: _key('apply'),
                            onPressed: _apply,
                            style: const AppButtonStyle(
                              minimumSize: Size(48, 48),
                            ),
                            icon: const Icon(CupertinoIcons.check_mark),
                            label: Text(_applyButtonLabel(l)),
                            variant: AppButtonVariant.filled,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhone(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final compactSection =
        _activeSection == 'type' || _activeSection == 'watch';
    final naturalHeight = (compactSection ? 560.0 : 660.0) * textScale;
    final height = math.min(
      naturalHeight,
      (size.height - MediaQuery.viewInsetsOf(context).bottom) * .9,
    );
    return AnimatedSize(
      duration: AppMotion.durationOf(context),
      curve: AppMotion.standard,
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: _key('phone-sheet'),
        width: size.width,
        height: height,
        child: ColoredBox(
          color: scheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const SizedBox(width: 36, height: 4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.filterBrowseTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l.filterSelectedCount(_count),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppIconButton(
                      key: _key('cancel'),
                      tooltip: l.libraryFilterCancel,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                    ),
                  ],
                ),
              ),
              _buildQuickAnchorRail(context, l, phone: true),
              if (_count > 0)
                SizedBox(
                  height: math.max(48, 40 * textScale),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: _buildSummaryPills(l),
                  ),
                ),
              const AppDivider(height: 1),
              Expanded(child: _buildFlatBody(context, phone: true)),
              _footerHairline(context),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      AppButton(
                        key: _key('clear'),
                        onPressed: _reset,
                        variant: AppButtonVariant.plain,
                        child: Text(l.filterReset),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppButton(
                          key: _key('apply'),
                          onPressed: _apply,
                          style: const AppButtonStyle(
                            minimumSize: Size(48, 48),
                          ),
                          variant: AppButtonVariant.filled,
                          child: Text(_applyButtonLabel(l)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickAnchorRail(
    BuildContext context,
    AppLocalizations l, {
    required bool phone,
  }) {
    final sections = <(String, String)>[
      if (_sort != null) ('sort', l.mobileSort),
      if (widget.typeFilterable) ('type', l.libraryFilterType),
      ('watch', l.libraryFilterWatch),
      ('year', l.libraryFilterYear),
      ('genre', l.libraryFilterGenre),
    ];
    final horizontalPad = widget.television ? 24.0 : (phone ? 16.0 : 20.0);
    final padding = EdgeInsets.fromLTRB(horizontalPad, 2, horizontalPad, 6);
    if (widget.television) {
      return Padding(
        padding: padding,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (id, label) in sections)
              TvAction(
                key: _key('section-$id'),
                pill: true,
                selected: _activeSection == id,
                onPressed: () => _chooseSection(id),
                child: Text(label),
              ),
          ],
        ),
      );
    }
    // 分段控件：安静的轨道 + 选中段实底强调色，全页只保留一个实心主操作。
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: ShapeDecoration(
              color: AppUiTheme.of(context).colorScheme.surfaceContainerHigh,
              shape: StadiumBorder(
                side: BorderSide(
                  color: AppEdge.of(AppUiTheme.of(context).brightness),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (id, label) in sections)
                  _buildSectionSegment(
                    context,
                    id: id,
                    label: label,
                    selected: _activeSection == id,
                    phone: phone,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionSegment(
    BuildContext context, {
    required String id,
    required String label,
    required bool selected,
    required bool phone,
  }) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: AppSurfaceAction(
        key: _key('section-$id'),
        onTap: () => _chooseSection(id),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          curve: AppMotion.standard,
          constraints: BoxConstraints(
            minWidth: 64,
            // 手机端保持原有 48 的触达区。
            minHeight: phone ? 48 : AppControlHeight.md,
          ),
          decoration: ShapeDecoration(
            color: selected ? scheme.primary : const Color(0x00000000),
            shape: const StadiumBorder(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSummaryPills(AppLocalizations l) {
    return [
      if (_draft.type != CatalogTypeFilter.all)
        _summary(
          _draft.type.label,
          () => _draft = _draft.copyWith(type: CatalogTypeFilter.all),
        ),
      if (_draft.watch != CatalogWatchFilter.all)
        _summary(
          _watchLabel(l, _draft.watch),
          () => _draft = _draft.copyWith(watch: CatalogWatchFilter.all),
        ),
      for (final year in _draft.years)
        _summary(
          '$year',
          () =>
              _draft = _draft.copyWith(years: [..._draft.years]..remove(year)),
        ),
      for (final genre in _draft.genres)
        _summary(
          genre,
          () => _draft = _draft.copyWith(
            genres: [..._draft.genres]..remove(genre),
          ),
        ),
    ];
  }

  Widget _summary(String label, VoidCallback change) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: RemovablePill(label: label, onDeleted: () => setState(change)),
  );

  /// 页脚与内容之间的发丝分隔线。
  Widget _footerHairline(BuildContext context) => ColoredBox(
    color: AppEdge.of(AppUiTheme.of(context).brightness),
    child: const SizedBox(height: 1, width: double.infinity),
  );

  Widget _buildFlatBody(BuildContext context, {required bool phone}) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final query = _search.text.trim().toLowerCase();
    final tv = widget.television;
    final horizontalPad = tv ? 24.0 : (phone ? 16.0 : 20.0);
    final body = SingleChildScrollView(
      controller: _scrollController,
      // 底部留白让最后一行滚到渐隐区之上仍可完整看到。
      padding: EdgeInsets.fromLTRB(
        horizontalPad,
        12,
        horizontalPad,
        tv ? 20 : 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sort != null) ...[
            _buildSortSection(context, l),
            const SizedBox(height: 20),
          ],
          if (widget.typeFilterable) ...[
            _buildTypeSection(context, l),
            const SizedBox(height: 20),
          ],
          _buildWatchSection(context, l),
          const SizedBox(height: 20),
          _buildGenreSection(context, l, query),
          const SizedBox(height: 20),
          _buildYearSection(context, l, query),
          if (tv) ...[
            const SizedBox(height: 20),
            Row(
              children: [
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
                    child: Text(_applyButtonLabel(l)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
    if (tv) return body;
    // 底部渐隐提示内容还能继续滚动，不挡点击。
    final fadeColor = phone
        ? theme.colorScheme.surface
        : theme.colorScheme.surfaceContainerLow;
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 24,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [fadeColor.withValues(alpha: 0), fadeColor],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String section,
    required String title,
    required IconData icon,
    Widget? trailing,
  }) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final anchorKey = _sectionAnchorKeys[section];
    return Container(
      key: anchorKey,
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            // 只有右侧有内容时才显示分隔点，避免悬空的「排序 ·」。
            trailing == null ? title : '$title ·',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildOptionItem({
    required String section,
    required String value,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) {
    if (widget.television) {
      return TvAction(
        key: _key('$section-$value'),
        autofocus: autofocus,
        pill: true,
        selected: selected,
        onPressed: () => setState(onPressed),
        trailing: selected
            ? const Icon(CupertinoIcons.check_mark, size: 16)
            : null,
        child: Text(label),
      );
    }
    return OptionPill(
      key: _key('$section-$value'),
      label: label,
      selected: selected,
      onPressed: () => setState(onPressed),
    );
  }

  Widget _buildSortSection(BuildContext context, AppLocalizations l) {
    final sorts = CatalogSort.optionsFor(
      const [],
      capabilities: widget.capabilities,
    );
    final current = _sort;
    final canToggleOrder = current != null && current.supportsOrderToggle;
    final isAsc = CatalogSort.normalizeSortOrder(_sortOrder) == 'Ascending';
    final orderLabel = isAsc ? l.filterSortAscending : l.filterSortDescending;
    final orderIcon = isAsc ? CupertinoIcons.sort_up : CupertinoIcons.sort_down;

    final Widget? orderButton = canToggleOrder
        ? (widget.television
              ? TvAction(
                  key: _key('sort-order'),
                  pill: true,
                  leading: Icon(orderIcon, size: 16),
                  onPressed: _toggleSortOrder,
                  child: Text(orderLabel),
                )
              : OptionPill(
                  key: _key('sort-order'),
                  label: '${isAsc ? "↑" : "↓"} $orderLabel',
                  selected: true,
                  onPressed: _toggleSortOrder,
                ))
        : null;

    return Column(
      key: _key('sort-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          section: 'sort',
          title: l.mobileSort,
          icon: CupertinoIcons.sort_down,
          trailing: orderButton,
        ),
        Wrap(
          spacing: widget.television ? 10 : 8,
          runSpacing: widget.television ? 10 : 8,
          children: [
            for (final sort in sorts)
              _buildOptionItem(
                section: 'sort',
                value: sort.sortBy,
                label: sort.label(l),
                selected: _sort == sort,
                autofocus: widget.television && _sort == sort,
                onPressed: () => _selectSort(sort),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTypeSection(BuildContext context, AppLocalizations l) {
    return Column(
      key: _key('type-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          section: 'type',
          title: l.libraryFilterType,
          icon: CupertinoIcons.rectangle_stack,
        ),
        Wrap(
          spacing: widget.television ? 10 : 8,
          runSpacing: widget.television ? 10 : 8,
          children: [
            for (final value in CatalogTypeFilter.values)
              _buildOptionItem(
                section: 'type',
                value: value.itemType ?? 'all',
                label: value.label,
                selected: _draft.type == value,
                autofocus:
                    widget.television && _sort == null && _draft.type == value,
                onPressed: () => _draft = _draft.copyWith(type: value),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildWatchSection(BuildContext context, AppLocalizations l) {
    return Column(
      key: _key('watch-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          section: 'watch',
          title: l.libraryFilterWatch,
          icon: CupertinoIcons.eye,
        ),
        Wrap(
          spacing: widget.television ? 10 : 8,
          runSpacing: widget.television ? 10 : 8,
          children: [
            for (final value in CatalogWatchFilter.values)
              if (!widget.capabilities.unsupportedFilters.contains(value.param))
                _buildOptionItem(
                  section: 'watch',
                  value: value.param ?? 'all',
                  label: _watchLabel(l, value),
                  selected: _draft.watch == value,
                  autofocus:
                      widget.television &&
                      _sort == null &&
                      !widget.typeFilterable &&
                      _draft.watch == value,
                  onPressed: () => _draft = _draft.copyWith(watch: value),
                ),
          ],
        ),
      ],
    );
  }

  Widget _buildGenreSection(
    BuildContext context,
    AppLocalizations l,
    String query,
  ) {
    final genres = (_genres.toList()..sort())
        .where((g) => query.isEmpty || g.toLowerCase().contains(query))
        .toList();
    return Column(
      key: _key('genre-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          section: 'genre',
          title: l.libraryFilterGenre,
          icon: CupertinoIcons.square_grid_2x2,
          trailing: _genreFailed
              ? AppButton.icon(
                  onPressed: _loadGenres,
                  icon: const Icon(CupertinoIcons.arrow_clockwise),
                  label: Text(l.retry),
                  variant: AppButtonVariant.plain,
                )
              : null,
        ),
        if (_loadingGenres) ...[
          const AppLoadingBar(),
          const SizedBox(height: 8),
        ],
        if (_showSearchField) ...[
          if (widget.television)
            TvInput(
              key: _key('genre-search'),
              label: l.filterSearchOptions,
              controller: _search,
              onSubmitted: () => setState(() {}),
            )
          else
            AppTextField(
              key: _key('genre-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              placeholder: l.filterSearchOptions,
              prefix: const Icon(AppIcons.search, fill: AppIcons.filled),
              suffix: query.isEmpty
                  ? null
                  : AppIconButton(
                      tooltip: l.filterReset,
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                    ),
            ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: widget.television ? 10 : 8,
          runSpacing: widget.television ? 10 : 8,
          children: [
            _buildOptionItem(
              section: 'genre',
              value: 'all',
              label: l.libraryFilterAll,
              selected: _draft.genres.isEmpty,
              onPressed: () => _draft = _draft.copyWith(genres: []),
            ),
            for (final genre in genres)
              _buildOptionItem(
                section: 'genre',
                value: genre,
                label: genre,
                selected: _draft.genres.contains(genre),
                onPressed: () {
                  final values = [..._draft.genres];
                  values.contains(genre)
                      ? values.remove(genre)
                      : values.add(genre);
                  _draft = _draft.copyWith(genres: values);
                },
              ),
            if (genres.isEmpty && !_loadingGenres) Text(l.filterNoOptions),
          ],
        ),
      ],
    );
  }

  Widget _buildYearSection(
    BuildContext context,
    AppLocalizations l,
    String query,
  ) {
    final years =
        (query.isNotEmpty
                ? (<int>{
                    ...widget.years,
                    ..._draft.years,
                    for (var y = DateTime.now().year; y >= 1900; y--) y,
                  }.toList()..sort((a, b) => b.compareTo(a)))
                : _visibleYears())
            .where((y) => query.isEmpty || '$y'.contains(query))
            .toList();

    return Column(
      key: _key('year-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          section: 'year',
          title: l.libraryFilterYear,
          icon: CupertinoIcons.calendar,
        ),
        Wrap(
          spacing: widget.television ? 10 : 8,
          runSpacing: widget.television ? 10 : 8,
          children: [
            _buildOptionItem(
              section: 'year',
              value: 'all',
              label: l.libraryFilterAll,
              selected: _draft.years.isEmpty,
              onPressed: () => _draft = _draft.copyWith(years: []),
            ),
            for (final year in years)
              _buildOptionItem(
                section: 'year',
                value: '$year',
                label: '$year',
                selected: _draft.years.contains(year),
                onPressed: () {
                  final values = [..._draft.years];
                  values.contains(year)
                      ? values.remove(year)
                      : values.add(year);
                  _draft = _draft.copyWith(years: values);
                },
              ),
            if (!_allYearsExpanded && query.isEmpty)
              if (widget.television)
                TvAction(
                  key: _key('year-expand'),
                  pill: true,
                  onPressed: () => setState(() => _allYearsExpanded = true),
                  child: const Text('展开更多年份'),
                )
              else
                OptionPill(
                  key: _key('year-expand'),
                  label: '展开更多年份',
                  selected: false,
                  onPressed: () => setState(() => _allYearsExpanded = true),
                ),
          ],
        ),
      ],
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
