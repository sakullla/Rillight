import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/media_image/media_image.dart';

/// Repairs a removed remote target only on the visible route. Offstage panes
/// cannot receive focus; a surviving nearby target or navigation remains usable.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child});
  final Widget child;
  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final _nodes = <FocusNode>{};
  Rect? _lastRect;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_schedule);
  }

  void selected(FocusNode node) {
    if (node.context != null) _lastRect = node.rect;
  }

  void remove(FocusNode node) {
    if (node.hasFocus && node.context != null) _lastRect = node.rect;
    _nodes.remove(node);
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          _lastRect == null) {
        return;
      }
      if (_nodes.any((node) => node.hasFocus)) return;
      final current = FocusManager.instance.primaryFocus;
      // Preserve an intentional non-button input target.
      if (current != null &&
          current is! FocusScopeNode &&
          current.context != null &&
          current.context!.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
        return;
      }
      final candidates = _nodes
          .where(
            (node) =>
                node.context?.mounted == true &&
                node.canRequestFocus &&
                !node.skipTraversal,
          )
          .toList();
      candidates.sort(
        (a, b) => (a.rect.center - _lastRect!.center).distanceSquared.compareTo(
          (b.rect.center - _lastRect!.center).distanceSquared,
        ),
      );
      if (candidates.isNotEmpty) {
        candidates.first.requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _TvFocusRegistry(owner: this, child: widget.child);
}

class _TvFocusRegistry extends InheritedWidget {
  const _TvFocusRegistry({required this.owner, required super.child});
  final _TvFocusRegionState owner;
  @override
  bool updateShouldNotify(_TvFocusRegistry oldWidget) =>
      owner != oldWidget.owner;
}

/// A stable, visible remote target. Its node survives rebuilds and route pushes.
class TvAction extends StatefulWidget {
  const TvAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.emphasized = false,
    this.pill = false,
    this.leading,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final bool autofocus, selected, emphasized;

  /// 胶囊形态:圆角 28、横向留白更大,用于顶部导航、筛选与分季切换。
  final bool pill;

  /// 可选前导图标,与 [child] 横向排列。
  final Widget? leading;
  final FocusNode? focusNode;

  /// 聚焦放大档位,要求落在 1.05–1.1。
  static const double focusedScale = 1.06;

  /// 高对比焦点环宽度,要求不低于 4px。
  static const double focusRingWidth = 4;
  @override
  State<TvAction> createState() => _TvActionState();
}

class _TvActionState extends State<TvAction>
    with AutomaticKeepAliveClientMixin {
  final _ownedNode = FocusNode();
  bool get _focused => _node.hasFocus;
  _TvFocusRegionState? _region;
  bool _activating = false;
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    updateKeepAlive();
    if (_node.hasFocus) {
      _region?.selected(_node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _node.hasFocus &&
            ModalRoute.of(context)?.isCurrent != false) {
          Scrollable.ensureVisible(
            context,
            alignment: .5,
            duration: AppMotion.durationOf(context, AppMotion.fast),
            curve: AppMotion.standard,
          );
        }
      });
    }
  }

  @override
  bool get wantKeepAlive => _focused;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final region = context
        .dependOnInheritedWidgetOfExactType<_TvFocusRegistry>()
        ?.owner;
    if (!identical(region, _region)) {
      _region?.remove(_node);
      _region = region;
      _region?._nodes.add(_node);
    }
  }

  Future<void> _activate() async {
    if (widget.onPressed == null || _activating) return;
    _activating = true;
    try {
      await widget.onPressed!();
    } finally {
      _activating = false;
      if (mounted && _node.canRequestFocus) _node.requestFocus();
    }
  }

  @override
  void dispose() {
    _region?.remove(_node);
    _node.removeListener(_changed);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final fill = widget.emphasized
        ? (_focused ? scheme.primary : scheme.primaryContainer)
        : _focused
        ? scheme.primaryContainer
        : widget.selected
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerHigh;
    final foreground = widget.emphasized
        ? (_focused ? scheme.onPrimary : scheme.onPrimaryContainer)
        : null;
    final content = widget.leading == null
        ? widget.child
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.leading!,
              const SizedBox(width: 8),
              Flexible(child: widget.child),
            ],
          );
    return ExcludeFocus(
      excluding: widget.onPressed == null,
      child: FocusableActionDetector(
        focusNode: _node,
        autofocus: widget.autofocus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_activate());
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: widget.onPressed != null,
          focused: _focused,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.onPressed == null ? null : _activate,
            child: AnimatedScale(
              // 焦点放大档位落在 1.05–1.1;动画经 AppMotion 中枢,减少动效时即时。
              scale: _focused ? TvAction.focusedScale : 1.0,
              duration: AppMotion.durationOf(context, AppMotion.fast),
              curve: AppMotion.standard,
              child: AnimatedContainer(
                duration: AppMotion.durationOf(context, AppMotion.fast),
                margin: const EdgeInsets.all(4),
                padding: widget.pill
                    ? const EdgeInsets.symmetric(horizontal: 18, vertical: 10)
                    : const EdgeInsets.all(12),
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  color: fill,
                  border: Border.all(
                    // 高对比焦点环:深色主题下是暖白,浅色主题下是深色。
                    color: _focused ? scheme.onSurface : Colors.transparent,
                    width: TvAction.focusRingWidth,
                  ),
                  borderRadius: BorderRadius.circular(widget.pill ? 28 : 10),
                ),
                child: Opacity(
                  opacity: widget.onPressed == null ? .4 : 1,
                  child: foreground == null
                      ? content
                      : IconTheme(
                          data: IconThemeData(color: foreground),
                          child: DefaultTextStyle.merge(
                            style: TextStyle(color: foreground),
                            child: content,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TV 舞台级主题覆写:弹窗底色与 1.15 倍阅读字号,TvFrame 与 TvShell 共用。
class TvStageTheme extends StatelessWidget {
  const TvStageTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        dialogTheme: DialogThemeData(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
        ),
        textTheme: Theme.of(context).textTheme.apply(fontSizeFactor: 1.15),
      ),
      child: child,
    );
  }
}

/// 视口安全区留白:边距不低于视口宽/高的 5%(960x540 下恰为 48)。
double tvSafeGutter(double extent) => math.max(48.0, extent * 0.05);

class TvFrame extends StatelessWidget {
  const TvFrame({
    super.key,
    required this.title,
    required this.child,
    this.back = true,
    this.edgeToEdge = false,
  });
  final String title;
  final Widget child;
  final bool back;

  /// 出血模式:true 时 [child] 铺满整个视口(调用方把沉浸头图放在滚动内容
  /// 最前,自行处理正文留白),标题行带遮罩浮在最上方;false 时布局与既有
  /// 安全区版本逐字节一致。
  final bool edgeToEdge;

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    // 安全区:边距不低于视口宽/高的 5%(960x540 下恰为 48),大屏随之放大。
    final horizontal = tvSafeGutter(viewSize.width);
    final vertical = tvSafeGutter(viewSize.height);
    return TvStageTheme(
      child: TvFocusRegion(
        child: Scaffold(
          body: !edgeToEdge
              ? SafeArea(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontal,
                      vertical: vertical,
                    ),
                    child: FocusTraversalGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _TvTitleRow(title: title, back: back),
                          const SizedBox(height: 12),
                          Expanded(child: child),
                        ],
                      ),
                    ),
                  ),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    FocusTraversalGroup(child: child),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _TvImmersiveTitleBand(
                        title: title,
                        back: back,
                        horizontal: horizontal,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TvTitleRow extends StatelessWidget {
  const _TvTitleRow({required this.title, required this.back});
  final String title;
  final bool back;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (back)
          TvAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Icon(Icons.arrow_back),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 出血页顶部遮罩带:保护返回钮与标题,向下溶到透明。
class _TvImmersiveTitleBand extends StatelessWidget {
  const _TvImmersiveTitleBand({
    required this.title,
    required this.back,
    required this.horizontal,
  });
  final String title;
  final bool back;
  final double horizontal;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final band = dark ? Colors.black : scheme.surface;
    final alpha = AppScrim.of(
      context,
      dark ? AppScrim.topBar : AppScrim.lightTopBar,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            band.withValues(alpha: alpha),
            band.withValues(alpha: alpha * 0.5),
            band.withValues(alpha: 0),
          ],
          stops: AppScrim.topBarStops,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: horizontal,
            right: horizontal,
            top: 12,
            bottom: 28,
          ),
          child: _TvTitleRow(title: title, back: back),
        ),
      ),
    );
  }
}

class TvFailure extends StatelessWidget {
  const TvFailure({super.key, required this.error, required this.retry});
  final EmbyException error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(embyFailureMessage(AppLocalizations.of(context), error)),
      TvAction(
        autofocus: true,
        onPressed: retry,
        child: Text(AppLocalizations.of(context).retry),
      ),
    ],
  );
}

/// 现代化 TV 海报卡:圆角封面 + 进度/已看/评分角标,聚焦时浮起投阴影。
///
/// 交互核仍是 [TvAction](焦点环、缩放、激活语义不变);[wide] 切换 16:9
/// 缩略图版式(继续观看行),海报版式保持 2:3。
class TvCard extends StatefulWidget {
  const TvCard({
    super.key,
    required this.item,
    this.autofocus = false,
    this.imageMaxWidth = 280,
    this.focusNode,
    this.wide = false,
  });
  final EmbyItem item;
  final bool autofocus;
  final int imageMaxWidth;
  final FocusNode? focusNode;

  /// 16:9 横版卡:继续观看行的剧集/影片缩略图。
  final bool wide;
  @override
  State<TvCard> createState() => _TvCardState();
}

class _TvCardState extends State<TvCard> {
  final _ownedNode = FocusNode();
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  bool get _focused => _node.hasFocus;

  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _node.removeListener(_changed);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final progress = item.playbackProgress;
    final played = item.userData.played;
    final meta = <String>[if (widget.wide && item.isEpisode) ?item.seriesName];
    return TvAction(
      autofocus: widget.autofocus,
      focusNode: _node,
      onPressed: () => context.push(AppRoutes.item(item.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: AppMotion.durationOf(context, AppMotion.fast),
              curve: AppMotion.standard,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                boxShadow: _focused
                    ? const [
                        BoxShadow(
                          blurRadius: 16,
                          offset: Offset(0, 6),
                          color: Color(0x59000000),
                        ),
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: MediaImage(
                        item: item,
                        maxWidth: widget.imageMaxWidth,
                        fit: BoxFit.cover,
                        preferThumb: widget.wide,
                      ),
                    ),
                    if (played)
                      ColoredBox(color: Colors.black.withValues(alpha: .28)),
                    if (progress > 0 && !played)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.black.withValues(alpha: .45),
                        ),
                      ),
                    if (played)
                      const Positioned(
                        right: 6,
                        top: 6,
                        child: EpisodeWatchedBadge(size: 18),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (meta.isNotEmpty)
            Text(
              meta.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class TvPoster extends StatelessWidget {
  const TvPoster({
    super.key,
    required this.item,
    this.autofocus = false,
    this.imageMaxWidth = 280,
    this.focusNode,
    this.wide = false,
  });
  final EmbyItem item;
  final bool autofocus;
  final int imageMaxWidth;
  final FocusNode? focusNode;

  /// 16:9 横版卡(继续观看行)。
  final bool wide;
  @override
  Widget build(BuildContext context) => TvCard(
    key: key,
    item: item,
    autofocus: autofocus,
    imageMaxWidth: imageMaxWidth,
    focusNode: focusNode,
    wide: wide,
  );
}

class TvGrid extends StatelessWidget {
  const TvGrid({super.key, required this.items});
  final List<EmbyItem> items;

  static int columnCount(double width) => (width / 200).floor().clamp(2, 8);

  static TvGridMetrics metricsFor(BuildContext context, double width) {
    final columns = columnCount(width);
    final cell = width / columns;
    final title = MediaShelf.lineHeightOf(
      context,
      Theme.of(context).textTheme.bodyMedium,
    );
    return TvGridMetrics(
      columns: columns,
      imageMaxWidth: catalogPosterMaxWidth(
        cell,
        MediaQuery.devicePixelRatioOf(context),
      ),
      childAspectRatio: cell / (cell * 1.35 + 8 + title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = metricsFor(context, MediaQuery.sizeOf(context).width);
    return TvPosterSliver(items: items, metrics: metrics);
  }
}

class TvGridMetrics {
  const TvGridMetrics({
    required this.columns,
    required this.imageMaxWidth,
    required this.childAspectRatio,
  });

  final int columns;
  final int imageMaxWidth;
  final double childAspectRatio;
}

/// 只构建视口内的海报。列数在滚动视图外算好，避免每滚一帧重建整屏。
class TvPosterSliver extends StatelessWidget {
  const TvPosterSliver({super.key, required this.items, required this.metrics});

  final List<EmbyItem> items;
  final TvGridMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: metrics.columns,
        childAspectRatio: metrics.childAspectRatio,
      ),
      delegate: _TvPosterDelegate(items: items, metrics: metrics),
    );
  }
}

class _TvPosterDelegate extends SliverChildBuilderDelegate {
  _TvPosterDelegate({required this.items, required TvGridMetrics metrics})
    : super(
        (context, index) => TvPoster(
          key: ValueKey(items[index].id),
          item: items[index],
          imageMaxWidth: metrics.imageMaxWidth,
        ),
        childCount: items.length,
        addAutomaticKeepAlives: false,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final index = items.indexWhere((item) => item.id == key.value);
          return index < 0 ? null : index;
        },
      );

  final List<EmbyItem> items;

  @override
  bool shouldRebuild(covariant _TvPosterDelegate oldDelegate) {
    return !identical(oldDelegate.items, items);
  }
}

/// Keep navigation keys out of EditableText until the user deliberately edits.
class TvInput extends StatelessWidget {
  const TvInput({
    super.key,
    required this.label,
    required this.controller,
    this.autofocus = false,
    this.secret = false,
    this.pill = false,
    this.leading,
    this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final bool autofocus, secret;

  /// 胶囊形态(搜索条)。
  final bool pill;

  /// 可选前导图标。
  final Widget? leading;
  final VoidCallback? onSubmitted;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => TvAction(
      autofocus: autofocus,
      pill: pill,
      leading: leading,
      onPressed: () async {
        await showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (context) => AlertDialog(
            title: Text(label),
            content: SizedBox(
              width: AppViewport.fit(
                600,
                MediaQuery.sizeOf(context).width - 96,
                MediaQuery.sizeOf(context),
              ),
              child: TextField(
                key: const Key('tv-input-editor'),
                controller: controller,
                autofocus: true,
                obscureText: secret,
                autocorrect: false,
                enableSuggestions: !secret,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => Navigator.pop(context),
              ),
            ),
            actions: [
              TvAction(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context).mobileBack),
              ),
            ],
          ),
        );
        onSubmitted?.call();
      },
      child: Text(
        '$label  ${secret ? '•' * value.text.length : value.text}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// TV 沉浸 hero 遮罩:顶带保护导航/标题,左侧文字带托底白字,底带溶入页面。
///
/// hero 文字恒为白色,遮罩恒为黑色系,与主题明暗无关;alpha 全部经
/// [AppScrim.resolve],系统要求高对比度时抬到不低于 [AppScrim.highContrastAlpha]。
class TvHeroScrim extends StatelessWidget {
  const TvHeroScrim({
    super.key,
    this.top = true,
    this.leading = true,
    this.bottom = true,
  });

  /// 顶带:保护浮于 hero 之上的导航与标题。
  final bool top;

  /// 左侧文字带:hero 底部左对齐标题区的横向渐变。
  final bool leading;

  /// 底带:向页面底色溶入。
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (top)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height:
                AppScrim.topBandHeight *
                AppViewport.scaleOf(MediaQuery.sizeOf(context)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.top),
                    ),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        if (leading)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.textStart),
                    ),
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.textMid),
                    ),
                    Colors.black.withValues(alpha: 0),
                  ],
                  stops: AppScrim.textStops,
                ),
              ),
            ),
          ),
        if (bottom)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.bottomMid),
                    ),
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.bottomMid),
                    ),
                  ],
                  stops: AppScrim.bottomStops,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
