import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/detail_source_scope.dart';
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
    final gutter = PresentationScope.pageGutterOf(context);
    // 分区之间留 32;标题与内容之间留 12。
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, AppSpacing.xxl, gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
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
      color: theme.colorScheme.onSurface.withValues(
        alpha: PresentationScope.isPhoneOf(context) ? .86 : 1,
      ),
      fontSize: PresentationScope.isPhoneOf(context) ? 15 : null,
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

  /// 宽桌面窗口的圆形头像直径。
  static double desktopAvatarWidth(double screenWidth) =>
      (MediaShelf.posterWidthFor(screenWidth) * 0.72).clamp(104.0, 148.0);

  /// 手机演职员肖像卡宽：一行完整放下 3 张卡片，消除行尾大片空白。
  static double phoneCardWidth(double screenWidth) {
    final inner = screenWidth - AppSpacing.md * 2;
    return ((inner - AppSpacing.xs * 2) / 3).floorToDouble().clamp(88.0, 140.0);
  }

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
    this.circle = false,
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

  /// 桌面:圆形头像,姓名与角色居中。
  final bool circle;

  double imageHeight() => circle ? width : width * 3 / 2;
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
    final width = EpisodePeopleSection.phoneCardWidth(screen);
    return _PersonMetrics(
      width: width,
      cardGap: AppSpacing.xs,
      imageGap: 6,
      radius: AppRadii.md,
      surface: scheme.surfaceContainerLow,
      titleStyle: theme.textTheme.labelLarge?.copyWith(height: 1.2),
      roleStyle: theme.textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.2,
      ),
      titlePadding: const EdgeInsets.symmetric(horizontal: 6),
      imageMaxWidth: catalogPosterMaxWidth(
        width,
        MediaQuery.devicePixelRatioOf(context),
      ),
      phone: true,
      tv: false,
    );
  }
  if (screen < 600) {
    // 窄桌面窗口整卡分页,沿用海报比例。
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
  // 桌面用圆形头像:比海报尺寸的灰块紧凑,一行能看到更多人。
  final width = EpisodePeopleSection.desktopAvatarWidth(screen);
  return _PersonMetrics(
    width: width,
    cardGap: AppSpacing.lg,
    imageGap: AppSpacing.sm,
    radius: width / 2,
    surface: scheme.surfaceContainerHigh,
    titleStyle: theme.textTheme.labelLarge,
    roleStyle: theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    ),
    titlePadding: const EdgeInsets.symmetric(horizontal: 2),
    circle: true,
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
                paperInLight: true,
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
                paperInLight: true,
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
class _RowScrollBehavior extends AppScrollBehavior {
  const _RowScrollBehavior();
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
      final align = metrics.circle ? TextAlign.center : TextAlign.start;
      return SizedBox(
        width: metrics.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: metrics.circle
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            _PersonPoster(person: person, metrics: metrics, focused: focused),
            SizedBox(height: metrics.imageGap),
            Padding(
              padding: metrics.titlePadding,
              child: Text(
                name.isEmpty ? '?' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
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
                  textAlign: align,
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
                  color: widget.focused ? scheme.onSurface : AppInk.transparent,
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
                      // 人像海报多为半身照,圆形裁切时把脸留在框内。
                      alignment: metrics.circle
                          ? const Alignment(0, -0.55)
                          : Alignment.center,
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
    if (widget.metrics.circle) {
      // 没有头像:中性表面实底,首字放大;演职员靠首字与姓名区分,不再按姓名取色。
      final scheme = theme.colorScheme;
      return DecoratedBox(
        key: const ValueKey('cast-initial-avatar'),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
        child: Center(
          child: Text(
            name.isEmpty ? '?' : name.characters.first,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontSize: widget.metrics.width * 0.3,
              color: scheme.onSurface.withValues(alpha: 0.86),
            ),
          ),
        ),
      );
    }
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

/// 媒体流的类别。
enum MediaStreamKind { video, audio, subtitle }

/// 媒体流分区:当前片源的视频/音频/字幕轨分组列出。
///
/// [selectableElsewhere] 列出已在别处(桌面详情的播放设置行)提供选择的类别,
/// 这些类别不再重复列出;视频与不可选的单一音轨照常显示。
class EpisodeMediaStreamsSection extends StatelessWidget {
  const EpisodeMediaStreamsSection({
    super.key,
    required this.source,
    this.sources = const [],
    this.selectedSourceId,
    this.onSelectSource,
    this.selectedAudioIndex,
    this.selectedSubtitleIndex,
    this.onAudio,
    this.onSubtitle,
    this.selectableElsewhere = const {},
  });

  static const sectionKey = Key('episode-media-streams');
  static const phoneVersionRowKey = Key('phone-detail-version-row');

  /// 当前选中的片源;为 null 或无流时分区整段隐藏。
  final ItemMediaSource? source;
  final List<ItemMediaSource> sources;
  final String? selectedSourceId;
  final ValueChanged<String>? onSelectSource;
  final int? selectedAudioIndex;
  final int? selectedSubtitleIndex;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int>? onSubtitle;

  /// 已在播放设置行提供选择、本分区不再列出的类别。
  final Set<MediaStreamKind> selectableElsewhere;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final source = this.source;
    if (source == null || source.streams.isEmpty) {
      return const SizedBox.shrink();
    }
    final videos = [
      if (!selectableElsewhere.contains(MediaStreamKind.video))
        for (final s in source.streams)
          if (s.isVideo) s,
    ];
    final audios = [
      if (!selectableElsewhere.contains(MediaStreamKind.audio))
        for (final s in source.streams)
          if (s.isAudio) s,
    ];
    final subtitles = [
      if (!selectableElsewhere.contains(MediaStreamKind.subtitle))
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
    final hasMultipleSources = sources.length > 1;
    if (groups.isEmpty && !hasMultipleSources) {
      return const SizedBox.shrink();
    }
    if (PresentationScope.isPhoneOf(context)) {
      return _Section(
        title: l10n.detailMediaInfo,
        child: _PhoneStreamCard(
          key: sectionKey,
          groups: groups,
          source: source,
          sources: sources,
          selectedSourceId: selectedSourceId ?? source.id,
          onSelectSource: onSelectSource,
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
              // 浅色是白卡细边:卡内轨道胶囊用浅灰,两层不再糊成一片灰。
              decoration: BoxDecoration(
                color: scheme.brightness == Brightness.light
                    ? scheme.surfaceContainerLowest
                    : scheme.surfaceContainerHigh.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(
                  color: scheme.brightness == Brightness.light
                      ? scheme.outlineVariant
                      : scheme.onSurface.withValues(alpha: .06),
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

//// 手机媒体信息：一张卡里每类一行——版本、视频、音轨、字幕。左侧图标和类名，
/// 右侧是当前会播放的那一条；有多条可选时整行可点，弹出底部单选表。
/// 没选过时显示片源的默认轨，说明「不改就放这一条」。
class _PhoneStreamCard extends StatelessWidget {
  const _PhoneStreamCard({
    super.key,
    required this.groups,
    required this.source,
    this.sources = const [],
    this.selectedSourceId,
    this.onSelectSource,
  });

  final List<_StreamGroup> groups;
  final ItemMediaSource source;
  final List<ItemMediaSource> sources;
  final String? selectedSourceId;
  final ValueChanged<String>? onSelectSource;

  ItemMediaStream? _stream(int index) =>
      source.streams.where((s) => s.index == index).firstOrNull;

  IconData _icon(_StreamGroup group) {
    final first = group.choices.firstOrNull;
    final stream = first == null ? null : _stream(first.index);
    if (stream?.isSubtitle == true) return AppIcons.subtitles;
    if (stream?.isAudio == true) return AppIcons.music;
    return AppIcons.video;
  }

  int? _defaultIndex(_StreamGroup group) {
    for (final choice in group.choices) {
      if (_stream(choice.index)?.isDefault == true) return choice.index;
    }
    return null;
  }

  Future<void> _pickTrack(BuildContext context, _StreamGroup group) async {
    final highlighted = group.selectedIndex ?? _defaultIndex(group);
    final picked = await showAppModalSheet<int>(
      context: context,
      builder: (context) => _PhoneChoiceSheet<int>(
        title: group.title,
        options: [
          for (final choice in group.choices)
            _PhoneSheetOption(
              key: ValueKey('media-stream-${choice.index}'),
              value: choice.index,
              label: choice.line,
            ),
        ],
        selected: highlighted,
      ),
    );
    if (picked != null) group.onSelected?.call(picked);
  }

  Future<void> _pickVersion(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showAppModalSheet<String>(
      context: context,
      builder: (context) => _PhoneChoiceSheet<String>(
        title: l10n.mediaSource,
        options: [
          for (final item in sources)
            _PhoneSheetOption(
              key: ValueKey('phone-detail-version-${item.id}'),
              value: item.id,
              label: _PhoneVersionRow.versionLabel(item, sources: sources),
              subtitle: phoneSourceVersionSubtitle(item),
            ),
        ],
        selected: selectedSourceId ?? source.id,
      ),
    );
    if (picked != null) onSelectSource?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final hasMultipleSources = sources.length > 1;
    final rows = <Widget>[
      if (hasMultipleSources)
        _PhoneVersionRow(
          key: EpisodeMediaStreamsSection.phoneVersionRowKey,
          sources: sources,
          selectedSourceId: selectedSourceId ?? source.id,
          onTap: onSelectSource == null ? null : () => _pickVersion(context),
        ),
      for (final group in groups)
        _PhoneSelectorRow(
          key: ValueKey('phone-detail-stream-row-${group.title}'),
          icon: _icon(group),
          title: group.title,
          count: group.choices.length,
          value: _valueOf(group),
          valueKey: group.onSelected == null && group.choices.length == 1
              ? ValueKey('media-stream-${group.choices.first.index}')
              : null,
          onTap: group.onSelected != null && group.choices.length > 1
              ? () => _pickTrack(context, group)
              : null,
        ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              AppDivider(
                height: 1,
                indent: AppSpacing.md + 26,
                endIndent: AppSpacing.md,
                color: scheme.onSurface.withValues(alpha: .07),
              ),
            rows[i],
          ],
        ],
      ),
    );
  }

  String _valueOf(_StreamGroup group) {
    if (group.onSelected == null) {
      return group.choices.map((choice) => choice.line).join(' / ');
    }
    final highlighted = group.selectedIndex ?? _defaultIndex(group);
    final choice =
        group.choices.where((c) => c.index == highlighted).firstOrNull ??
        group.choices.firstOrNull;
    return choice?.line ?? '';
  }
}

/// 一行选择器：图标、类名（带胶囊可选数）、右侧单行当前值和下拉箭头。
class _PhoneSelectorRow extends StatelessWidget {
  const _PhoneSelectorRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.count = 1,
    this.valueKey,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final int count;
  final Key? valueKey;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final interactive = onTap != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 54),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: interactive
                    ? scheme.primary.withValues(alpha: .14)
                    : scheme.onSurface.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Icon(
                icon,
                size: 16,
                fill: AppIcons.filled,
                color: interactive ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (count > 1) ...[
              const SizedBox(width: 6),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value,
                key: valueKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: interactive
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: interactive ? FontWeight.w500 : null,
                ),
              ),
            ),
            if (interactive) ...[
              const SizedBox(width: 6),
              Icon(
                AppIcons.chevronDown,
                fill: AppIcons.filled,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
    if (!interactive) return row;
    return AppSurfaceAction(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: row,
    );
  }
}

class _PhoneSheetOption<T> {
  const _PhoneSheetOption({
    required this.key,
    required this.value,
    required this.label,
    this.subtitle,
  });

  final Key key;
  final T value;
  final String label;
  final String? subtitle;
}

/// 底部单选表：顶部拖拽指示条、标题计数与圆角卡片选项，当前项高亮描边并打勾。
class _PhoneChoiceSheet<T> extends StatelessWidget {
  const _PhoneChoiceSheet({
    required this.title,
    required this.options,
    required this.selected,
  });

  final String title;
  final List<_PhoneSheetOption<T>> options;
  final T? selected;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: .32),
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(width: AppSpacing.xs),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Text(
                    '${options.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            itemCount: options.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final option = options[index];
              final isSelected = option.value == selected;
              final subtitle = option.subtitle;
              return DecoratedBox(
                decoration: isSelected
                    ? AppSelectionDecoration.of(scheme, radius: AppRadii.md)
                    : BoxDecoration(
                        color: scheme.surfaceContainerHigh.withValues(
                          alpha: .55,
                        ),
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: .28),
                        ),
                      ),
                child: AppSurfaceAction(
                  key: option.key,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  onTap: () => Navigator.of(context).pop(option.value),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 50),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  option.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: isSelected
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurface,
                                    fontSize: 15,
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : null,
                                  ),
                                ),
                                if (subtitle != null &&
                                    subtitle.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isSelected) ...[
                            const SizedBox(width: 12),
                            Icon(
                              AppIcons.check,
                              fill: AppIcons.filled,
                              size: 18,
                              color: scheme.primary,
                            ),
                          ],
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

/// 版本行：与音轨字幕同形，右侧是当前片源的版本名。
class _PhoneVersionRow extends StatelessWidget {
  const _PhoneVersionRow({
    super.key,
    required this.sources,
    required this.selectedSourceId,
    this.onTap,
  });

  final List<ItemMediaSource> sources;
  final String selectedSourceId;
  final VoidCallback? onTap;

  static String versionLabel(
    ItemMediaSource source, {
    List<ItemMediaSource> sources = const [],
  }) {
    return phoneSourceVersionLabel(
      source,
      sources.isEmpty ? [source] : sources,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selected =
        sources.where((s) => s.id == selectedSourceId).firstOrNull ??
        sources.first;
    return _PhoneSelectorRow(
      icon: AppIcons.mediaSource,
      title: l10n.mediaSource,
      count: sources.length,
      value: versionLabel(selected, sources: sources),
      onTap: onTap,
    );
  }
}

// 轨道少时按文字宽度排列。轨道一多，长短标题会把换行挤成参差的一行一个，
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
        color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    return Container(
      decoration: selected
          ? AppSelectionDecoration.of(scheme, radius: AppRadii.sm)
          : BoxDecoration(
              color: scheme.brightness == Brightness.light
                  ? scheme.surfaceContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: AppInk.transparent),
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

/// 章节没有服务器剪影时：中性表面实底 + 章节序号，一排章节靠序号读出顺序。
/// 手机与桌面章节卡共用。
class ChapterFallbackArt extends StatelessWidget {
  const ChapterFallbackArt({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: AppSpacing.xs,
            top: 2,
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: theme.textTheme.headlineLarge?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: .28),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Center(
            child: Icon(
              AppIcons.play,
              fill: AppIcons.filled,
              size: 30,
              color: scheme.onSurfaceVariant.withValues(alpha: .8),
            ),
          ),
        ],
      ),
    );
  }
}
