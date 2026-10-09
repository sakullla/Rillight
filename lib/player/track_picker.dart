import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/reveal_selected.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';

/// 轨道/片源选项超过该数量时,选择器顶部显示搜索框。
/// 低于阈值保持原有平铺,不为少数选项引入额外输入负担。
const int kTrackPickerSearchThreshold = 10;

/// 选择器搜索框的稳定 key:UI 捕获与组件测试据此输入过滤词。
const Key kTrackPickerSearchKey = Key('track-picker-search');

/// 轨道辅助行:内嵌/外挂 + 编码 + 默认标记,如「内嵌 · SUBRIP · 默认」。
String trackMetaLabel(AppLocalizations l, MediaStreamInfo track) {
  final parts = <String>[
    if (track.isSubtitle)
      track.isExternal ? l.subtitleMetaExternal : l.subtitleMetaEmbedded,
    if ((track.codec ?? '').isNotEmpty) track.codec!.toUpperCase(),
    if (track.isDefault) l.trackMetaDefault,
  ];
  return parts.join(' · ');
}

/// 按过滤词保留选项:标签、语言码、编码等已拼进 [searchText]。
List<T> filterPickerOptions<T>(
  List<T> options,
  String query,
  String Function(T) searchText,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return options;
  return [
    for (final option in options)
      if (searchText(option).toLowerCase().contains(needle)) option,
  ];
}

/// 选择器一条选项:标题控件 + 参与搜索的文本 + 选中态 + 动作。
class TrackPickerOption {
  const TrackPickerOption({
    required this.title,
    required this.searchText,
    required this.selected,
    this.key,
    this.leading,
    this.subtitle,
    this.trailing,
    this.reveal = true,
    this.onTap,
  });

  /// 选项行上挂的 key(捕获/测试定位,如 `mobile-source-<id>`)。
  final Key? key;

  final Widget title;
  final String searchText;
  final bool selected;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;

  /// 是否显示选中揭示动画;手机面板用 leading 单选图标时关掉。
  final bool reveal;
  final VoidCallback? onTap;
}

/// 行构建签名:桌面默认用 [_PickerTile];手机端换成带单选图标的磁贴。
typedef TrackPickerTileBuilder =
    Widget Function(BuildContext context, TrackPickerOption option);

/// 可搜索的选项列表:超阈值显示搜索框,列表懒构建且有界,
/// 直接放进 Expanded/Flexible 等带高度约束的槽位。
class TrackPickerList extends StatefulWidget {
  const TrackPickerList({
    super.key,
    required this.options,
    this.searchThreshold = kTrackPickerSearchThreshold,
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
    this.tileBuilder,
  });

  final List<TrackPickerOption> options;
  final int searchThreshold;
  final EdgeInsetsGeometry padding;

  /// 嵌套在外层滚动视图(如手机设置面板)里时置 true:
  /// 列表禁用自身滚动并一次性展开,滚动交给外层。
  final bool shrinkWrap;
  final TrackPickerTileBuilder? tileBuilder;

  @override
  State<TrackPickerList> createState() => _TrackPickerListState();
}

class _TrackPickerListState extends State<TrackPickerList> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final GlobalKey _selectedKey = GlobalKey();
  bool _revealPending = false;

  @override
  void initState() {
    super.initState();
    // 懒构建下选中项可能尚未挂载:先按视口高度步进滚动,
    // 待其进入视口再由 ensureVisible 精确定位。手动滚动后不重复揭示。
    _revealPending =
        !widget.shrinkWrap && widget.options.any((o) => o.selected);
    if (_revealPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _revealSelected() {
    if (!mounted || !_revealPending) return;
    final selected = _selectedKey.currentContext;
    if (selected != null) {
      _revealPending = false;
      Scrollable.ensureVisible(selected, alignment: .5);
      return;
    }
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - .5) {
      _revealPending = false;
      return;
    }
    _scroll.jumpTo(
      math.min(
        position.pixels + position.viewportDimension,
        position.maxScrollExtent,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final filtered = filterPickerOptions(
      widget.options,
      _search.text,
      (option) => option.searchText,
    );
    final list = filtered.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                l.searchNoResults,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        : ListView.builder(
            // 面板内可能并存多个滚动视图,禁用 PrimaryScrollController 继承,
            // 避免 Scrollbar 断言「attached to more than one ScrollPosition」。
            primary: false,
            controller: widget.shrinkWrap ? null : _scroll,
            padding: widget.padding,
            shrinkWrap: widget.shrinkWrap,
            physics: widget.shrinkWrap
                ? const NeverScrollableScrollPhysics()
                : null,
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final option = filtered[index];
              final builder = widget.tileBuilder;
              final tile = builder == null
                  ? _PickerTile(option: option)
                  : builder(context, option);
              return option.selected
                  ? KeyedSubtree(key: _selectedKey, child: tile)
                  : tile;
            },
          );
    return Column(
      mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.options.length > widget.searchThreshold)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TrackPickerSearchField(
              controller: _search,
              onChanged: (_) => setState(() {}),
            ),
          ),
        if (widget.shrinkWrap) list else Expanded(child: list),
      ],
    );
  }
}

/// 紧凑搜索框:前缀放大镜 + 可清空,宽度和播放器面板一致。
class TrackPickerSearchField extends StatelessWidget {
  const TrackPickerSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return TextField(
      key: kTrackPickerSearchKey,
      controller: controller,
      textInputAction: TextInputAction.search,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        isDense: true,
        hintText: l.filterSearchOptions,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox(width: 40)
              : IconButton(
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).deleteButtonTooltip,
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      onChanged: onChanged,
    );
  }
}

/// 与播放设置菜单同款的选择行:选中高亮 + 右侧勾。
class _PickerTile extends StatelessWidget {
  const _PickerTile({required this.option});

  final TrackPickerOption option;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = option.selected;
    return Padding(
      key: option.key == null ? null : ValueKey('option-shell-${option.key}'),
      padding: const EdgeInsets.only(bottom: 4),
      child: RevealSelected(
        selected: selected && option.reveal,
        child: ListTile(
          key: option.key,
          selected: selected,
          selectedTileColor: scheme.surfaceBright,
          selectedColor: scheme.onSurface,
          iconColor: scheme.onSurfaceVariant,
          textColor: scheme.onSurface,
          shape: const StadiumBorder(),
          minTileHeight: 44,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: option.leading,
          title: option.title,
          subtitle: option.subtitle,
          trailing:
              option.trailing ??
              (selected
                  ? Icon(Icons.check_rounded, size: 18, color: scheme.onSurface)
                  : const SizedBox(width: 18)),
          onTap: option.onTap,
        ),
      ),
    );
  }
}

/// 桌面播放条上的字幕菜单:超过十条自动带搜索,辅助行标出
/// 内嵌/外挂与编码,当前选择高亮;打开时钉住控制栏不淡出。
class SubtitleTrackMenu extends StatefulWidget {
  const SubtitleTrackMenu({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SubtitleTrackMenu> createState() => _SubtitleTrackMenuState();
}

class _SubtitleTrackMenuState extends State<SubtitleTrackMenu> {
  final MenuController _menu = MenuController();
  final FocusNode _buttonFocus = FocusNode();
  final FocusScopeNode _panelFocus = FocusScopeNode();

  @override
  void didUpdateWidget(SubtitleTrackMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    scheduleMicrotask(
      () => oldWidget.controller.setControlsPinned(false, owner: _menu),
    );
    if (_menu.isOpen) {
      widget.controller.setControlsPinned(true, owner: _menu);
    }
  }

  @override
  void dispose() {
    _buttonFocus.dispose();
    _panelFocus.dispose();
    final controller = widget.controller;
    scheduleMicrotask(() => controller.setControlsPinned(false, owner: _menu));
    super.dispose();
  }

  void _select(int? index) {
    widget.controller.setSubtitle(index);
    _menu.close();
    _buttonFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final l = AppLocalizations.of(context);
    final c = widget.controller;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      onOpen: () {
        c.setControlsPinned(true, owner: _menu);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _menu.isOpen) _panelFocus.requestFocus();
        });
      },
      onClose: () => c.setControlsPinned(false, owner: _menu),
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(16),
        shadowColor: WidgetStatePropertyAll(scheme.scrim.withValues(alpha: .5)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.xl),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      builder: (context, menu, _) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => IconButton(
          key: PlayerKeys.subtitle,
          focusNode: _buttonFocus,
          tooltip: l.subtitleTrack,
          color: scheme.onSurface,
          icon: Icon(
            c.subtitleStreamIndex == null
                ? Icons.closed_caption_off_rounded
                : Icons.closed_caption_rounded,
          ),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
      menuChildren: [
        ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final width = math.min(
              AppViewport.dp(420, screen),
              math.max(280.0, screen.width - 48),
            );
            final height = math.min(
              AppViewport.dp(520, screen),
              math.max(240.0, screen.height - 160),
            );
            return SizedBox(
              key: const Key('player-subtitle-panel'),
              width: width,
              height: height,
              child: FocusScope(
                node: _panelFocus,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    _menu.close();
                    _buttonFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: _panel(context, c.selectableSubtitleTracks),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _panel(BuildContext context, List<MediaStreamInfo> tracks) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.controller;
    final enabled = !c.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.subtitleTrack,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (tracks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    l.trackPickerCount(tracks.length),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              IconButton(
                key: const Key('player-subtitle-close'),
                onPressed: _menu.close,
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
        Divider(height: 2, color: scheme.outlineVariant.withValues(alpha: .7)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TrackPickerList(
              options: [
                TrackPickerOption(
                  title: Text(
                    l.subtitleOff,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  searchText: l.subtitleOff,
                  selected: c.subtitleStreamIndex == null,
                  onTap: enabled ? () => _select(null) : null,
                ),
                for (final track in tracks)
                  TrackPickerOption(
                    title: Text(
                      track.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _meta(theme, track),
                    searchText:
                        '${track.label} ${track.language ?? ''} '
                        '${track.codec ?? ''} ${track.displayTitle ?? ''}',
                    selected: track.index == c.subtitleStreamIndex,
                    onTap: enabled ? () => _select(track.index) : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget? _meta(ThemeData theme, MediaStreamInfo track) {
    final meta = trackMetaLabel(AppLocalizations.of(context), track);
    if (meta.isEmpty) return null;
    return Text(
      meta,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: .68),
      ),
    );
  }
}
