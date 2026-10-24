import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/media_server/models.dart';

/// 季切换器的呈现端。缺省按 [AppUiTheme] 的 tv/phone 标志推断。
enum SeasonSwitcherPlatform { desktop, phone, tv }

/// 自适应季切换器。
///
/// - 只有一季(或没有季)时不渲染。
/// - 所有季标签单行排开放得下时,直接显示分段标签,每个标签的 key 为
///   [CatalogKeys.seasonTab](可由 [tabKey] 改写)。
/// - 放不下时折叠为「当前季 ˅」入口(key [CatalogKeys.seasonPicker]):桌面弹出
///   锚定菜单,手机弹出底部单选表,TV 弹出焦点可达的选择列表;每个选项的 key
///   为 [CatalogKeys.seasonOption]。
/// - 长季名单行显示并省略,完整名称作为 tooltip 与语义 label。
class SeasonSwitcher extends StatelessWidget {
  const SeasonSwitcher({
    super.key,
    required this.seasons,
    required this.currentId,
    required this.onSelected,
    this.platform,
    this.maxWidth,
    this.tabKey,
    this.focusNodeFor,
    this.pickerFocusNode,
  });

  final List<MediaItem> seasons;
  final String? currentId;
  final ValueChanged<String>? onSelected;

  /// 呈现端;缺省按主题推断。
  final SeasonSwitcherPlatform? platform;

  /// 标签行可用的最大宽度;与父约束取较小者。
  final double? maxWidth;

  /// 标签 key;缺省 [CatalogKeys.seasonTab]。
  final Key Function(String id)? tabKey;

  /// TV 标签的焦点节点(如页面焦点表里的 `season:<id>`)。
  final FocusNode? Function(String id)? focusNodeFor;

  /// TV 折叠入口的焦点节点。
  final FocusNode? pickerFocusNode;

  /// 单个季标签的最大文字宽度(TV 再乘画布倍率)。超出时省略并带 tooltip。
  static const double maxLabelWidth = 200;

  /// 标签之间的间隔(TV 再乘画布倍率)。
  static const double gap = AppSpacing.xs;

  /// 桌面/手机标签按钮面高度。
  static const double tabExtent = 36;

  static SeasonSwitcherPlatform platformOf(BuildContext context) {
    final theme = AppUiTheme.of(context);
    if (theme.tv) return SeasonSwitcherPlatform.tv;
    if (theme.phone) return SeasonSwitcherPlatform.phone;
    return SeasonSwitcherPlatform.desktop;
  }

  MediaItem get _current {
    for (final season in seasons) {
      if (season.id == currentId) return season;
    }
    return seasons.first;
  }

  @override
  Widget build(BuildContext context) {
    if (seasons.length < 2) return const SizedBox.shrink();
    final resolved = platform ?? platformOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var available = constraints.maxWidth;
        if (maxWidth != null && maxWidth! < available) available = maxWidth!;
        final metrics = _TabMetrics.of(context, resolved);
        final groupInset = resolved == SeasonSwitcherPlatform.tv ? 0.0 : 6.0;
        if (metrics.rowWidth(seasons) + groupInset <= available) {
          return _tabs(context, resolved, metrics);
        }
        return _picker(context, resolved, metrics);
      },
    );
  }

  Widget _tabs(
    BuildContext context,
    SeasonSwitcherPlatform resolved,
    _TabMetrics metrics,
  ) {
    final children = <Widget>[];
    for (var i = 0; i < seasons.length; i++) {
      final season = seasons[i];
      if (i > 0) children.add(SizedBox(width: metrics.gap));
      final key = (tabKey ?? CatalogKeys.seasonTab)(season.id);
      final selected = season.id == currentId;
      final truncated = metrics.labelWidth(season.name) > metrics.maxLabel;
      final onPressed = onSelected == null
          ? null
          : () => onSelected!(season.id);
      children.add(
        resolved == SeasonSwitcherPlatform.tv
            ? _TvSeasonTab(
                key: key,
                name: season.name,
                selected: selected,
                maxLabel: metrics.maxLabel,
                focusNode: focusNodeFor?.call(season.id),
                onPressed: onPressed,
              )
            : _SeasonTab(
                key: key,
                name: season.name,
                selected: selected,
                truncated: truncated,
                maxLabel: metrics.maxLabel,
                onPressed: onPressed,
              ),
      );
    }
    final row = Row(mainAxisSize: MainAxisSize.min, children: children);
    if (resolved == SeasonSwitcherPlatform.tv) return row;
    final scheme = AppUiTheme.of(context).colorScheme;
    return Container(
      key: const Key('season-switcher-tabs'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(AppRadii.md + 3),
        border: Border.all(color: AppEdge.of(scheme.brightness)),
      ),
      child: row,
    );
  }

  Widget _picker(
    BuildContext context,
    SeasonSwitcherPlatform resolved,
    _TabMetrics metrics,
  ) {
    final current = _current;
    final l = AppLocalizations.of(context);
    final semantic = l.seasonSwitcherCurrent(current.name);
    if (resolved == SeasonSwitcherPlatform.tv) {
      return Semantics(
        label: semantic,
        button: true,
        excludeSemantics: true,
        child: TvAction(
          key: CatalogKeys.seasonPicker,
          variant: TvActionVariant.ghost,
          selected: true,
          focusNode: pickerFocusNode,
          trailing: const Icon(CupertinoIcons.chevron_down),
          onPressed: onSelected == null ? null : () => _pickTv(context),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxLabel),
            child: Text(
              current.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }
    final truncated = metrics.labelWidth(current.name) > metrics.maxLabel;
    return _SeasonTab(
      key: CatalogKeys.seasonPicker,
      name: current.name,
      selected: true,
      truncated: truncated,
      maxLabel: metrics.maxLabel,
      semanticLabel: semantic,
      trailing: CupertinoIcons.chevron_down,
      onPressed: onSelected == null
          ? null
          : resolved == SeasonSwitcherPlatform.phone
          ? () => _pickPhone(context)
          : null,
      onPressedAt:
          onSelected == null || resolved != SeasonSwitcherPlatform.desktop
          ? null
          : (anchor) => _pickDesktop(context, anchor),
    );
  }

  Future<void> _pickDesktop(BuildContext context, RelativeRect anchor) async {
    final picked = await showAppMenu<String>(
      context: context,
      position: anchor,
      selected: currentId,
      title: AppLocalizations.of(context).seasonSwitcherTitle,
      constraints: const BoxConstraints(maxWidth: 280),
      items: [
        for (final season in seasons)
          AppMenuEntry(
            key: CatalogKeys.seasonOption(season.id),
            value: season.id,
            child: Text(
              season.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
    if (picked != null) onSelected?.call(picked);
  }

  Future<void> _pickPhone(BuildContext context) async {
    final picked = await showAppModalSheet<String>(
      context: context,
      builder: (context) =>
          _SeasonSheet(seasons: seasons, currentId: currentId),
    );
    if (picked != null) onSelected?.call(picked);
  }

  Future<void> _pickTv(BuildContext context) async {
    final picked = await showAppDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (context) {
        final s = TvDesign.scaleOf(context);
        return AppDialog(
          maxWidth: 420 * s,
          title: Text(AppLocalizations.of(context).seasonSwitcherTitle),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: SingleChildScrollView(
              child: Column(
                key: const Key('season-switcher-tv-list'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final season in seasons)
                    Padding(
                      padding: EdgeInsets.only(bottom: 4 * s),
                      child: TvChoiceTile(
                        actionKey: CatalogKeys.seasonOption(season.id),
                        label: season.name,
                        selected: season.id == currentId,
                        autofocus: season.id == currentId,
                        onPressed: () => Navigator.of(context).pop(season.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) onSelected?.call(picked);
  }
}

/// 标签尺寸换算:按实际字体与系统字号缩放测量季名宽度。
class _TabMetrics {
  _TabMetrics({
    required this.style,
    required this.textScaler,
    required this.padding,
    required this.minWidth,
    required this.maxLabel,
    required this.gap,
  });

  factory _TabMetrics.of(
    BuildContext context,
    SeasonSwitcherPlatform platform,
  ) {
    final theme = AppUiTheme.of(context);
    final style = (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
    );
    final scaler = MediaQuery.textScalerOf(context);
    if (platform == SeasonSwitcherPlatform.tv) {
      final s = TvDesign.scaleOf(context);
      return _TabMetrics(
        style: style,
        textScaler: scaler,
        padding: 12 * s,
        minWidth: 0,
        maxLabel: SeasonSwitcher.maxLabelWidth * s,
        gap: AppSpacing.xxs * s,
      );
    }
    return _TabMetrics(
      style: style,
      textScaler: scaler,
      padding: 16,
      minWidth: 64,
      maxLabel: SeasonSwitcher.maxLabelWidth,
      gap: SeasonSwitcher.gap,
    );
  }

  final TextStyle style;
  final TextScaler textScaler;
  final double padding, minWidth, maxLabel, gap;

  double labelWidth(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  double tabWidth(String text) {
    var label = labelWidth(text);
    if (label > maxLabel) label = maxLabel;
    final width = label + padding * 2;
    return width < minWidth ? minWidth : width;
  }

  double rowWidth(List<MediaItem> seasons) {
    var total = 0.0;
    for (final season in seasons) {
      total += tabWidth(season.name);
    }
    return total + gap * (seasons.length - 1);
  }
}

/// 桌面与手机的季标签:选中为 [AppSelectionDecoration] 同款实底加描边,
/// 未选为安静表面与发丝边。也用作折叠后的「当前季 ˅」入口。
class _SeasonTab extends StatelessWidget {
  const _SeasonTab({
    super.key,
    required this.name,
    required this.selected,
    required this.truncated,
    required this.maxLabel,
    this.semanticLabel,
    this.trailing,
    this.onPressed,
    this.onPressedAt,
  });

  final String name;
  final bool selected, truncated;
  final double maxLabel;
  final String? semanticLabel;
  final IconData? trailing;
  final VoidCallback? onPressed;

  /// 需要锚点的点击(桌面菜单从按钮下沿展开)。
  final ValueChanged<RelativeRect>? onPressedAt;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final label = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxLabel),
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final button = Builder(
      builder: (context) => AppButton(
        selected: selected,
        variant: AppButtonVariant.outlined,
        semanticLabel: semanticLabel ?? name,
        onPressed: onPressedAt != null
            ? () {
                final box = context.findRenderObject()! as RenderBox;
                final origin = box.localToGlobal(Offset(0, box.size.height));
                onPressedAt!(RelativeRect.fromLTRB(origin.dx, origin.dy, 0, 0));
              }
            : onPressed,
        style: AppButtonStyle(
          faceExtent: SeasonSwitcher.tabExtent,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          backgroundColor: selected
              ? colors.primaryContainer
              : trailing != null
              ? colors.surfaceContainerLow
              : AppInk.transparent,
          foregroundColor: selected
              ? colors.onPrimaryContainer
              : colors.onSurface,
          side: selected
              ? BorderSide(
                  color: colors.primary,
                  width: AppSelectionDecoration.borderWidth,
                )
              : BorderSide(
                  color: trailing != null
                      ? AppEdge.of(colors.brightness)
                      : AppInk.transparent,
                ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: theme.textTheme.labelLarge!.copyWith(
            fontWeight: selected || trailing != null
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
        child: ExcludeSemantics(
          child: trailing == null
              ? label
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: label),
                    const SizedBox(width: 6),
                    Icon(trailing, size: 14, color: colors.onSurfaceVariant),
                  ],
                ),
        ),
      ),
    );
    return truncated ? AppTooltip(message: name, child: button) : button;
  }
}

/// TV 季标签:无底文字按钮,选中为浅底加半粗,聚焦整块反相。
class _TvSeasonTab extends StatelessWidget {
  const _TvSeasonTab({
    super.key,
    required this.name,
    required this.selected,
    required this.maxLabel,
    this.focusNode,
    this.onPressed,
  });

  final String name;
  final bool selected;
  final double maxLabel;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    label: name,
    button: true,
    selected: selected,
    excludeSemantics: true,
    child: TvAction(
      variant: TvActionVariant.ghost,
      focusNode: focusNode,
      selected: selected,
      onPressed: onPressed,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabel),
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ),
  );
}

/// 手机折叠后的底部单选表。
class _SeasonSheet extends StatelessWidget {
  const _SeasonSheet({required this.seasons, required this.currentId});

  final List<MediaItem> seasons;
  final String? currentId;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      key: const Key('season-switcher-sheet'),
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
            AppSpacing.xs,
          ),
          child: Text(
            AppLocalizations.of(context).seasonSwitcherTitle,
            style: theme.textTheme.titleMedium,
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xs,
              0,
              AppSpacing.xs,
              AppSpacing.md,
            ),
            children: [
              for (final season in seasons)
                Semantics(
                  key: CatalogKeys.seasonOption(season.id),
                  inMutuallyExclusiveGroup: true,
                  checked: season.id == currentId,
                  child: AppListTile(
                    minTileHeight: 48,
                    selected: season.id == currentId,
                    title: Text(
                      season.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: season.id == currentId
                          ? TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                    trailing: season.id == currentId
                        ? Icon(
                            AppIcons.check,
                            fill: AppIcons.filled,
                            size: 20,
                            color: scheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(season.id),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
