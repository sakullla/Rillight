import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/ui/ui.dart';

/// 长季（番剧、日播剧、综艺）的分段规则。
///
/// 一季几十集时整列滚动就够了；上百集时用户关心的是「第几百集附近」，
/// 所以列表上方给一行可直接点的分段（1–50、51–100…），不必先找「选集」。
abstract final class EpisodeRanges {
  /// 超过这个集数才出现分段条；两屏以内的季不需要。
  static const int minTotal = 60;

  static bool show(int total) => total > minTotal;

  /// 每段集数。上千集时 50 一段会有 20 多枚标签，改为 100 一段。
  static int sizeFor(int total) => total > 1000 ? 100 : 50;

  static List<EpisodeRange> of(int total) {
    final size = sizeFor(total);
    return [
      for (var start = 1; start <= total; start += size)
        EpisodeRange(start, math.min(start + size - 1, total)),
    ];
  }

  /// 集号所在分段的下标；越界时夹在首尾。
  static int indexOf(int total, int number) {
    final count = (total / sizeFor(total)).ceil();
    if (count <= 0) return 0;
    return ((number - 1) ~/ sizeFor(total)).clamp(0, count - 1);
  }
}

/// 一个分段：起止集号（含）。
class EpisodeRange {
  const EpisodeRange(this.start, this.end);

  final int start;
  final int end;
}

/// 分段条：一行可横滑的紧凑分段标签，当前段为实底。
///
/// 比季标签低一档（32 高、等宽数字），读作季的下一级。当前段变化时自动
/// 滚到可见处；竖直滚轮交回外层页面，不会卡在这一行上。
class EpisodeRangeBar extends StatefulWidget {
  const EpisodeRangeBar({
    super.key,
    required this.total,
    required this.activeNumber,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  /// 本季集数（服务器总数）。
  final int total;

  /// 当前所在的集号，决定哪一段高亮；为空时高亮第一段。
  final int? activeNumber;

  /// 点选分段，参数是该段的起始集号。
  final ValueChanged<int> onSelected;
  final EdgeInsetsGeometry padding;

  static const barKey = Key('episode-range-bar');
  static Key chipKey(int start) => Key('episode-range-$start');

  static const double chipExtent = 32;
  static const double gap = AppSpacing.xs;

  @override
  State<EpisodeRangeBar> createState() => _EpisodeRangeBarState();
}

class _EpisodeRangeBarState extends State<EpisodeRangeBar> {
  final _scroll = ScrollController();
  double _chipWidth = 0;

  int get _activeIndex =>
      EpisodeRanges.indexOf(widget.total, widget.activeNumber ?? 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _reveal(animate: false),
    );
  }

  @override
  void didUpdateWidget(EpisodeRangeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = EpisodeRanges.indexOf(
      oldWidget.total,
      oldWidget.activeNumber ?? 1,
    );
    if (before != _activeIndex || oldWidget.total != widget.total) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 当前段滚到可见范围内（居中偏左），已经可见时不动。
  void _reveal({bool animate = true}) {
    if (!mounted || !_scroll.hasClients || _chipWidth <= 0) return;
    final position = _scroll.position;
    final slot = _chipWidth + EpisodeRangeBar.gap;
    final left = _activeIndex * slot;
    final right = left + _chipWidth;
    final view = position.viewportDimension;
    if (left >= position.pixels && right <= position.pixels + view) return;
    final target = (left - (view - _chipWidth) / 3).clamp(
      0.0,
      position.maxScrollExtent,
    );
    final duration = AppMotion.durationOf(context);
    if (!animate || duration == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: duration, curve: AppMotion.standard);
    }
  }

  void _forwardVerticalWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) return;
    final vertical = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (vertical == null) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final dy = (resolved as PointerScrollEvent).scrollDelta.dy;
      final position = vertical.position;
      position.jumpTo(
        (position.pixels + dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final ranges = EpisodeRanges.of(widget.total);
    final style = (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // 所有分段等宽：按最长的末段测一次，滚动定位只需乘法。
    final last = ranges.last;
    final painter = TextPainter(
      text: TextSpan(
        text: l.episodeRangeLabel(last.start, last.end),
        style: style,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    _chipWidth = (painter.width + 28).ceilToDouble();
    final labelHeight = painter.height;
    painter.dispose();
    final extent = math.max(EpisodeRangeBar.chipExtent, labelHeight + 12);
    final active = _activeIndex;
    return Semantics(
      container: true,
      label: l.episodeRangesTitle,
      child: Listener(
        onPointerSignal: _forwardVerticalWheel,
        child: SizedBox(
          key: EpisodeRangeBar.barKey,
          height: extent,
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: ranges.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: EpisodeRangeBar.gap),
            itemBuilder: (context, index) {
              final range = ranges[index];
              final selected = index == active;
              return SizedBox(
                width: _chipWidth,
                child: AppButton(
                  key: EpisodeRangeBar.chipKey(range.start),
                  selected: selected,
                  variant: AppButtonVariant.outlined,
                  semanticLabel: l.episodeRangeSemantic(range.start, range.end),
                  onPressed: () => widget.onSelected(range.start),
                  style: AppButtonStyle(
                    minimumSize: Size(_chipWidth, extent),
                    padding: EdgeInsets.symmetric(
                      vertical: ((extent - labelHeight) / 2).clamp(4.0, 12.0),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    backgroundColor: selected
                        ? colors.primaryContainer
                        : colors.surfaceContainerLow.withValues(alpha: .58),
                    foregroundColor: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                    side: BorderSide(
                      color: selected
                          ? colors.primary.withValues(alpha: .7)
                          : AppEdge.of(colors.brightness),
                    ),
                    textStyle: style.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  child: ExcludeSemantics(
                    child: Text(
                      l.episodeRangeLabel(range.start, range.end),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 列表末尾的自动续载点：滚到离视口不远（[reach]）时触发一次 [onTrigger]。
///
/// 不能把「被构建」当成「快到底了」：SliverToBoxAdapter 的子节点立即构建，
/// SliverList 也总会先建第一个子节点来量高度。所以布局后按实际几何判断它离
/// 视口多远，并跟着滚动重新判断。同一个 [token]（通常是已载入条数）只触发
/// 一次；新一页到达后 token 变化，若末尾仍在附近就继续载入，直到填满视口。
class AutoLoadTrigger extends StatefulWidget {
  const AutoLoadTrigger({
    super.key,
    required this.token,
    required this.onTrigger,
    this.reach = 600,
    this.child,
  });

  final Object token;
  final VoidCallback onTrigger;

  /// 触发距离：末尾离视口远端不超过这么多逻辑像素时开始续载。
  final double reach;
  final Widget? child;

  @override
  State<AutoLoadTrigger> createState() => _AutoLoadTriggerState();
}

class _AutoLoadTriggerState extends State<AutoLoadTrigger> {
  Object? _fired;
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_check);
      _position = position;
      _position?.addListener(_check);
    }
  }

  @override
  void didUpdateWidget(AutoLoadTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) _schedule();
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted || _fired == widget.token) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final position = _position;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (position == null || viewport == null || !position.hasPixels) {
      return;
    }
    final leading = viewport.getOffsetToReveal(box, 0).offset;
    final distance = leading - position.pixels - position.viewportDimension;
    if (distance > widget.reach) return;
    _fired = widget.token;
    widget.onTrigger();
  }

  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}
