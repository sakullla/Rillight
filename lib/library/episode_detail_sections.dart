import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/detached_scroll.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 详情页日期统一格式:yyyy-MM-dd(播出日期胶囊与元数据分区共用)。
String formatDateYmd(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// 分区骨架:标题 + 内容,左右对齐页面 [AppSpacing.page] 边距。
/// 与 `_ChapterStrip` 同一条竖线,数据为空的分区由调用方整段隐藏。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final phone = PresentationScope.isPhoneOf(context);
    final gutter = PresentationScope.pageGutterOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        phone ? AppSpacing.xl : AppSpacing.md,
        gutter,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: phone
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// 概览分区:默认 3 行截断,超长时提供展开/收起。
///
/// [compact] 为 true 时不带分区标题与页面边距,直接嵌入 hero 信息栏。
class EpisodeOverviewSection extends StatefulWidget {
  const EpisodeOverviewSection({
    super.key,
    required this.overview,
    this.compact = false,
    this.collapsedLines = _collapsedLines,
  });

  /// 正文文本,供测试断言 maxLines。
  static const textKey = Key('episode-overview-text');

  /// 展开/收起按钮。
  static const toggleKey = Key('episode-overview-toggle');

  static const _collapsedLines = 3;

  final String? overview;
  final bool compact;

  /// 折叠时最多显示的行数。剧集页用 2 行,把首屏留给分集。
  final int collapsedLines;

  @override
  State<EpisodeOverviewSection> createState() => _EpisodeOverviewSectionState();
}

class _EpisodeOverviewSectionState extends State<EpisodeOverviewSection> {
  bool _expanded = false;

  bool _exceedsCollapsedLines(
    BuildContext context,
    double maxWidth,
    TextStyle? style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: widget.overview, style: style),
      maxLines: widget.collapsedLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final overview = widget.overview;
    if (overview == null || overview.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.55,
    );
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final toggleable =
            _expanded ||
            _exceedsCollapsedLines(context, constraints.maxWidth, style);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              overview,
              key: EpisodeOverviewSection.textKey,
              maxLines: _expanded ? null : widget.collapsedLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: style,
            ),
            if (toggleable)
              AppButton(
                key: EpisodeOverviewSection.toggleKey,
                onPressed: () => setState(() => _expanded = !_expanded),
                style: AppButtonStyle(
                  foregroundColor: theme.colorScheme.primary,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  textStyle: theme.textTheme.labelLarge,
                ),
                variant: AppButtonVariant.plain,
                child: Text(_expanded ? l10n.collapse : l10n.expand),
              ),
          ],
        );
      },
    );
    if (widget.compact) {
      // 桌面嵌在标题旁信息栏里，与标题左对齐；手机直接排在页面上，取页面边距。
      final inset = PresentationScope.isPhoneOf(context)
          ? PresentationScope.pageGutterOf(context)
          : 0.0;
      return Padding(
        padding: EdgeInsets.fromLTRB(inset, AppSpacing.sm, inset, 0),
        child: body,
      );
    }
    return _Section(title: l10n.detailOverview, child: body);
  }
}

/// 窄屏横滑一次只露出放得下的整数张卡片。
///
/// 剩余宽度留白，下一张整页留在外面。滑到最后一页时卡片靠右，
/// 右侧边距与行首相同。宽屏换行不走这里。
class WholeCardStrip extends StatefulWidget {
  const WholeCardStrip({
    super.key,
    required this.itemCount,
    required this.cardWidth,
    required this.gap,
    required this.height,
    required this.itemBuilder,
    this.margin = 0,
  });

  final int itemCount;
  final double cardWidth;
  final double gap;
  final double height;
  final double margin;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<WholeCardStrip> createState() => _WholeCardStripState();
}

class _WholeCardStripState extends State<WholeCardStrip> {
  // 不记住页码。详情页的竖向 PageStorage 会把这一条横滑甩到最后一页。
  final _pages = PageController(keepPage: false);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  int _perPage(double viewport) {
    final inner = viewport - widget.margin * 2;
    if (inner <= widget.cardWidth || widget.cardWidth <= 0) {
      return 1;
    }
    var count = ((inner + widget.gap) / (widget.cardWidth + widget.gap))
        .floor();
    if (count < 1) {
      count = 1;
    }
    while (count > 1 &&
        count * widget.cardWidth + (count - 1) * widget.gap > inner + 0.1) {
      count--;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 0) {
      return SizedBox(height: widget.height);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        if (!viewport.isFinite || viewport <= 0) {
          return SizedBox(height: widget.height);
        }
        final perPage = _perPage(viewport);
        final pages = (widget.itemCount + perPage - 1) ~/ perPage;
        return SizedBox(
          height: widget.height,
          child: PageView.builder(
            controller: _pages,
            itemCount: pages,
            padEnds: false,
            itemBuilder: (context, page) {
              final start = page * perPage;
              final end = start + perPage > widget.itemCount
                  ? widget.itemCount
                  : start + perPage;
              final children = <Widget>[];
              for (var index = start; index < end; index++) {
                if (children.isNotEmpty) {
                  children.add(SizedBox(width: widget.gap));
                }
                children.add(widget.itemBuilder(context, index));
              }
              final alignEnd = pages > 1 && page == pages - 1;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.margin),
                child: Row(
                  mainAxisAlignment: alignEnd
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  children: children,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 演职员分区:演员、导演、编剧、其他各一条横行。
///
/// 图像是该端海报的 2:3 圆角矩形。手机和窄于 600 的非电视表面整卡分页；
/// 电视每组一条可聚焦横行；其余宽表面横向滚动，同一职务不折行。
class EpisodePeopleSection extends StatelessWidget {
  const EpisodePeopleSection({super.key, required this.people});

  static const sectionKey = Key('episode-people');

  /// 2:3 图像区域。同一分区里每张卡都用这把钥匙，测试从卡片往下找。
  static const imageKey = Key('episode-person-image');

  final List<ItemPerson> people;

  /// 分组顺序:演员 → 导演 → 编剧 → 其他。
  static const _typeOrder = ['Actor', 'Director', 'Writer'];

  String _groupLabel(AppLocalizations l10n, String? type) {
    return switch (type) {
      'Actor' => l10n.personTypeActor,
      'Director' => l10n.personTypeDirector,
      'Writer' => l10n.personTypeWriter,
      _ => l10n.personTypeOther,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    if (people.isEmpty) {
      return const SizedBox.shrink();
    }
    final groups = <String, List<ItemPerson>>{};
    for (final person in people) {
      final type = _typeOrder.contains(person.type) ? person.type! : '';
      groups.putIfAbsent(type, () => []).add(person);
    }
    final orderedTypes = [
      for (final type in _typeOrder)
        if (groups.containsKey(type)) type,
      if (groups.containsKey('')) '',
    ];
    final rail = _personRail(context);
    final metrics = _personMetrics(context);
    return _Section(
      title: l10n.detailCast,
      child: Column(
        key: sectionKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final type in orderedTypes) ...[
            Text(
              _groupLabel(l10n, type.isEmpty ? null : type),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PeopleGroupRow(
              typeKey: type,
              people: groups[type]!,
              rail: rail,
              metrics: metrics,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}

enum _PersonRail { whole, scroll, tv }

/// 手机，以及屏幕窄于 600 且不是电视的表面，一次只露出完整卡片。
_PersonRail _personRail(BuildContext context) {
  if (PresentationScope.maybeOf(context)?.isTv == true) {
    return _PersonRail.tv;
  }
  if (PresentationScope.isPhoneOf(context) ||
      MediaQuery.sizeOf(context).width < 600) {
    return _PersonRail.whole;
  }
  return _PersonRail.scroll;
}

class _PersonMetrics {
  const _PersonMetrics({
    required this.width,
    required this.cardGap,
    required this.imageGap,
    required this.radius,
    required this.surface,
    required this.titleStyle,
    required this.roleStyle,
    required this.titlePadding,
    required this.imageMaxWidth,
    required this.phone,
    required this.tv,
  });

  final double width;
  final double cardGap;
  final double imageGap;
  final double radius;
  final Color surface;
  final TextStyle? titleStyle;
  final TextStyle? roleStyle;
  final EdgeInsets titlePadding;
  final int imageMaxWidth;
  final bool phone;
  final bool tv;

  double imageHeight() => width * 3 / 2;
}

_PersonMetrics _personMetrics(BuildContext context) {
  final theme = AppUiTheme.of(context);
  final scheme = theme.colorScheme;
  final screen = MediaQuery.sizeOf(context).width;
  final tv = PresentationScope.maybeOf(context)?.isTv == true;
  final phone = PresentationScope.isPhoneOf(context);
  if (tv) {
    final scale = TvDesign.scaleOf(context);
    final width = TvDesign.posterWidth * scale;
    return _PersonMetrics(
      width: width,
      cardGap: TvDesign.cardGap * scale,
      imageGap: 8 * scale,
      radius: TvDesign.cardRadius * scale,
      surface: scheme.surfaceContainerHigh,
      titleStyle: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      roleStyle: theme.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: .8),
      ),
      titlePadding: EdgeInsets.zero,
      imageMaxWidth: tvImageWidth(context, width, max: 720),
      phone: false,
      tv: true,
    );
  }
  if (phone) {
    final width = phoneHomePosterCardWidth(screen);
    return _PersonMetrics(
      width: width,
      cardGap: AppSpacing.xs,
      imageGap: 6,
      radius: AppRadii.md,
      surface: scheme.surfaceContainerLow,
      titleStyle: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
      roleStyle: theme.textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.2,
      ),
      titlePadding: const EdgeInsets.symmetric(horizontal: 10),
      imageMaxWidth: catalogPosterMaxWidth(
        width,
        MediaQuery.devicePixelRatioOf(context),
      ),
      phone: true,
      tv: false,
    );
  }
  final width = MediaShelf.posterWidthFor(screen);
  return _PersonMetrics(
    width: width,
    cardGap: MediaShelf.cardGap,
    imageGap: AppSpacing.xs,
    radius: AppRadii.md,
    surface: scheme.surfaceContainerHigh,
    titleStyle: theme.textTheme.titleSmall,
    roleStyle: theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurface.withValues(alpha: 0.72),
    ),
    titlePadding: EdgeInsets.zero,
    imageMaxWidth: catalogPosterMaxWidth(
      width,
      MediaQuery.devicePixelRatioOf(context),
    ),
    phone: false,
    tv: false,
  );
}

double _lineHeight(BuildContext context, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: '海报Ag', style: style),
    strutStyle: StrutStyle.fromTextStyle(
      style ?? const TextStyle(),
      forceStrutHeight: true,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height.ceilToDouble();
  painter.dispose();
  return height;
}

String _personId(ItemPerson person) => person.id?.trim() ?? '';

String? _personRole(ItemPerson person) {
  final role = person.role?.trim();
  if (role == null || role.isEmpty) return null;
  return role;
}

void _openPerson(BuildContext context, ItemPerson person) {
  final id = _personId(person);
  if (id.isEmpty) return;
  final name = person.name.trim();
  context.push(
    AppRoutes.person(id, name: name.isEmpty ? null : name),
    extra: DetailSourceScope.command(context, id),
  );
}

class _PeopleGroupRow extends StatefulWidget {
  const _PeopleGroupRow({
    required this.typeKey,
    required this.people,
    required this.rail,
    required this.metrics,
  });

  final String typeKey;
  final List<ItemPerson> people;
  final _PersonRail rail;
  final _PersonMetrics metrics;

  @override
  State<_PeopleGroupRow> createState() => _PeopleGroupRowState();
}

class _PeopleGroupRowState extends State<_PeopleGroupRow> {
  // 详情页的竖向 PageStorage 不能把这一行恢复到末尾。
  final _scroll = ScrollController(keepScrollOffset: false);
  final _nodes = <int, FocusNode>{};
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateButtons();
    });
  }

  @override
  void didUpdateWidget(covariant _PeopleGroupRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.people.length != widget.people.length ||
        oldWidget.metrics.width != widget.metrics.width) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateButtons();
      });
    }
  }

  void _updateButtons() {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (!position.hasContentDimensions) {
      return;
    }
    final overflowing = position.maxScrollExtent > 0.5;
    final canLeft = overflowing && position.pixels > 0.5;
    final canRight =
        overflowing && position.pixels < position.maxScrollExtent - 0.5;
    if (canLeft == _canScrollLeft && canRight == _canScrollRight) {
      return;
    }
    setState(() {
      _canScrollLeft = canLeft;
      _canScrollRight = canRight;
    });
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final target =
        (position.pixels + position.viewportDimension * 0.9 * direction).clamp(
          0.0,
          position.maxScrollExtent,
        );
    final duration = AppMotion.durationOf(context);
    if (duration == Duration.zero) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(target, duration: duration, curve: AppMotion.standard);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) return;
    final vertical = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (vertical == null) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final dy = (resolved as PointerScrollEvent).scrollDelta.dy;
      final position = vertical.position;
      if (!position.hasPixels) return;
      position.pointerScroll(dy);
    });
  }

  FocusNode _nodeFor(int index) {
    return _nodes.putIfAbsent(index, () {
      final node = FocusNode(
        debugLabel: 'episode-person-${widget.typeKey}-$index',
      );
      node.addListener(() {
        if (node.hasFocus) _reveal(index);
      });
      return node;
    });
  }

  int? _neighbor(int index, bool forward) {
    final next = index + (forward ? 1 : -1);
    if (next < 0 || next >= widget.people.length) return null;
    return next;
  }

  int _focusedIndex() {
    for (final entry in _nodes.entries) {
      if (entry.value.hasFocus) return entry.key;
    }
    return -1;
  }

  void _reveal(int index) {
    if (!mounted || !_scroll.hasClients || widget.metrics.width <= 0) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final start = index * (widget.metrics.width + widget.metrics.cardGap);
    final end = start + widget.metrics.width;
    final view = position.viewportDimension;
    var target = position.pixels;
    if (start < target) {
      target = start;
    } else if (end > target + view) {
      target = end - view;
    }
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() < 0.5) return;
    position.jumpTo(clamped);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (widget.rail != _PersonRail.tv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final forward =
        (key == LogicalKeyboardKey.arrowRight) ==
        (Directionality.of(context) == TextDirection.ltr);
    final current = _focusedIndex();
    if (current < 0) return KeyEventResult.ignored;
    final next = _neighbor(current, forward);
    if (next == null) return KeyEventResult.handled;
    _reveal(next);
    _nodes[next]?.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scroll.removeListener(_updateButtons);
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  double _rowHeight(BuildContext context) {
    final metrics = widget.metrics;
    final role = widget.people.any((person) => _personRole(person) != null)
        ? _lineHeight(context, metrics.roleStyle)
        : 0.0;
    return metrics.imageHeight() +
        metrics.imageGap +
        _lineHeight(context, metrics.titleStyle) +
        role;
  }

  Widget _card(BuildContext context, int index) {
    return _PersonCard(
      key: ValueKey('episode-person-${widget.typeKey}-$index'),
      person: widget.people[index],
      metrics: widget.metrics,
      focusNode: widget.rail == _PersonRail.tv ? _nodeFor(index) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = _rowHeight(context);
    final metrics = widget.metrics;
    if (widget.rail == _PersonRail.whole) {
      return WholeCardStrip(
        height: height,
        itemCount: widget.people.length,
        cardWidth: metrics.width,
        gap: metrics.cardGap,
        itemBuilder: (context, index) {
          return SizedBox(
            height: height,
            child: Align(
              alignment: Alignment.topCenter,
              child: _card(context, index),
            ),
          );
        },
      );
    }
    if (widget.rail == _PersonRail.tv) {
      for (var index = 0; index < widget.people.length; index++) {
        _nodeFor(index);
      }
    }
    final row = ScrollConfiguration(
      behavior: const _RowScrollBehavior(),
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        primary: false,
        clipBehavior: widget.rail == _PersonRail.tv ? Clip.none : Clip.hardEdge,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < widget.people.length; index++) ...[
              if (index > 0) SizedBox(width: metrics.cardGap),
              _card(context, index),
            ],
          ],
        ),
      ),
    );
    if (widget.rail == _PersonRail.tv) {
      return Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: SizedBox(width: double.infinity, height: height, child: row),
      );
    }
    final l10n = AppLocalizations.of(context);
    final shelfId = 'people-${widget.typeKey}';
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _updateButtons();
              return false;
            },
            child: Listener(onPointerSignal: _onPointerSignal, child: row),
          ),
          if (_canScrollLeft)
            Align(
              alignment: Alignment.centerLeft,
              child: ScrimIconButton(
                key: CatalogKeys.shelfScrollLeft(shelfId),
                tooltip: l10n.scrollLeft,
                icon: const Icon(CupertinoIcons.chevron_left),
                onPressed: () => _page(-1),
              ),
            ),
          if (_canScrollRight)
            Align(
              alignment: Alignment.centerRight,
              child: ScrimIconButton(
                key: CatalogKeys.shelfScrollRight(shelfId),
                tooltip: l10n.scrollRight,
                icon: const Icon(CupertinoIcons.chevron_right),
                onPressed: () => _page(1),
              ),
            ),
        ],
      ),
    );
  }
}

/// 桌面鼠标左键可以拖动演职员横条。竖直滚轮仍交给外层详情页。
class _RowScrollBehavior extends CupertinoScrollBehavior {
  const _RowScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    super.key,
    required this.person,
    required this.metrics,
    this.focusNode,
  });

  final ItemPerson person;
  final _PersonMetrics metrics;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    Widget card(bool focused) {
      final role = _personRole(person);
      final name = person.name.trim();
      final titleStyle = metrics.tv
          ? metrics.titleStyle?.copyWith(
              fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
            )
          : metrics.titleStyle;
      return SizedBox(
        width: metrics.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PersonPoster(person: person, metrics: metrics, focused: focused),
            SizedBox(height: metrics.imageGap),
            Padding(
              padding: metrics.titlePadding,
              child: Text(
                name.isEmpty ? '?' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.start,
                style: titleStyle,
                strutStyle: StrutStyle.fromTextStyle(
                  titleStyle ?? const TextStyle(),
                  forceStrutHeight: true,
                ),
              ),
            ),
            if (role != null)
              Padding(
                padding: metrics.titlePadding,
                child: Text(
                  role,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: metrics.roleStyle,
                  strutStyle: StrutStyle.fromTextStyle(
                    metrics.roleStyle ?? const TextStyle(),
                    forceStrutHeight: true,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // 无 Id 的卡也进入焦点顺序以便滚进视口，但确认键不打开人物页。
    if (metrics.tv) {
      return TvAction(
        focusNode: focusNode,
        variant: TvActionVariant.card,
        onPressed: () {
          if (_personId(person).isNotEmpty) {
            _openPerson(context, person);
          }
        },
        child: Builder(builder: (context) => card(TvAction.focusedOf(context))),
      );
    }
    if (_personId(person).isEmpty) return card(false);
    return Container(
      decoration: BoxDecoration(),
      child: AppSurfaceAction(
        onTap: () => _openPerson(context, person),
        canRequestFocus: !metrics.phone,
        child: card(false),
      ),
    );
  }
}

/// 人物海报。有 Id 和 Primary 标签时走 [MediaImageCache] 与 `getItemImage`；
/// 没有图或加载失败时，在同一矩形里显示姓名首字。
class _PersonPoster extends StatefulWidget {
  const _PersonPoster({
    required this.person,
    required this.metrics,
    required this.focused,
  });

  final ItemPerson person;
  final _PersonMetrics metrics;
  final bool focused;

  @override
  State<_PersonPoster> createState() => _PersonPosterState();
}

class _PersonPosterState extends State<_PersonPoster> {
  Future<Uint8List?>? _future;
  int? _loadedWidth;

  bool get _hasImage {
    final id = _personId(widget.person);
    final tag = widget.person.primaryImageTag;
    return id.isNotEmpty && tag != null && tag.isNotEmpty;
  }

  bool get _canLoad =>
      AuthScope.maybeOf(context) != null ||
      DetailSourceScope.maybeOf(context) != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasImage && _canLoad) {
      _future ??= _load();
    }
  }

  @override
  void didUpdateWidget(_PersonPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    final samePerson =
        widget.person.id == oldWidget.person.id &&
        widget.person.primaryImageTag == oldWidget.person.primaryImageTag &&
        widget.metrics.imageMaxWidth == _loadedWidth;
    if (samePerson) return;
    _future = _hasImage && _canLoad ? _load() : null;
  }

  Future<Uint8List?> _load() {
    final auth = AuthScope.maybeOf(context);
    final origin = DetailSourceScope.maybeOf(context);
    final policy = DetailSourceScope.imagePolicyOf(context);
    final maxWidth = widget.metrics.imageMaxWidth;
    _loadedWidth = maxWidth;
    if (origin == null && auth == null) {
      return Future<Uint8List?>.value(null);
    }
    final String serverId;
    if (policy != null && policy.isValid) {
      serverId = policy.scope;
    } else if (origin == null) {
      serverId = auth?.session?.server.id ?? '';
    } else {
      return Future<Uint8List?>.value(null);
    }
    final client = origin?.client ?? auth!.client;
    final id = _personId(widget.person);
    final tag = widget.person.primaryImageTag;
    return MediaImageCache.instance.load(
      policy: policy != null && policy.isValid ? policy : null,
      serverId: serverId,
      itemId: id,
      type: 'Primary',
      tag: tag,
      maxWidth: maxWidth,
      fetch: () async {
        try {
          final data = await client.getItemImage(
            id,
            tag: tag,
            maxWidth: maxWidth,
          );
          if (data.isEmpty) return null;
          return Uint8List.fromList(data);
        } catch (_) {
          return null;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    final radius = BorderRadius.circular(metrics.radius);
    final scheme = AppUiTheme.of(context).colorScheme;
    final scale = metrics.tv ? TvDesign.scaleOf(context) : 1.0;
    return SizedBox(
      key: EpisodePeopleSection.imageKey,
      width: metrics.width,
      height: metrics.imageHeight(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: metrics.surface,
          borderRadius: radius,
          border: metrics.tv
              ? Border.all(
                  color: widget.focused
                      ? scheme.onSurface
                      : const Color(0x00000000),
                  width: TvAction.focusRingWidth * scale,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: Clip.hardEdge,
          child: _hasImage
              ? FutureBuilder<Uint8List?>(
                  future: _future,
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes == null || bytes.isEmpty) return _letter(context);
                    return Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          _letter(context),
                    );
                  },
                )
              : _letter(context),
        ),
      ),
    );
  }

  Widget _letter(BuildContext context) {
    final name = widget.person.name.trim();
    final theme = AppUiTheme.of(context);
    return Center(
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 媒体流分区:当前片源的视频/音频/字幕轨分组列出。
class EpisodeMediaStreamsSection extends StatelessWidget {
  const EpisodeMediaStreamsSection({
    super.key,
    required this.source,
    this.selectedAudioIndex,
    this.selectedSubtitleIndex,
    this.onAudio,
    this.onSubtitle,
  });

  static const sectionKey = Key('episode-media-streams');

  /// 当前选中的片源;为 null 或无流时分区整段隐藏。
  final ItemMediaSource? source;
  final int? selectedAudioIndex;
  final int? selectedSubtitleIndex;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final source = this.source;
    if (source == null || source.streams.isEmpty) {
      return const SizedBox.shrink();
    }
    final videos = [
      for (final s in source.streams)
        if (s.isVideo) s,
    ];
    final audios = [
      for (final s in source.streams)
        if (s.isAudio) s,
    ];
    final subtitles = [
      for (final s in source.streams)
        if (s.isSubtitle) s,
    ];
    final videoChoices = _choices(videos, _videoLine);
    final audioChoices = _choices(audios, (stream) => _audioLine(l10n, stream));
    final subtitleChoices = _choices(subtitles, _subtitleLine);
    final groups = <_StreamGroup>[
      if (videoChoices.isNotEmpty) _StreamGroup(l10n.videoTrack, videoChoices),
      if (audioChoices.isNotEmpty)
        _StreamGroup(
          l10n.audioTrack,
          audioChoices,
          selectedIndex: selectedAudioIndex,
          onSelected: onAudio,
        ),
      if (subtitleChoices.isNotEmpty)
        _StreamGroup(
          l10n.subtitleTrack,
          subtitleChoices,
          selectedIndex: selectedSubtitleIndex,
          onSelected: onSubtitle,
        ),
    ];
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    if (PresentationScope.isPhoneOf(context)) {
      return _Section(
        title: l10n.detailMediaInfo,
        child: _PhoneStreamCard(
          key: sectionKey,
          groups: groups,
          source: source,
        ),
      );
    }
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 桌面/电视：一张卡，左侧是固定宽的分类名，右侧是该类各轨，行间细分隔线。
    // 窄窗口放不下标签列时，分类名回到各组上方。
    final scheme = theme.colorScheme;
    return _Section(
      title: l10n.detailMediaInfo,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              key: sectionKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  Text(groups[i].title, style: labelStyle),
                  const SizedBox(height: AppSpacing.xs),
                  _StreamChoiceWrap(group: groups[i]),
                ],
              ],
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(
                  color: scheme.onSurface.withValues(alpha: .06),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                child: Column(
                  key: sectionKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < groups.length; i++) ...[
                      if (i > 0)
                        AppDivider(
                          height: 1,
                          color: scheme.onSurface.withValues(alpha: .08),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 72,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(groups[i].title, style: labelStyle),
                              ),
                            ),
                            Expanded(
                              child: _StreamChoiceWrap(group: groups[i]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static List<_StreamChoice> _choices(
    List<ItemMediaStream> streams,
    String Function(ItemMediaStream stream) lineOf,
  ) {
    final labeled = <_StreamChoice>[];
    final counts = <String, int>{};
    for (final stream in streams) {
      final line = lineOf(stream);
      if (line.isEmpty) {
        continue;
      }
      counts[line] = (counts[line] ?? 0) + 1;
      labeled.add(_StreamChoice(stream.index, line));
    }
    return [
      for (final choice in labeled)
        if (counts[choice.line]! > 1)
          _StreamChoice(choice.index, '${choice.line} #${choice.index}')
        else
          choice,
    ];
  }

  static String _joined(List<String?> parts) {
    return [
      for (final part in parts)
        if (part != null && part.trim().isNotEmpty) part.trim(),
    ].join(' · ');
  }

  static String? _upper(String? codec) {
    final value = codec?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.toUpperCase();
  }

  /// 紧凑摘要:视频、音频、字幕各一行,供电视详情的信息区使用。
  static List<(String, String)> summary(
    AppLocalizations l10n,
    ItemMediaSource source,
  ) {
    String join(
      Iterable<ItemMediaStream> streams,
      String Function(ItemMediaStream) line,
    ) =>
        {for (final stream in streams) line(stream)}
            .where((value) => value.isNotEmpty)
            .join('  ·  ');
    final video = join(source.streams.where((s) => s.isVideo), _videoLine);
    final audio = join(
      source.streams.where((s) => s.isAudio),
      (stream) => _audioLine(l10n, stream),
    );
    final subtitle = join(
      source.streams.where((s) => s.isSubtitle),
      _subtitleLine,
    );
    return [
      if (video.isNotEmpty) (l10n.videoTrack, video),
      if (audio.isNotEmpty) (l10n.audioTrack, audio),
      if (subtitle.isNotEmpty) (l10n.subtitleTrack, subtitle),
    ];
  }

  static String _videoLine(ItemMediaStream stream) {
    final range = stream.videoRange?.trim();
    final showRange =
        range != null && range.isNotEmpty && range.toUpperCase() != 'SDR';
    final line = _joined([
      _resolution(stream),
      _upper(stream.codec),
      if (showRange) range,
    ]);
    if (line.isNotEmpty) {
      return line;
    }
    return stream.label?.trim() ?? '';
  }

  static String? _resolution(ItemMediaStream stream) {
    final height = stream.height;
    if (height == null || height <= 0) {
      return null;
    }
    if (height >= 2000) {
      return '4K';
    }
    if (height >= 1400) {
      return '1440p';
    }
    if (height >= 1000) {
      return '1080p';
    }
    if (height >= 700) {
      return '720p';
    }
    return '${height}p';
  }

  static String _audioLine(AppLocalizations l10n, ItemMediaStream stream) {
    final label = stream.label?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return _joined([
      _upper(stream.codec),
      stream.channels != null ? l10n.audioChannels(stream.channels!) : null,
    ]);
  }

  static String _subtitleLine(ItemMediaStream stream) {
    final label = stream.label?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return _upper(stream.codec) ?? '';
  }
}

class _StreamChoice {
  const _StreamChoice(this.index, this.line);

  final int index;
  final String line;
}

class _StreamGroup {
  const _StreamGroup(
    this.title,
    this.choices, {
    this.selectedIndex,
    this.onSelected,
  });

  final String title;
  final List<_StreamChoice> choices;
  final int? selectedIndex;
  final ValueChanged<int>? onSelected;
}

/// 手机媒体信息：一张卡分三行（视频/音轨/字幕），每行图标 + 标题，下面是可横滑的
/// 单选轨道。没选过时高亮片源的默认轨，说明「不改就放这一条」。
class _PhoneStreamCard extends StatelessWidget {
  const _PhoneStreamCard({
    super.key,
    required this.groups,
    required this.source,
  });

  final List<_StreamGroup> groups;
  final ItemMediaSource source;

  ItemMediaStream? _stream(int index) =>
      source.streams.where((s) => s.index == index).firstOrNull;

  IconData _icon(_StreamGroup group) {
    final first = group.choices.firstOrNull;
    final stream = first == null ? null : _stream(first.index);
    if (stream?.isSubtitle == true) return CupertinoIcons.captions_bubble;
    if (stream?.isAudio == true) return CupertinoIcons.waveform;
    return CupertinoIcons.videocam;
  }

  int? _defaultIndex(_StreamGroup group) {
    for (final choice in group.choices) {
      if (_stream(choice.index)?.isDefault == true) return choice.index;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0)
              AppDivider(
                height: 1,
                indent: AppSpacing.md,
                endIndent: AppSpacing.md,
                color: scheme.outlineVariant.withValues(alpha: .5),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _icon(groups[i]),
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          groups[i].title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (groups[i].choices.length > 1) ...[
                          const SizedBox(width: AppSpacing.xxs),
                          Text(
                            '${groups[i].choices.length}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: .7,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  if (groups[i].onSelected == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final choice in groups[i].choices)
                            Text(
                              choice.line,
                              key: ValueKey('media-stream-${choice.index}'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    )
                  else
                    _PhoneTrackRow(
                      group: groups[i],
                      highlighted:
                          groups[i].selectedIndex ?? _defaultIndex(groups[i]),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PhoneTrackRow extends StatelessWidget {
  const _PhoneTrackRow({required this.group, required this.highlighted});

  final _StreamGroup group;
  final int? highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final height =
        40 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);
    return SizedBox(
      height: height,
      child: DetachedHorizontalScroll(
        builder: (controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          itemCount: group.choices.length,
          separatorBuilder: (context, index) =>
              const SizedBox(width: AppSpacing.xs),
          itemBuilder: (context, index) {
            final choice = group.choices[index];
            final selected = choice.index == highlighted;
            return Container(
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary.withValues(alpha: .16)
                    : scheme.surface.withValues(alpha: .6),
              ),
              key: ValueKey('media-stream-${choice.index}'),
              clipBehavior: Clip.antiAlias,
              child: AppSurfaceAction(
                onTap: () => group.onSelected!(choice.index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (selected) ...[
                        Icon(
                          CupertinoIcons.check_mark,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 4),
                      ],
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: Text(
                          choice.line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: selected ? scheme.primary : scheme.onSurface,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 轨道少时按文字宽度排列。轨道一多，长短标题会把换行挤成参差的一行一个，
/// 所以改成等宽列，重复标题补上轨道序号。
class _StreamChoiceWrap extends StatelessWidget {
  const _StreamChoiceWrap({required this.group});

  static const _denseCount = 5;

  final _StreamGroup group;

  @override
  Widget build(BuildContext context) {
    final dense = group.choices.length >= _denseCount;
    if (!dense) {
      return Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [for (final choice in group.choices) _chip(context, choice)],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gap = AppSpacing.xs;
        final columns = width >= 760
            ? 4
            : width >= 520
            ? 3
            : 2;
        final cell = columns <= 1
            ? width
            : (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final choice in group.choices)
              SizedBox(
                width: cell,
                child: _chip(context, choice, expand: true),
              ),
          ],
        );
      },
    );
  }

  Widget _chip(
    BuildContext context,
    _StreamChoice choice, {
    bool expand = false,
  }) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final selected = choice.index == group.selectedIndex;
    final label = Text(
      choice.line,
      maxLines: expand ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: selected ? scheme.primary : scheme.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: 0.18)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      key: ValueKey('media-stream-${choice.index}'),
      clipBehavior: Clip.antiAlias,
      child: AppSurfaceAction(
        onTap: group.onSelected == null
            ? null
            : () => group.onSelected!(choice.index),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: expand
              ? SizedBox(width: double.infinity, child: label)
              : label,
        ),
      ),
    );
  }
}

/// 下一集卡片:缩略图 + 标题,点击进入该集详情。无下一集时整段隐藏。
class NextEpisodeCard extends StatelessWidget {
  const NextEpisodeCard({super.key, required this.episode, this.onTap});

  static const sectionKey = Key('episode-next-section');
  static const cardKey = Key('episode-next-card');

  final MediaItem? episode;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final episode = this.episode;
    if (episode == null) {
      return const SizedBox.shrink();
    }
    final runtime = runtimeLabel(l10n, episode);
    return _Section(
      title: l10n.nextEpisode,
      child: ConstrainedBox(
        key: sectionKey,
        constraints: const BoxConstraints(maxWidth: 420),
        child: SizedBox(
          width: double.infinity,
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: AppSurfaceAction(
              key: cardKey,
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: SizedBox(
                        width: 160,
                        height: 90,
                        child: MediaImage(
                          item: episode,
                          width: 160,
                          height: 90,
                          preferThumb: true,
                          maxWidth: 320,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            episodeLabel(episode),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          if (runtime != null)
                            Text(
                              runtime,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
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
        ),
      ),
    );
  }
}

/// 元数据分区:入库日期等次级日期。全部缺失时整段隐藏。
///
/// 手机上扩成「详细信息」：首播、时长、入库日期和当前片源的容器、大小、码率，
/// 左标签右数值的表格。
class EpisodeMetadataSection extends StatelessWidget {
  const EpisodeMetadataSection({super.key, required this.item, this.source});

  static const sectionKey = Key('episode-metadata');

  final MediaItem item;

  /// 当前片源；手机信息表据此给出容器、文件大小与码率。
  final ItemMediaSource? source;

  static String _bytes(int size) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit >= 3 ? 2 : (unit == 0 ? 0 : 1);
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  static String _bitrate(int bps) {
    if (bps >= 1000000) {
      return '${(bps / 1000000).toStringAsFixed(1)} Mbps';
    }
    return '${(bps / 1000).round()} kbps';
  }

  Widget _phone(BuildContext context, AppLocalizations l10n) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final source = this.source;
    final runtime = item.isSeries ? null : runtimeLabel(l10n, item);
    final container = source?.container?.trim();
    final size = source?.size;
    final bitrate = source?.bitrate;
    final rows = <(String, String)>[
      if (item.premiereDate != null)
        (l10n.premiereDateLabel, formatDateYmd(item.premiereDate!)),
      if (runtime != null) (l10n.runtimeRowLabel, runtime),
      if (item.dateCreated != null)
        (l10n.dateAdded, formatDateYmd(item.dateCreated!)),
      if (container != null && container.isNotEmpty)
        (l10n.fileContainerLabel, container.toUpperCase()),
      if (size != null && size > 0) (l10n.fileSizeLabel, _bytes(size)),
      if (bitrate != null && bitrate > 0)
        (l10n.fileBitrateLabel, _bitrate(bitrate)),
    ];
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return _Section(
      title: l10n.detailInfo,
      child: DecoratedBox(
        key: sectionKey,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                AppDivider(
                  height: 1,
                  indent: AppSpacing.md,
                  endIndent: AppSpacing.md,
                  color: scheme.outlineVariant.withValues(alpha: .5),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(rows[i].$1, style: labelStyle)),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: Text(
                        rows[i].$2,
                        textAlign: TextAlign.end,
                        style: valueStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    if (PresentationScope.isPhoneOf(context)) {
      return _phone(context, l10n);
    }
    final rows = <(String, String)>[
      if (item.dateCreated != null)
        (l10n.dateAdded, formatDateYmd(item.dateCreated!)),
    ];
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return _Section(
      title: l10n.detailMetadata,
      child: Column(
        key: sectionKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xxs,
                children: [
                  Text(
                    row.$1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(row.$2, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 章节没有服务器剪影时：主色渐变底 + 章节序号，一排章节读起来是一段顺序，
/// 而不是一排灰块。手机与桌面章节卡共用。
class ChapterFallbackArt extends StatelessWidget {
  const ChapterFallbackArt({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerHigh],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: AppSpacing.xs,
            top: 2,
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: theme.textTheme.headlineLarge?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: .28),
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Center(
            child: Icon(
              CupertinoIcons.play_circle,
              size: 30,
              color: scheme.onPrimaryContainer.withValues(alpha: .8),
            ),
          ),
        ],
      ),
    );
  }
}
