import 'dart:async';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../media_server/media_server_client.dart';
import '../media_server/media_source_format.dart';
import '../aggregation/query/aggregation_query.dart';
import '../aggregation/query/same_source_query.dart';
import '../auth/auth_scope.dart';
import '../auth/server_entry_coordinator.dart';
import '../auth/server_password_form.dart';
import '../auth/tv_server_access_page.dart';
import '../auth/server_list_store.dart';
import '../app/l10n/app_localizations.dart';
import '../app/presentation_environment.dart';
import '../app/widgets/skeleton.dart';
import '../search/search_action.dart';
import '../player/playback_runtime.dart';
import '../player/player_bindings.dart';
import '../player/player_host_command.dart';
import '../player/player_window_host.dart';
import 'detail_source_scope.dart';
import 'episode_mapping_dialog.dart';
import 'item_format.dart';
import '../app/widgets/long_press_copy.dart';

class _DialogKeyboard extends StatelessWidget {
  const _DialogKeyboard({required this.child, this.autofocus = true});
  final Widget child;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(autofocus: autofocus, skipTraversal: true, child: child),
    ),
  );
}

/// 片源选择的外框。桌面/TV 是居中对话框，手机是贴底弹层；两者结构一致：
/// 固定页眉（标题、作品与查找状态、关闭）、固定筛选条、可滚动的来源列表，
/// 以及可选页脚（TV 的关闭、密码页的取消）。
class _SourcePanel extends StatelessWidget {
  const _SourcePanel({
    required this.sheet,
    required this.title,
    required this.scroll,
    required this.content,
    this.subtitle,
    this.status,
    this.toolbar,
    this.footer,
    this.onClose,
    this.closeLabel,
  });

  final bool sheet;
  final String title;
  final ScrollController scroll;
  final Widget content;
  final Widget? subtitle;
  final Widget? status;
  final Widget? toolbar;
  final Widget? footer;

  /// 页眉右上角的关闭按钮；TV 用页脚按钮代替，以便方向键能走到。
  final VoidCallback? onClose;
  final String? closeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final hairline = Container(height: 1, color: scheme.outlineVariant);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        sheet ? 8 : 18,
        onClose == null ? 20 : 10,
        toolbar == null ? 14 : 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  key: const Key('source-selection-title'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null) ...[const SizedBox(height: 4), subtitle!],
                if (status != null) ...[const SizedBox(height: 8), status!],
              ],
            ),
          ),
          if (onClose != null)
            AppIconButton(
              key: const Key('source-selection-close'),
              icon: const Icon(AppIcons.close),
              tooltip: closeLabel,
              onPressed: onClose,
            ),
        ],
      ),
    );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sheet) ...[
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
        ],
        header,
        if (toolbar != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: toolbar),
        hairline,
        Flexible(
          child: SingleChildScrollView(
            key: const Key('source-selection-content'),
            controller: scroll,
            primary: false,
            padding: EdgeInsets.fromLTRB(
              16,
              14,
              16,
              footer == null && sheet
                  ? 16 + MediaQuery.paddingOf(context).bottom
                  : 16,
            ),
            child: content,
          ),
        ),
        if (footer != null) ...[
          hairline,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: sheet ? SafeArea(top: false, child: footer!) : footer,
          ),
        ],
      ],
    );
    if (sheet) {
      // 结果陆续到达时弹层不从一条缝跳成整屏：先占半屏，内容多了再长高。
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height * .5,
        ),
        child: body,
      );
    }
    return AppModalFrame(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: body,
      ),
    );
  }
}

/// 页眉里的查找状态：查询进行时带一个小转圈，结束后只剩文字。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.loading});
  final String text;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        if (loading) ...[
          const SizedBox(
            width: 14,
            height: 14,
            child: CupertinoActivityIndicator(radius: 7),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// 列表里的分区标题：「正在使用」「其他服务器 3」「需要解锁 2」。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.count, this.top = 0});
  final String label;
  final int? count;
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: muted,
      fontWeight: FontWeight.w600,
      letterSpacing: .2,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 4, 8),
      child: Row(
        children: [
          Text(label, style: style),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: style?.copyWith(color: muted.withValues(alpha: .7)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 查询中占位的来源骨架卡：与 [_SourceCard] 同外形（服务器标记 + 标题行 +
/// 一组版本规格），骨架到结果的切换不跳动。
class _SourceCardSkeleton extends StatelessWidget {
  const _SourceCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: AppEdge.of(scheme.brightness, strong: true),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkeletonBlock(
                    width: 40,
                    height: 40,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    animated: animate,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBlock(
                          width: 112,
                          height: 14,
                          animated: animate,
                        ),
                        const SizedBox(height: 8),
                        SkeletonBlock(
                          width: 160,
                          height: 11,
                          animated: animate,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _VersionSkeleton(animate: animate),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersionSkeleton extends StatelessWidget {
  const _VersionSkeleton({required this.animate});
  final bool animate;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SkeletonBlock(width: double.infinity, height: 12, animated: animate),
      const SizedBox(height: 8),
      Row(
        children: [
          for (final width in const [36.0, 44.0, 52.0, 60.0]) ...[
            SkeletonBlock(
              width: width,
              height: 20,
              borderRadius: BorderRadius.circular(6),
              animated: animate,
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    ],
  );
}

/// What a detail page needs to render the source selection entry in its own
/// action style. The page must put [key] on the activatable button.
class SourceSelectionActionView {
  const SourceSelectionActionView({
    required this.label,
    required this.icon,
    required this.loading,
    required this.onPressed,
    String? shortLabel,
  }) : shortLabel = shortLabel ?? label;

  static const Key key = Key('source-selection-open');

  /// 完整说明（tooltip/读屏）。
  final String label;

  /// 按钮上可见的短标签（「其他来源」）。
  final String shortLabel;
  final IconData icon;

  /// True while the dialog's origin is resolving or the dialog is open.
  final bool loading;

  /// Ignores repeated activation while [loading]; pages that must keep focus
  /// (TV) can stay enabled, others disable on [loading].
  final Future<void> Function() onPressed;
}

/// The in-content source selection entry. Each detail page places one inside
/// its own action row; availability comes from [SourceSelectionAvailability]
/// published by the source detail gate.
class SourceSelectionAction extends StatefulWidget {
  const SourceSelectionAction({super.key, this.builder});

  /// Builds the page-styled button. Defaults to an outlined pill.
  final Widget Function(BuildContext context, SourceSelectionActionView view)?
  builder;

  /// Whether an entry would render here, so pages can omit spacing or an
  /// otherwise empty action row.
  static bool availableIn(BuildContext context) {
    final availability = SourceSelectionAvailability.maybeOf(context);
    if (availability == null || !availability.available) return false;
    final origin = DetailSourceScope.maybeOf(context);
    if (origin != null) return origin.permit.isValid;
    return availability.itemId != null;
  }

  @override
  State<SourceSelectionAction> createState() => _SourceSelectionActionState();
}

class _SourceSelectionActionState extends State<SourceSelectionAction> {
  bool _loading = false;
  Future<void> _show() async {
    if (_loading) return;
    final availability = SourceSelectionAvailability.maybeOf(context);
    if (availability == null || !availability.available) return;
    final scopedOrigin = DetailSourceScope.maybeOf(context);
    final itemId = availability.itemId;
    final runtime = PlayerScope.of(context).runtime;
    if (runtime == null ||
        (scopedOrigin != null && !scopedOrigin.permit.isValid) ||
        (scopedOrigin == null && itemId == null)) {
      return;
    }
    final auth = AuthScope.of(context);
    final selected = auth.session;
    final selectedGeneration = selected == null
        ? null
        : auth.serverAccess.generation(selected.server.id);
    final route = ModalRoute.of(context);
    bool stillHere() =>
        route?.isCurrent != false &&
        (scopedOrigin != null ||
            (selected != null &&
                identical(auth.session, selected) &&
                auth.serverAccess.generation(selected.server.id) ==
                    selectedGeneration));
    // 手机端立刻弹底部弹层，预取与查询都在弹层内进行；桌面/TV 维持原对话框流程。
    if (PresentationScope.isPhoneOf(context)) {
      await _showPhoneSheet(
        runtime: runtime,
        scopedOrigin: scopedOrigin,
        itemId: itemId,
        selectedGeneration: selectedGeneration,
        stillHere: stillHere,
      );
      return;
    }
    setState(() => _loading = true);
    SameSourceQueryController? controller;
    try {
      final origin =
          scopedOrigin ??
          await runtime.resolve(
            PlayerOpenRequest(
              itemId: itemId!,
              accessGeneration: selectedGeneration,
            ),
          );
      if (!mounted || !stillHere() || !origin.permit.isValid) return;
      final MediaItem dto =
          origin.resolvedItem ??
          await origin.permit.dispatch((c) => c.getItem(origin.source.itemId));
      var current = dto;
      EpisodeSource? episode;
      if (current.isEpisode && current.seriesId != null) {
        episode = EpisodeSource.fromMediaItem(origin.source, current);
        current = await origin.permit.dispatch(
          (c) => c.getItem(current.seriesId!),
        );
      }
      if (!mounted || !stillHere() || !origin.permit.isValid) return;
      final item = QueryItem(
        SourceReference(account: origin.source.account, itemId: current.id),
        origin.libraryId,
        current,
      );
      controller = SameSourceQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      unawaited(
        controller.start(origin: item, scope: QueryScope(pageSize: 24)),
      );
      await showAppDialog<void>(
        context: context,
        // Desktop overlays must cover the shell header. TV keeps its route-local
        // navigator so the underlying D-pad focus scope becomes inactive.
        useRootNavigator: !PresentationScope.of(context).isTv,
        builder: (context) => _SourceSelectionDialog(
          controller: controller!,
          episode: episode,
          current: dto,
        ),
      );
    } catch (_) {
      if (mounted && stillHere()) {
        showAppNotice(
          context,
          AppLocalizations.of(context).sourceSelectionUnavailable,
        );
      }
    } finally {
      controller?.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 手机端：点击后立刻打开底部弹层，片源解析（resolve + getItem）移入弹层
  /// 异步执行，查询即开即走；弹层关闭后统一 dispose 控制器。
  Future<void> _showPhoneSheet({
    required PlaybackRuntime runtime,
    required PlaybackOrigin? scopedOrigin,
    required String? itemId,
    required int? selectedGeneration,
    required bool Function() stillHere,
  }) async {
    setState(() => _loading = true);
    SameSourceQueryController? controller;
    try {
      controller = SameSourceQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      await showAppModalSheet<void>(
        context: context,
        builder: (context) => _SourceSelectionDialog(
          controller: controller!,
          phoneSheet: true,
          runtime: runtime,
          scopedOrigin: scopedOrigin,
          itemId: itemId,
          selectedGeneration: selectedGeneration,
          stillHere: stillHere,
        ),
      );
    } finally {
      controller?.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SourceSelectionAction.availableIn(context)) {
      return const SizedBox.shrink();
    }
    final view = SourceSelectionActionView(
      label: AppLocalizations.of(context).sourceSelectionAction,
      shortLabel: AppLocalizations.of(context).sourceSelectionShort,
      icon: AppIcons.otherSources,
      loading: _loading,
      onPressed: _show,
    );
    final builder = widget.builder;
    if (builder != null) return builder(context, view);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    // A sibling secondary action in the page's own action row: no overlay
    // shadow, no floating surface.
    return AppButton.icon(
      key: SourceSelectionActionView.key,
      onPressed: view.loading ? null : view.onPressed,
      icon: Icon(view.icon, size: 18),
      label: Text(view.label),
      variant: AppButtonVariant.outlined,
      style: AppButtonStyle(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.22)),
        textStyle: theme.textTheme.labelLarge,
      ),
    );
  }
}

class _SourceSelectionDialog extends StatefulWidget {
  const _SourceSelectionDialog({
    required this.controller,
    this.episode,
    this.current,
    this.phoneSheet = false,
    this.runtime,
    this.scopedOrigin,
    this.itemId,
    this.selectedGeneration,
    this.stillHere,
  });
  final SameSourceQueryController controller;
  final EpisodeSource? episode;

  /// The item being watched (movie or the episode itself) with its versions,
  /// shown as the reference row.
  final MediaItem? current;

  /// 手机端走底部弹层：入口点击后立刻弹层，预取在弹层内完成，此时
  /// [runtime]/[scopedOrigin]/[itemId]/[selectedGeneration]/[stillHere]
  /// 由入口在弹层外捕获传入（弹层挂在根导航上，读不到页面级 scope）。
  final bool phoneSheet;
  final PlaybackRuntime? runtime;
  final PlaybackOrigin? scopedOrigin;
  final String? itemId;
  final int? selectedGeneration;
  final bool Function()? stillHere;

  @override
  State<_SourceSelectionDialog> createState() => _SourceSelectionDialogState();
}

class _SourceSelectionDialogState extends State<_SourceSelectionDialog> {
  SameSourceQueryController get controller => widget.controller;
  EpisodeSource? get episode => widget.episode ?? _resolvedEpisode;
  EpisodeSource? _resolvedEpisode;
  MediaItem? get current => widget.current ?? _resolvedCurrent;
  MediaItem? _resolvedCurrent;
  Map<SourceReference, EpisodeComparison> _episodeIndex = const {};
  SavedServer? _passwordTarget;
  ServerEntryTicket? _pendingEntry;
  bool _busy = false;
  bool _resolved = false;
  String? _error;
  final Map<SourceReference, String> _rowErrors = {};
  String? _resolution;
  String? _range;
  String? _video;
  String? _subtitle;
  String? _audio;
  final ScrollController _scroll = ScrollController();
  final Set<SourceReference> _lookupStarted = {};

  bool get _sheetResolving => widget.phoneSheet && !_resolved;

  @override
  void initState() {
    super.initState();
    _resolved = !widget.phoneSheet;
    controller.addListener(_matchCurrentEpisode);
    _matchCurrentEpisode();
    if (widget.phoneSheet) unawaited(_resolveAndStart());
  }

  /// 弹层内预取：解析来源 → 取条目（单集再取剧集）→ 启动跨服务器查询。
  /// 全程骨架卡占位，失败才关闭弹层并提示。
  Future<void> _resolveAndStart() async {
    final runtime = widget.runtime;
    final stillHere = widget.stillHere;
    if (runtime == null || stillHere == null) return;
    try {
      final origin =
          widget.scopedOrigin ??
          await runtime.resolve(
            PlayerOpenRequest(
              itemId: widget.itemId!,
              accessGeneration: widget.selectedGeneration,
            ),
          );
      if (!mounted || !stillHere() || !origin.permit.isValid) {
        _closeAfterFrame();
        return;
      }
      final MediaItem dto =
          origin.resolvedItem ??
          await origin.permit.dispatch((c) => c.getItem(origin.source.itemId));
      var current = dto;
      EpisodeSource? episode;
      if (current.isEpisode && current.seriesId != null) {
        episode = EpisodeSource.fromMediaItem(origin.source, current);
        current = await origin.permit.dispatch(
          (c) => c.getItem(current.seriesId!),
        );
      }
      if (!mounted || !stillHere() || !origin.permit.isValid) {
        _closeAfterFrame();
        return;
      }
      _resolvedEpisode = episode;
      _resolvedCurrent = dto;
      final item = QueryItem(
        SourceReference(account: origin.source.account, itemId: current.id),
        origin.libraryId,
        current,
      );
      unawaited(
        widget.controller.start(origin: item, scope: QueryScope(pageSize: 24)),
      );
      if (mounted) setState(() => _resolved = true);
      _matchCurrentEpisode();
    } catch (_) {
      if (mounted && stillHere()) {
        showAppNotice(
          context,
          AppLocalizations.of(context).sourceSelectionUnavailable,
        );
      }
      _closeAfterFrame();
    }
  }

  void _closeAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  bool get _filtering =>
      _resolution != null ||
      _range != null ||
      _video != null ||
      _subtitle != null ||
      _audio != null;

  void _clearFilters() {
    _resolution = null;
    _range = null;
    _video = null;
    _subtitle = null;
    _audio = null;
  }

  @override
  void dispose() {
    controller.removeListener(_matchCurrentEpisode);
    _pendingEntry?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 已经打开某一集时，对确认过的剧集直接找这一集。
  /// 外部编号优先；没有编号时按季号和集号给出可打开的一集，不再先弹核对窗。
  void _matchCurrentEpisode() {
    final current = episode;
    if (current == null) return;
    for (final comparison in controller.comparisons) {
      if (!comparison.decision.confirmed || !comparison.source.item.isSeries) {
        continue;
      }
      final reference = comparison.source.reference;
      if (!_lookupStarted.add(reference)) continue;
      unawaited(_lookupEpisode(comparison.source));
    }
  }

  Future<void> _verifyTarget(String password) async {
    final target = _passwordTarget;
    final runtime = PlayerScope.of(context).runtime;
    if (_busy || target == null || runtime == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ServerEntryTicket? entry;
    try {
      entry = await runtime.prepareSourceEntry(
        target.id,
        requestPassword: (_) async => password,
      );
      if (!mounted || controller.origin == null) {
        entry?.cancel();
        return;
      }
      if (entry == null) {
        setState(
          () => _error = runtime.registry.access.retryAt(target.id) != null
              ? AppLocalizations.of(context).serversPasswordWrong
              : AppLocalizations.of(context).sourceSelectionUnreachable,
        );
        return;
      }
      _pendingEntry = entry;
      await controller.addEntry(entry);
      if (!mounted || controller.origin == null) {
        entry.cancel();
        return;
      }
      setState(() => _passwordTarget = null);
    } catch (_) {
      entry?.cancel();
      if (mounted) {
        setState(
          () =>
              _error = AppLocalizations.of(context).sourceSelectionUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTarget(
    QueryItem item, {
    required SourceReference row,
    String? version,
  }) async {
    if (_busy || controller.origin == null) return;
    final runtime = PlayerScope.of(context).runtime;
    if (runtime == null) return;
    final auth = AuthScope.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final overlay = SearchOverlayController.maybeOf(context);
    final serverId = item.reference.account.configuredServerId;
    ServerEntryTicket? entry = controller.entryFor(serverId);
    setState(() {
      _busy = true;
      _rowErrors.remove(row);
    });
    try {
      if (entry == null && auth.session?.server.id != serverId) {
        entry = await runtime.prepareSourceEntry(serverId);
        if (entry == null) throw StateError('Target entry needs verification');
        _pendingEntry = entry;
      }
      final permit = entry == null ? controller.permitForItem(item) : null;
      // Verify the actual account, item and ancestry before any selection or
      // access publication. A comparison card alone is not navigation proof.
      final target = await runtime.resolve(
        PlayerOpenRequest(
          itemId: item.reference.itemId,
          source: item.reference,
          libraryId: item.libraryId,
          accessGeneration: entry?.generation ?? permit!.accessGeneration,
        ),
        entry: entry,
      );
      if (!mounted || controller.origin == null) {
        entry?.cancel();
        return;
      }
      if (entry != null) {
        try {
          await entry.prepareCommit();
        } catch (_) {
          entry.cancel();
          rethrow;
        }
        if (!mounted || controller.origin == null) {
          entry.cancel();
          return;
        }
        if (!entry.commit()) {
          entry.cancel();
          throw StateError('Target entry revoked');
        }
      }
      final generation = auth.serverAccess.generation(serverId);
      final destination = PlayerHostOpenItemCommand(
        itemId: target.source.itemId,
        source: target.source,
        libraryId: target.libraryId,
        accessGeneration: generation,
      );
      // Entering B can revoke the detail hosting this dialog. Navigation uses
      // the captured router, never that soon-to-be-unmounted A context.
      // Detail only: the source list never starts playback.
      if (navigator.mounted && route?.isCurrent == true) {
        // A sheet/dialog pop starts an exit animation. Waiting for the pop
        // future prevents the following route replacement from racing the
        // overlay teardown on Android.
        await navigator.maybePop();
      }
      overlay?.close();
      router.go(
        '/item/${Uri.encodeComponent(target.source.itemId)}'
        '${version == null ? '' : '?version=${Uri.encodeQueryComponent(version)}'}',
        extra: destination,
      );
    } catch (_) {
      entry?.cancel();
      if (mounted) {
        setState(() {
          _rowErrors[row] = AppLocalizations.of(context)
              .sourceSelectionUnreachable;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lookupEpisode(QueryItem target) async {
    final current = episode;
    if (current == null || controller.origin == null) return;
    try {
      await controller.lookupEpisode(
        target: target,
        episode: withConfirmedEpisodeMapping(current),
        verifiedNumberingScheme: userConfirmedEpisodeNumbering,
      );
    } on StateError {
      // The series stopped being a confirmed match while the request was queued.
    }
  }

  EpisodeComparison? _episodeResult(SourceComparison comparison) =>
      _episodeIndex[comparison.source.reference];

  bool _episodeLookupFailed(EpisodeComparison result) =>
      result.status != SourceQueryStatus.available ||
      result.lookup.status == EpisodeLookupStatus.queryFailed;

  /// The DTO whose versions represent this row: the matched episode once its
  /// details arrived, otherwise the row's own item (movie or series).
  MediaItem _versionsOf(SourceComparison comparison) {
    if (episode != null && comparison.source.item.isSeries) {
      final detail = _episodeResult(comparison)?.item;
      if (detail != null) return detail;
    }
    return comparison.source.item;
  }

  /// Confirmed series or movie. From an episode, the target is that episode
  /// once it matches. A missing episode, or one that is still unmatched,
  /// opens the series. Unconfirmed servers and a failed or unfinished
  /// episode lookup do not open.
  QueryItem? _openableItem(SourceComparison comparison) {
    if (!comparison.decision.confirmed) return null;
    final current = episode;
    if (current == null || !comparison.source.item.isSeries) {
      return comparison.source;
    }
    final result = _episodeResult(comparison);
    if (result == null ||
        result.status == SourceQueryStatus.loading ||
        _episodeLookupFailed(result)) {
      return null;
    }
    final found = result.lookup.source;
    if (result.lookup.status == EpisodeLookupStatus.confirmed &&
        found != null) {
      return QueryItem(
        found.reference,
        comparison.source.libraryId,
        MediaItem(
          id: found.reference.itemId,
          name: found.name?.trim().isNotEmpty == true
              ? found.name!
              : comparison.source.item.name,
          type: 'Episode',
          seriesId: comparison.source.reference.itemId,
          parentIndexNumber: found.season,
          indexNumber: found.episode,
        ),
      );
    }
    if (result.lookup.status == EpisodeLookupStatus.missing ||
        result.lookup.status == EpisodeLookupStatus.uncertain) {
      return comparison.source;
    }
    return null;
  }

  /// 单集模式下这一行的查找状态；找到并确认的一集不再额外提示，
  /// 直接显示那一集的版本。
  Widget? _episodeStatus(AppLocalizations l, SourceComparison comparison) {
    final current = episode;
    if (current == null ||
        !comparison.decision.confirmed ||
        !comparison.source.item.isSeries) {
      return null;
    }
    final result = _episodeResult(comparison);
    if (result == null || result.status == SourceQueryStatus.loading) {
      return _RowNote(text: l.sourceSelectionFindingEpisode, loading: true);
    }
    if (_episodeLookupFailed(result)) {
      return AppButton(
        onPressed: _busy ? null : () => _lookupEpisode(comparison.source),
        variant: AppButtonVariant.tinted,
        minimumSize: const Size(0, 36),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.refresh, size: 16),
            const SizedBox(width: 6),
            Text(l.aggregationEpisodeFailed),
          ],
        ),
      );
    }
    if (result.lookup.status == EpisodeLookupStatus.missing) {
      return _RowNote(text: l.aggregationMissingEpisode, icon: AppIcons.info);
    }
    if (result.lookup.status == EpisodeLookupStatus.uncertain) {
      return _RowNote(
        text: l.sourceSelectionFindingEpisode,
        icon: AppIcons.search,
      );
    }
    return null;
  }

  /// 卡片副标题。同名同作品不再重复片名；待核对的候选带上片名与年份，
  /// 单集模式显示对上的那一集，最后是这台服务器上的观看记录。
  String? _cardMeta(AppLocalizations l, SourceComparison comparison) {
    final item = comparison.source.item;
    final origin = controller.origin!.item;
    final parts = <String>[];
    final differs =
        item.name.trim().toLowerCase() != origin.name.trim().toLowerCase();
    if (!comparison.decision.confirmed || differs) {
      final year = item.productionYear;
      parts.add(
        year == null || comparison.decision.confirmed
            ? item.name
            : '${item.name} ($year)',
      );
    }
    DateTime? watched = item.userData.lastPlayedDate;
    if (episode != null && item.isSeries) {
      final result = _episodeResult(comparison);
      final detail = result?.item;
      final found = result?.lookup.status == EpisodeLookupStatus.confirmed
          ? result?.lookup.source
          : null;
      if (detail != null) {
        final label = continueWatchingSubtitle(detail);
        if (label.isNotEmpty) parts.add(label);
        watched = detail.userData.lastPlayedDate;
      } else if (found != null) {
        final code = found.season != null && found.episode != null
            ? 'S${found.season}E${found.episode}'
            : null;
        final name = found.name?.trim();
        final label = [?code, if (name != null && name.isNotEmpty) name];
        if (label.isNotEmpty) parts.add(label.join(' · '));
      }
    } else if (item.isSeries && (item.childCount ?? 0) > 0) {
      parts.add(l.cardSeasonCount(item.childCount!));
    }
    final seen = _watchedLabel(l, watched);
    if (seen != null) parts.add(seen);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _sourceCard(
    AppLocalizations l,
    SourceComparison comparison,
    String? Function(String id) serverName,
    Map<String, String> badges,
  ) {
    final openItem = _openableItem(comparison);
    final reference = comparison.source.reference;
    final faces = _versionFaces(_versionsOf(comparison));
    final prefix = _versionPrefix(reference);
    final result = episode != null && comparison.source.item.isSeries
        ? _episodeResult(comparison)
        : null;
    return _SourceCard(
      cardKey: ValueKey(
        'source-selection-item-${reference.account.configuredServerId}-${reference.itemId}',
      ),
      serverName: serverName(reference.account.configuredServerId) ?? '',
      meta: _cardMeta(l, comparison),
      caution: comparison.decision.confirmed
          ? null
          : l.sourceSelectionCheckDetails,
      faces: faces,
      badges: [for (var i = 0; i < faces.length; i++) badges['$prefix:$i']],
      versionsLoading: result?.detailLoading == true,
      onOpen: _busy || openItem == null
          ? null
          : () => _openTarget(openItem, row: reference),
      // 多个版本时点哪个版本，就带着它打开详情并预选；只有一个版本时没有
      // 可选的，按默认打开。版本必须属于将要打开的那个条目。
      onOpenVersion:
          _busy ||
              openItem == null ||
              faces.length < 2 ||
              _versionsOf(comparison).id != openItem.reference.itemId
          ? null
          : (id) => _openTarget(openItem, row: reference, version: id),
      lookup: _episodeStatus(l, comparison),
      error: _rowErrors[reference],
    );
  }

  bool _accepts(MediaItem item) => sourceSelectionAccepts(
    item,
    resolution: _resolution,
    range: _range,
    video: _video,
    subtitle: _subtitle,
    audio: _audio,
  );

  Future<void> _pickFilter(
    BuildContext anchorContext, {
    required String title,
    required List<String> options,
    required String? selected,
    required String Function(String value) labelOf,
    required ValueChanged<String?> onChanged,
  }) async {
    final any = AppLocalizations.of(anchorContext).sourceSelectionFilterAny;
    final position = _filterMenuPosition(anchorContext);
    final choice = await showAppMenu<String>(
      context: anchorContext,
      title: position == null ? title : null,
      position: position,
      selected: selected ?? '',
      constraints: const BoxConstraints(maxWidth: 220),
      items: [
        for (final option in <String?>[null, ...options])
          AppMenuEntry(
            key: Key('source-selection-filter-option-${option ?? 'any'}'),
            value: option ?? '',
            child: Text(option == null ? any : labelOf(option)),
          ),
      ],
    );
    if (!mounted || choice == null) return;
    onChanged(choice.isEmpty ? null : choice);
  }

  RelativeRect? _filterMenuPosition(BuildContext anchorContext) {
    final button = anchorContext.findRenderObject();
    final overlay = Navigator.of(anchorContext).overlay?.context
        .findRenderObject();
    if (button is! RenderBox ||
        !button.attached ||
        !button.hasSize ||
        overlay is! RenderBox ||
        !overlay.attached ||
        !overlay.hasSize) {
      return null;
    }
    return RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
  }

  Widget _filterControl({
    required Key key,
    required String title,
    required String category,
    required List<String> options,
    required String? selected,
    required ValueChanged<String?> onSelected,
    String Function(String value)? labelOf,
    IconData? icon,
    String? mark,
  }) {
    final l = AppLocalizations.of(context);
    String labelFor(String? value) => value == null
        ? l.sourceSelectionFilterAny
        : (labelOf?.call(value) ?? value);
    final label = labelFor(selected);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Builder(
        builder: (buttonContext) => _FilterButton(
          key: key,
          icon: icon,
          mark: mark,
          label: label,
          selected: selected != null,
          semanticLabel: '$category，$label',
          onPressed: _busy
              ? null
              : () => unawaited(
                  _pickFilter(
                    buttonContext,
                    title: title,
                    options: options,
                    selected: selected,
                    labelOf: labelOf ?? (value) => value,
                    onChanged: (value) => setState(() => onSelected(value)),
                  ),
                ),
        ),
      ),
    );
  }

  /// 固定在页眉下方的筛选条。只有至少两种取值的维度才出现；
  /// 没有可筛的维度时返回 null，页眉下不留空行。
  Widget? _filterBar(
    AppLocalizations l, {
    required List<String> resolutions,
    required List<String> ranges,
    required List<String> videos,
    required List<String> subtitles,
    required List<String> sounds,
  }) {
    final controls = <Widget>[
      if (resolutions.length >= 2 || _resolution != null)
        _filterControl(
          key: const Key('source-selection-filter-resolution'),
          title: l.sourceSelectionResolution,
          category: l.sourceSelectionResolution,
          options: resolutions,
          selected: _resolution,
          icon: AppIcons.quality,
          onSelected: (value) => _resolution = value,
        ),
      if (ranges.length >= 2 || _range != null)
        _filterControl(
          key: const Key('source-selection-filter-range'),
          title: l.sourceSelectionRange,
          category: l.sourceSelectionRange,
          options: ranges,
          selected: _range,
          mark: 'HDR',
          onSelected: (value) => _range = value,
        ),
      if (videos.length >= 2 || _video != null)
        _filterControl(
          key: const Key('source-selection-filter-video'),
          title: l.sourceSelectionVideo,
          category: l.sourceSelectionVideo,
          options: videos,
          selected: _video,
          icon: AppIcons.video,
          onSelected: (value) => _video = value,
        ),
      if (subtitles.length >= 2 || _subtitle != null)
        _filterControl(
          key: const Key('source-selection-filter-subtitle'),
          title: l.sourceSelectionSubtitle,
          category: l.sourceSelectionSubtitle,
          options: subtitles,
          selected: _subtitle,
          icon: AppIcons.subtitles,
          labelOf: (value) => _subtitleLabel(l, value),
          onSelected: (value) => _subtitle = value,
        ),
      if (sounds.length >= 2 || _audio != null)
        _filterControl(
          key: const Key('source-selection-filter-audio'),
          title: l.sourceSelectionSound,
          category: l.sourceSelectionSound,
          options: sounds,
          selected: _audio,
          icon: AppIcons.volumeUp,
          onSelected: (value) => _audio = value,
        ),
      if (_filtering)
        AppButton(
          key: const Key('source-selection-filter-clear'),
          onPressed: _busy ? null : () => setState(_clearFilters),
          variant: AppButtonVariant.plain,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(l.sourceSelectionClearFilters),
        ),
    ];
    if (controls.isEmpty) return null;
    return SizedBox(
      key: const Key('source-selection-filters'),
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        primary: false,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: controls),
      ),
    );
  }

  void _close() => Navigator.pop(context);

  /// 桌面/TV 走居中对话框；手机走贴底弹层，两者共用页眉、筛选条与列表。
  /// TV 的关闭放在页脚，遥控器向下就能走到；其余平台放在页眉右上角，
  /// 键盘快捷键只保留在桌面/TV。
  Widget _frame({
    required String title,
    required Widget content,
    Widget? subtitle,
    Widget? status,
    Widget? toolbar,
    Widget? footer,
  }) {
    final l = AppLocalizations.of(context);
    final tv = PresentationScope.of(context).isTv;
    final panel = _SourcePanel(
      sheet: widget.phoneSheet,
      title: title,
      scroll: _scroll,
      content: content,
      subtitle: subtitle,
      status: status,
      toolbar: toolbar,
      onClose: tv ? null : _close,
      closeLabel: l.sourceSelectionClose,
      footer:
          footer ??
          (tv
              ? Align(
                  alignment: Alignment.centerRight,
                  child: AppButton(
                    key: const Key('source-selection-close'),
                    autofocus: true,
                    onPressed: _close,
                    variant: AppButtonVariant.plain,
                    child: Text(l.sourceSelectionClose),
                  ),
                )
              : null),
    );
    if (widget.phoneSheet) return panel;
    return _DialogKeyboard(autofocus: !tv, child: panel);
  }

  Widget _workLine(MediaItem work) {
    final theme = AppUiTheme.of(context);
    final current = this.current;
    final episodeLabel = current != null && current.isEpisode
        ? continueWatchingSubtitle(current)
        : '';
    return Text(
      episodeLabel.isEmpty ? work.name : '${work.name} · $episodeLabel',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: .86),
        fontWeight: FontWeight.w500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      if (controller.origin == null) {
        if (_sheetResolving) {
          // 弹层解析来源中：骨架卡占位，页眉显示查找状态。
          return _frame(
            title: l.sourceSelectionAction,
            status: _StatusLine(
              text: l.sourceSelectionSearching,
              loading: true,
            ),
            content: const Column(
              children: [
                _SourceCardSkeleton(),
                _SourceCardSkeleton(),
                _SourceCardSkeleton(),
              ],
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        });
        return const SizedBox.shrink();
      }
      _episodeIndex = {
        for (final result in controller.episodes) result.target: result,
      };
      final servers = controller.query.registry.project();
      final access = controller.query.registry.access;
      final originServer =
          controller.origin!.reference.account.configuredServerId;
      final comparisons =
          [
            for (final candidate in controller.comparisons)
              if (candidate.source.reference.account.configuredServerId !=
                      originServer &&
                  (candidate.decision.confirmed ||
                      candidate.decision.kind == MatchKind.candidate))
                candidate,
          ]..sort((a, b) {
            final confirm = (b.decision.confirmed ? 1 : 0).compareTo(
              a.decision.confirmed ? 1 : 0,
            );
            if (confirm != 0) return confirm;
            return _bestScore(_versionsOf(b))
                .compareTo(_bestScore(_versionsOf(a)));
          });
      final shown = [
        for (final comparison in comparisons)
          if (_accepts(_versionsOf(comparison))) comparison,
      ];
      final current = this.current;
      // 当前来源只作对照：只列它最好的一个版本，其余以「N 个版本」带过，
      // 不把其他服务器挤出首屏。
      final currentVersions = current == null
          ? const <_VersionFace>[]
          : _versionFaces(current);
      final currentFaces = [?_bestFace(currentVersions)];
      final badges = _bestBadges([
        (_currentPrefix, currentFaces),
        for (final comparison in shown)
          (
            _versionPrefix(comparison.source.reference),
            _versionFaces(_versionsOf(comparison)),
          ),
      ], l);
      final passwordTarget = _passwordTarget;
      final theme = AppUiTheme.of(context);
      final scheme = theme.colorScheme;
      if (passwordTarget != null) {
        return _frame(
          title: l.sourceSelectionPasswordTitle,
          subtitle: Text(
            passwordTarget.displayName,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PresentationScope.of(context).isTv
                  ? TvServerUnlockForm(
                      onSubmit: _verifyTarget,
                      prompt: l.sourceSelectionPasswordPrompt,
                      submitLabel: l.sourceSelectionUnlock,
                      busy: _busy,
                      unavailable: access.isUnavailable(passwordTarget.id),
                      retryAt: access.retryAt(passwordTarget.id),
                      error: _error,
                    )
                  : ServerUnlockForm(
                      onSubmit: _verifyTarget,
                      prompt: l.sourceSelectionPasswordPrompt,
                      submitLabel: l.sourceSelectionUnlock,
                      busy: _busy,
                      unavailable: access.isUnavailable(passwordTarget.id),
                      retryAt: access.retryAt(passwordTarget.id),
                      error: _error,
                    ),
            ],
          ),
          footer: Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              key: const Key('source-selection-verification-cancel'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _passwordTarget = null;
                      _error = null;
                    }),
              variant: AppButtonVariant.plain,
              child: Text(l.cancelAction),
            ),
          ),
        );
      }
      final versions = [for (final c in comparisons) _versionsOf(c)];
      final resolutions = _facetOptions(versions, (face) => face.resolution);
      final ranges = _facetOptions(versions, (face) => face.range, _rangeOrder);
      final videos = _facetOptions(versions, (face) => face.video, _videoOrder);
      final subtitles = _facetOptions(
        versions,
        (face) => face.subtitle,
        _subtitleOrder,
      );
      final sounds = _facetOptions(versions, (face) => face.audio, _audioOrder);
      final locked = [
        for (final server in servers)
          if (!access.allows(server.id) &&
              controller.entryFor(server.id)?.isValid != true)
            server,
      ];
      final hasMore = controller.sources.any(
        (source) => source.hasMore && !source.failed,
      );
      final failedServers = {
        for (final source in controller.sources)
          if (source.failed) source.key.serverId,
      };
      String? serverName(String id) =>
          servers.where((server) => server.id == id).firstOrNull?.displayName;
      final loading = controller.loading;
      final showCurrent = currentFaces.isNotEmpty;
      final status = _StatusLine(
        loading: loading,
        text: loading && comparisons.isEmpty
            ? l.sourceSelectionSearching
            : l.sourceSelectionFound(
                _filtering ? shown.length : comparisons.length,
              ),
      );
      return _frame(
        title: l.sourceSelectionAction,
        subtitle: _workLine(controller.origin!.item),
        status: status,
        toolbar: _filterBar(
          l,
          resolutions: resolutions,
          ranges: ranges,
          videos: videos,
          subtitles: subtitles,
          sounds: sounds,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RowNote(
                  text: _error!,
                  icon: AppIcons.error,
                  color: scheme.error,
                ),
              ),
            if (showCurrent) ...[
              _SectionLabel(l.sourceSelectionCurrentSection),
              _SourceCard(
                cardKey: const Key('source-selection-current'),
                serverName: serverName(originServer) ?? '',
                current: true,
                currentLabel: l.sourceSelectionCurrent,
                meta: [
                  if (currentVersions.length > 1)
                    l.sourceSelectionVersionCount(currentVersions.length),
                  ?_watchedLabel(l, current!.userData.lastPlayedDate),
                ].join(' · ').emptyAsNull,
                faces: currentFaces,
                badges: [
                  for (var i = 0; i < currentFaces.length; i++)
                    badges['$_currentPrefix:$i'],
                ],
                onOpen: null,
              ),
              if (shown.isNotEmpty || (loading && comparisons.isEmpty))
                _SectionLabel(
                  l.sourceSelectionOtherSection,
                  count: shown.isEmpty ? null : shown.length,
                  top: 10,
                ),
            ],
            if (loading && shown.isEmpty) ...const [
              _SourceCardSkeleton(),
              _SourceCardSkeleton(),
            ],
            if (controller.complete && comparisons.isEmpty && locked.isEmpty)
              _EmptyState(
                icon: AppIcons.otherSources,
                title: l.sourceSelectionEmpty,
                hint: l.sourceSelectionEmptyHint,
              ),
            if (controller.complete && comparisons.isNotEmpty && shown.isEmpty)
              _EmptyState(
                icon: AppIcons.filter,
                title: l.sourceSelectionNoMatch,
              ),
            for (final comparison in shown)
              _sourceCard(l, comparison, serverName, badges),
            if (failedServers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 10),
                child: _FailureNotice(
                  text: l.sourceSelectionFailedServers(failedServers.length),
                  actionLabel: l.sourceSelectionRetryAction,
                  onRetry: _busy
                      ? null
                      : () {
                          for (final source in controller.sources.where(
                            (source) => source.failed,
                          )) {
                            unawaited(controller.retry(source.key));
                          }
                        },
                ),
              ),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AppButton(
                  onPressed: _busy
                      ? null
                      : () {
                          for (final source in controller.sources.where(
                            (source) => source.hasMore && !source.failed,
                          )) {
                            unawaited(controller.loadMore(source.key));
                          }
                        },
                  variant: AppButtonVariant.tinted,
                  style: const AppButtonStyle(
                    minimumSize: Size(double.infinity, 44),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(AppIcons.search, size: 18),
                      const SizedBox(width: 6),
                      Text(l.sourceSelectionMore),
                    ],
                  ),
                ),
              ),
            if (locked.isNotEmpty) ...[
              _SectionLabel(
                l.sourceSelectionLockedSection,
                count: locked.length,
                top: comparisons.isEmpty && !showCurrent && !loading ? 0 : 10,
              ),
              _LockedServerGroup(
                servers: locked,
                subtitle: '${l.serversLocked} · ${l.sourceSelectionLockedHint}',
                unlockLabel: l.sourceSelectionUnlock,
                enabled: !_busy,
                onUnlock: (server) {
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                  setState(() {
                    _passwordTarget = server;
                    _error = null;
                  });
                },
              ),
            ],
          ],
        ),
      );
    },
  );
}

enum _SpecTone { neutral, resolution, range }

class _Spec {
  const _Spec(this.label, [this.tone = _SpecTone.neutral]);
  final String label;
  final _SpecTone tone;
}

class _VersionFace {
  const _VersionFace({
    required this.id,
    required this.specs,
    required this.release,
    required this.resolution,
    required this.range,
    required this.video,
    required this.subtitle,
    required this.audio,
    required this.rank,
    required this.bitrate,
  });

  /// 服务器上的 MediaSource id；打开详情时用来预选这个版本。
  final String id;

  /// 规格标签，按「分辨率 · 动态范围 · 编码 · 帧率 · 音频 · 体积 · 码率」排列。
  final List<_Spec> specs;

  /// 去掉片名、年份和刮削标记后的发布名（文件名），用来区分同规格的版本。
  final String? release;
  final String? resolution;
  final String? range;
  final String? video;
  final String? subtitle;
  final String? audio;
  final int rank;
  final int bitrate;
}

class _RankedVersion {
  const _RankedVersion(this.key, this.rank, this.bitrate);
  final String key;
  final int rank;
  final int bitrate;
}

// A source card is rendered several times during one dialog build (sorting,
// filtering, badges and the card itself). Media streams are immutable, so a
// weak identity cache avoids reparsing the same presentation metadata while
// still allowing old query results to be collected.
final Expando<List<_VersionFace>> _versionFacesMemo =
    Expando<List<_VersionFace>>('source-selection-version-faces');

const _resolutionOrder = ['4K', '1440p', '1080p', '720p'];
const _rangeOrder = ['杜比视界', 'HDR10+', 'HDR'];
const _videoOrder = ['AV1', 'H.265', 'VP9', 'H.264', 'MPEG-2'];
const _subtitleOrder = ['zh', 'en', 'external', 'present', 'none'];
const _audioOrder = [
  'Atmos',
  'TrueHD',
  'DTS',
  'E-AC3',
  'AC3',
  'FLAC',
  'AAC',
  'Opus',
  'PCM',
];

int _resolutionRank(String? label) => switch (label) {
  '4K' => 4,
  '1440p' => 3,
  '1080p' => 2,
  '720p' => 1,
  _ => 0,
};

String? _resolutionFromRank(int rank) => switch (rank) {
  4 => '4K',
  3 => '1440p',
  2 => '1080p',
  1 => '720p',
  _ => null,
};

String? _rangeLabel(String token) {
  if (token.contains('杜比视界')) return '杜比视界';
  if (token.contains('HDR10+')) return 'HDR10+';
  if (token.contains('HDR')) return 'HDR';
  return null;
}

String? _audioKey(String token) {
  for (final name in _audioOrder) {
    if (token == name || token.startsWith('$name ')) return name;
  }
  return null;
}

String? _audioFromParts(List<String> parts) {
  for (final part in parts) {
    final audio = _audioKey(part);
    if (audio != null) return audio;
  }
  return null;
}

String? _videoToken(String part) {
  final tokens = part
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();
  for (final token in tokens) {
    if (_videoOrder.contains(token)) return token;
  }
  if (tokens.length != 1) return null;
  final token = tokens.single;
  if (_resolutionRank(token) > 0 ||
      _rangeLabel(token) != null ||
      _audioKey(token) != null) {
    return null;
  }
  if (RegExp(r'^[A-Z0-9][A-Z0-9.+-]{1,11}$').hasMatch(token)) return token;
  return null;
}

String? _videoFromParts(List<String> parts) {
  for (final part in parts) {
    final video = _videoToken(part);
    if (video != null) return video;
  }
  return null;
}

String? _videoFromStreams(ItemMediaSource source) {
  for (final stream in source.streams) {
    if (!stream.isVideo) continue;
    return videoCodecLabel(stream.codec);
  }
  return null;
}

/// 没有任何媒体流时保持未知。空列表只说明服务端没返回 MediaStreams，
/// 不能据此显示成“无字幕”。
String? _subtitleKey(ItemMediaSource source) {
  if (source.streams.isEmpty) return null;
  final subtitles = source.subtitleStreams;
  if (subtitles.isEmpty) return 'none';
  if (subtitles.any(_subtitleIsChinese)) return 'zh';
  if (subtitles.any(_subtitleIsEnglish)) return 'en';
  if (subtitles.every((stream) => stream.isExternal == true)) return 'external';
  return 'present';
}

bool _subtitleIsChinese(ItemMediaStream stream) =>
    _languageIs(stream.language, const {'zh', 'chi', 'zho', 'cn', 'chinese'}) ||
    _labelHas(stream.label, const ['中文', '简体', '繁体', '中字']);

bool _subtitleIsEnglish(ItemMediaStream stream) =>
    _languageIs(stream.language, const {'en', 'eng', 'english'}) ||
    _labelEquals(stream.label, const ['english', '英文', '英字', '英语']);

bool _languageIs(String? language, Set<String> codes) {
  final value = language?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return false;
  return codes.contains(value.split(RegExp(r'[-_]')).first);
}

bool _labelHas(String? label, List<String> needles) {
  final text = label ?? '';
  return needles.any(text.contains);
}

bool _labelEquals(String? label, List<String> values) {
  final text = label?.trim().toLowerCase() ?? '';
  return values.contains(text);
}

String _subtitleLabel(AppLocalizations l10n, String key) => switch (key) {
  'zh' => l10n.sourceSelectionSubtitleChinese,
  'en' => l10n.sourceSelectionSubtitleEnglish,
  'external' => l10n.sourceSelectionSubtitleExternal,
  'present' => l10n.sourceSelectionSubtitlePresent,
  'none' => l10n.sourceSelectionSubtitleNone,
  _ => key,
};

String? _byteLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  const gb = 1000 * 1000 * 1000;
  const mb = 1000 * 1000;
  if (bytes >= gb) {
    final value = bytes / gb;
    final digits = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  return null;
}

String? _bitRateLabel(int bitrate) {
  if (bitrate <= 0) return null;
  final mbps = bitrate / 1000000;
  if (mbps >= 1) {
    final digits = mbps >= 10 ? 0 : 1;
    return '${mbps.toStringAsFixed(digits)} Mbps';
  }
  return '${(bitrate / 1000).round()} kbps';
}

final _providerTag = RegExp(
  r'[\[{(]\s*(?:tmdb|tvdb|imdb|douban|bgm|anidb)(?:id)?\s*[-=:]\s*[^\]})]*[\]})]',
  caseSensitive: false,
);
final _mediaExtension = RegExp(
  r'\.(?:mkv|mp4|m4v|m2ts|ts|avi|iso|wmv|mov|webm|flv|rmvb|strm)$',
  caseSensitive: false,
);
final _leadingYear = RegExp(r'^[(\[]?(?:19|20)\d{2}[)\]]?(?=[\s._\-]|$)');
final _leadingSeparators = RegExp(r'^[\s._\-·:：|]+');

/// 发布名：Emby 的 MediaSource.Name 通常就是文件名，如
/// `兰香如故 S01E12 2160p.HDR.60FPS` 或 `刀剑神域 (2017) {tmdbid=413594} BDRip`。
/// 片名在弹窗标题里已经有了，这里去掉片名、紧随的年份、刮削标记与扩展名；
/// 剩下的只是规格标签的重复（如「4K」）时不再单独显示。
String? _releaseName(
  ItemMediaSource source,
  MediaItem item,
  List<_Spec> specs,
) {
  var text = source.name?.trim() ?? '';
  if (text.isEmpty) return null;
  final slash = text.lastIndexOf(RegExp(r'[\\/]'));
  if (slash >= 0) text = text.substring(slash + 1);
  text = text.replaceFirst(_mediaExtension, '').replaceAll(_providerTag, ' ');
  final titles = <String>{
    for (final title in [item.seriesName, item.name])
      if (title != null && title.trim().length >= 2) title.trim(),
  }.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final title in titles) {
    if (!text.toLowerCase().startsWith(title.toLowerCase())) continue;
    var rest = text
        .substring(title.length)
        .replaceFirst(_leadingSeparators, '');
    rest = rest
        .replaceFirst(_leadingYear, '')
        .replaceFirst(_leadingSeparators, '');
    // 名字就是片名本身（Emby 单版本的默认名），没有可区分的信息。
    if (rest.isEmpty) return null;
    text = rest;
    break;
  }
  text = text.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  if (text.isEmpty) return null;
  var residue = text;
  final labels = [for (final spec in specs) spec.label]
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final label in labels) {
    residue = residue.replaceAll(label, ' ');
  }
  if (residue.replaceAll(RegExp(r'[\s·._\-]+'), '').isEmpty) return null;
  return text;
}

String? _frameRateLabel(ItemMediaSource source) {
  for (final stream in source.streams) {
    if (!stream.isVideo) continue;
    final fps = stream.averageFrameRate ?? 0;
    // 只标高帧率：24/25/30 是默认，标出来只是噪音。
    return fps >= 47 ? '${fps.round()}fps' : null;
  }
  return null;
}

_VersionFace _faceFor(ItemMediaSource source, MediaItem item) {
  final view = source.presentation;
  final parts = view.headline == '—'
      ? const <String>[]
      : view.headline
            .split(' · ')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();
  final specs = <_Spec>[];
  bool has(String label) => specs.any((spec) => spec.label == label);
  String? resolution;
  String? range;
  String? audio;
  final video = _videoFromStreams(source) ?? _videoFromParts(parts);
  final subtitle = _subtitleKey(source);
  final fps = _frameRateLabel(source);
  if (parts.isNotEmpty) {
    final quality = parts.first
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    final structured =
        parts.length > 1 ||
        quality.any(
          (token) => _resolutionRank(token) > 0 || _rangeLabel(token) != null,
        );
    if (!structured) {
      specs.add(_Spec(parts.join(' · ')));
    } else {
      for (final token in quality) {
        final isResolution = _resolutionRank(token) > 0;
        final tokenRange = _rangeLabel(token);
        if (isResolution) resolution ??= token;
        range ??= tokenRange;
        if (!has(token)) {
          specs.add(
            _Spec(
              token,
              isResolution
                  ? _SpecTone.resolution
                  : tokenRange != null
                  ? _SpecTone.range
                  : _SpecTone.neutral,
            ),
          );
        }
      }
      if (parts.length >= 2 && !has(parts[1])) specs.add(_Spec(parts[1]));
      if (fps != null && !has(fps)) specs.add(_Spec(fps));
      if (parts.length >= 3) {
        audio = _audioKey(parts[2]);
        if (!has(parts[2])) specs.add(_Spec(parts[2]));
      }
    }
  }
  audio ??= _audioFromParts(parts);
  var bitrate = source.bitrate ?? 0;
  if (bitrate <= 0) {
    for (final stream in source.streams) {
      if (stream.isVideo && (stream.bitRate ?? 0) > 0) {
        bitrate = stream.bitRate!;
        break;
      }
    }
  }
  final size = _byteLabel(source.size);
  final rate = _bitRateLabel(bitrate);
  if (size != null && !has(size)) specs.add(_Spec(size));
  if (rate != null && !has(rate)) specs.add(_Spec(rate));
  var rank = _resolutionRank(resolution);
  if (rank == 0) {
    final height = source.height ?? 0;
    final width = source.width ?? 0;
    if (height >= 2160 || width >= 3840) {
      rank = 4;
    } else if (height >= 1440 || width >= 2560) {
      rank = 3;
    } else if (height >= 1080 || width >= 1920) {
      rank = 2;
    } else if (height >= 720 || width >= 1280) {
      rank = 1;
    }
  }
  if (resolution == null) {
    resolution = _resolutionFromRank(rank);
    if (resolution != null && !has(resolution)) {
      specs.insert(0, _Spec(resolution, _SpecTone.resolution));
    }
  }
  return _VersionFace(
    id: source.id,
    specs: specs,
    release: _releaseName(source, item, specs),
    resolution: resolution,
    range: range,
    video: video,
    subtitle: subtitle,
    audio: audio,
    rank: rank,
    bitrate: bitrate < 0 ? 0 : bitrate,
  );
}

List<_VersionFace> _versionFaces(MediaItem item) {
  final cached = _versionFacesMemo[item];
  if (cached != null) return cached;
  final faces = <_VersionFace>[];
  for (final source in item.mediaSources) {
    final face = _faceFor(source, item);
    if (face.specs.isNotEmpty ||
        face.release != null ||
        face.resolution != null ||
        face.range != null ||
        face.video != null ||
        face.subtitle != null ||
        face.audio != null) {
      faces.add(face);
    }
  }
  final result = List<_VersionFace>.unmodifiable(faces);
  _versionFacesMemo[item] = result;
  return result;
}

@visibleForTesting
typedef SourceSelectionFace = ({
  String? resolution,
  String? range,
  String? video,
  String? subtitle,
  String? audio,
});

@visibleForTesting
List<SourceSelectionFace> sourceSelectionFaces(MediaItem item) => [
  for (final face in _versionFaces(item))
    (
      resolution: face.resolution,
      range: face.range,
      video: face.video,
      subtitle: face.subtitle,
      audio: face.audio,
    ),
];

/// 版本行上显示的发布名与规格标签，供测试核对展示内容。
@visibleForTesting
List<({String? release, List<String> specs})> sourceSelectionVersionLabels(
  MediaItem item,
) => [
  for (final face in _versionFaces(item))
    (release: face.release, specs: [for (final spec in face.specs) spec.label]),
];

@visibleForTesting
bool sourceSelectionAccepts(
  MediaItem item, {
  String? resolution,
  String? range,
  String? video,
  String? subtitle,
  String? audio,
}) {
  if (resolution == null &&
      range == null &&
      video == null &&
      subtitle == null &&
      audio == null) {
    return true;
  }
  final faces = _versionFaces(item);
  if (faces.isEmpty) return false;
  return faces.any(
    (face) =>
        (resolution == null || face.resolution == resolution) &&
        (range == null || face.range == range) &&
        (video == null || face.video == video) &&
        (subtitle == null || face.subtitle == subtitle) &&
        (audio == null || face.audio == audio),
  );
}

int _faceScore(_VersionFace face) => face.rank * 1000000000 + face.bitrate;

int _bestScore(MediaItem item) {
  var best = 0;
  for (final face in _versionFaces(item)) {
    final score = _faceScore(face);
    if (score > best) best = score;
  }
  return best;
}

_VersionFace? _bestFace(List<_VersionFace> faces) {
  _VersionFace? best;
  for (final face in faces) {
    if (best == null || _faceScore(face) > _faceScore(best)) best = face;
  }
  return best;
}

extension on String {
  String? get emptyAsNull => isEmpty ? null : this;
}

const _currentPrefix = 'current';

String _versionPrefix(SourceReference reference) =>
    '${reference.account.configuredServerId}:${reference.itemId}';

List<String> _facetOptions(
  List<MediaItem> items,
  String? Function(_VersionFace face) read, [
  List<String> order = _resolutionOrder,
]) {
  final found = <String>{};
  for (final item in items) {
    for (final face in _versionFaces(item)) {
      final value = read(face);
      if (value != null && value.isNotEmpty) found.add(value);
    }
  }
  final ordered = <String>[
    for (final name in order)
      if (found.remove(name)) name,
  ];
  final rest = found.toList()..sort();
  return [...ordered, ...rest];
}

/// 在当前来源与所有可见来源的全部版本里挑出唯一的最佳者，
/// 标「最高码率」或「最清晰」。并列或缺少数据时不标。
Map<String, String> _bestBadges(
  List<(String, List<_VersionFace>)> rows,
  AppLocalizations l10n,
) {
  final ranked = <_RankedVersion>[];
  for (final (prefix, faces) in rows) {
    for (var index = 0; index < faces.length; index++) {
      ranked.add(
        _RankedVersion(
          '$prefix:$index',
          faces[index].rank,
          faces[index].bitrate,
        ),
      );
    }
  }
  if (ranked.length < 2) return const {};
  ranked.sort((a, b) {
    final rank = b.rank.compareTo(a.rank);
    if (rank != 0) return rank;
    return b.bitrate.compareTo(a.bitrate);
  });
  final top = ranked.first;
  final next = ranked[1];
  if ((top.rank == next.rank && top.bitrate == next.bitrate) ||
      (top.rank == 0 && top.bitrate == 0)) {
    return const {};
  }
  final highestRate = ranked.fold<int>(
    0,
    (best, version) => version.bitrate > best ? version.bitrate : best,
  );
  final label =
      top.bitrate > 0 &&
          top.bitrate == highestRate &&
          top.bitrate > next.bitrate
      ? l10n.sourceSelectionBestBitrate
      : top.rank > next.rank
      ? l10n.sourceSelectionClearest
      : null;
  if (label == null) return const {};
  return {top.key: label};
}

String? _watchedLabel(AppLocalizations l10n, DateTime? date) {
  if (date == null) return null;
  final local = date.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final delta = today.difference(day).inDays;
  if (delta <= 0) return l10n.sourceSelectionWatchedToday;
  if (delta == 1) return l10n.sourceSelectionWatchedYesterday;
  if (delta < 365) return l10n.sourceSelectionWatchedDays(delta);
  return null;
}

String _serverInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

/// 每台服务器一个稳定的低饱和色块，多台服务器一眼能分开。
(Color, Color) _serverColors(String name, Brightness brightness) {
  var hash = 0;
  for (final rune in name.trim().runes) {
    hash = (hash * 31 + rune) & 0x7fffffff;
  }
  final hue = (hash % 360).toDouble();
  final dark = brightness == Brightness.dark;
  final fill = HSLColor.fromAHSL(1, hue, .42, dark ? .30 : .88).toColor();
  final ink = HSLColor.fromAHSL(1, hue, .55, dark ? .88 : .28).toColor();
  return (fill, ink);
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    super.key,
    required this.label,
    required this.selected,
    required this.semanticLabel,
    required this.onPressed,
    this.icon,
    this.mark,
  });

  final String label;
  final bool selected;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? mark;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    final muted = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return AppButton(
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      variant: AppButtonVariant.filled,
      style: AppButtonStyle(
        backgroundColor: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHigh,
        foregroundColor: foreground,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: .5)
              : AppEdge.of(scheme.brightness, strong: true),
        ),
        textStyle: theme.textTheme.labelLarge,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: muted),
            const SizedBox(width: 6),
          ],
          if (mark != null) ...[
            Text(
              mark!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontWeight: FontWeight.w800,
                letterSpacing: -.2,
              ),
            ),
            if (label != mark) const SizedBox(width: 6),
          ],
          if (mark == null || label != mark) Text(label),
          const SizedBox(width: 4),
          Icon(AppIcons.chevronDown, size: 16, color: muted),
        ],
      ),
    );
  }
}

/// 需要解锁的服务器收在列表末尾的一组紧凑行里：查找结果优先，
/// 解锁是次要动作。
class _LockedServerGroup extends StatelessWidget {
  const _LockedServerGroup({
    required this.servers,
    required this.subtitle,
    required this.unlockLabel,
    required this.enabled,
    required this.onUnlock,
  });

  final List<SavedServer> servers;
  final String subtitle;
  final String unlockLabel;
  final bool enabled;
  final ValueChanged<SavedServer> onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppEdge.of(scheme.brightness, strong: true)),
      ),
      child: Column(
        children: [
          for (var index = 0; index < servers.length; index++) ...[
            if (index > 0)
              Padding(
                padding: const EdgeInsets.only(left: 58),
                child: Container(
                  height: 1,
                  color: AppEdge.of(scheme.brightness),
                ),
              ),
            Padding(
              key: ValueKey('source-selection-server-${servers[index].id}'),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: .06),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      AppIcons.lock,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          servers[index].displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    key: ValueKey(
                      'source-selection-verify-${servers[index].id}',
                    ),
                    onPressed: enabled ? () => onUnlock(servers[index]) : null,
                    variant: AppButtonVariant.tinted,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(unlockLabel),
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

class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.cardKey,
    required this.serverName,
    required this.meta,
    required this.faces,
    required this.badges,
    required this.onOpen,
    this.onOpenVersion,
    this.current = false,
    this.currentLabel,
    this.caution,
    this.versionsLoading = false,
    this.lookup,
    this.error,
  });

  final Key cardKey;
  final String serverName;
  final String? meta;
  final bool current;
  final String? currentLabel;
  final String? caution;
  final List<_VersionFace> faces;
  final List<String?> badges;
  final VoidCallback? onOpen;

  /// 打开并预选某个版本。为空时版本行与卡片头一样按默认打开。
  final ValueChanged<String>? onOpenVersion;
  final bool versionsLoading;
  final Widget? lookup;
  final String? error;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  /// 指针所在的部分：-1 是卡片头，0.. 是第几个版本。
  int? _hovered;

  void _hover(int part, bool value) {
    setState(() {
      if (value) {
        _hovered = part;
      } else if (_hovered == part) {
        _hovered = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final interactive = widget.onOpen != null;
    final headerHovered = _hovered == -1 && interactive;
    final anyHovered = _hovered != null && interactive;
    final radius = BorderRadius.circular(AppRadii.lg);
    final border = widget.current
        ? scheme.primary.withValues(alpha: .65)
        : anyHovered
        ? scheme.onSurface.withValues(alpha: .22)
        : AppEdge.of(scheme.brightness, strong: true);
    final fill = widget.current
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: .06),
            scheme.surfaceContainerHigh,
          )
        : headerHovered
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerHigh;
    final header = Row(
      children: [
        _ServerMark(name: widget.serverName),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.serverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.current && widget.currentLabel != null) ...[
                    const SizedBox(width: 8),
                    _Pill(
                      label: widget.currentLabel!,
                      background: scheme.primary,
                      foreground: scheme.onPrimary,
                    ),
                  ],
                ],
              ),
              if (widget.meta != null) ...[
                const SizedBox(height: 2),
                Text(
                  widget.meta!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (interactive) ...[
          const SizedBox(width: 8),
          Icon(
            AppIcons.chevronRight,
            size: 22,
            color: headerHovered ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ],
      ],
    );
    final faces = [
      for (final face in widget.faces)
        if (face.release != null || face.specs.isNotEmpty) face,
    ];
    final hasVersions = faces.isNotEmpty;
    final trailing = widget.lookup != null || widget.error != null;
    return Padding(
      key: widget.cardKey,
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.all(color: border, width: widget.current ? 1.5 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSurfaceAction(
              onTap: widget.onOpen,
              onHover: (value) => _hover(-1, value),
              borderRadius: radius,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  14,
                  14,
                  14,
                  hasVersions || widget.versionsLoading
                      ? 4
                      : trailing
                      ? 10
                      : 14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    if (widget.caution != null) ...[
                      const SizedBox(height: 10),
                      _RowNote(
                        text: widget.caution!,
                        icon: AppIcons.info,
                        color: _cautionColor(scheme.brightness),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            for (var index = 0; index < faces.length; index++)
              _VersionRow(
                key: ValueKey('source-selection-version-${faces[index].id}'),
                face: faces[index],
                badge: widget.faces.indexOf(faces[index]) < widget.badges.length
                    ? widget.badges[widget.faces.indexOf(faces[index])]
                    : null,
                divided: index > 0,
                last: index == faces.length - 1 && !trailing,
                hovered: _hovered == index && interactive,
                onHover: (value) => _hover(index, value),
                onTap: widget.onOpen == null
                    ? null
                    : widget.onOpenVersion == null
                    ? widget.onOpen
                    : () => widget.onOpenVersion!(faces[index].id),
              ),
            if (widget.versionsLoading && !hasVersions)
              Padding(
                padding: EdgeInsets.fromLTRB(14, 8, 14, trailing ? 10 : 14),
                child: _VersionSkeleton(
                  animate: !MediaQuery.disableAnimationsOf(context),
                ),
              ),
            if (widget.lookup != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: widget.lookup,
                ),
              ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: _RowNote(
                  text: widget.error!,
                  icon: AppIcons.wifiOff,
                  color: scheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 待核对提示与 HDR 标签共用的暖色，取自服务状态的语义色。
Color _cautionColor(Brightness brightness) => AppSemantic.warning(brightness);

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.background,
    required this.foreground,
  });
  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadii.pill),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      child: Text(
        label,
        style: AppUiTheme.of(context).textTheme.labelSmall
            ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

/// 卡片里的一行小字说明（查找中、没有这一集、待核对、连不上）。
class _RowNote extends StatelessWidget {
  const _RowNote({
    required this.text,
    this.icon,
    this.color,
    this.loading = false,
  });
  final String text;
  final IconData? icon;
  final Color? color;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading)
          const SizedBox(
            width: 14,
            height: 14,
            child: CupertinoActivityIndicator(radius: 6),
          )
        else if (icon != null)
          Icon(icon, size: 15, color: tint),
        if (loading || icon != null) const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: tint),
          ),
        ),
      ],
    );
  }
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({
    required this.text,
    required this.actionLabel,
    required this.onRetry,
  });
  final String text;
  final String actionLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: scheme.error.withValues(alpha: .22)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: [
            Icon(AppIcons.wifiOff, size: 18, color: scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            AppButton(
              onPressed: onRetry,
              variant: AppButtonVariant.plain,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, this.hint});
  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: .06),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 24, color: muted),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall,
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _ServerMark extends StatelessWidget {
  const _ServerMark({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final (fill, ink) = _serverColors(name, theme.colorScheme.brightness);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Text(
        _serverInitial(name),
        style: theme.textTheme.titleMedium?.copyWith(
          color: ink,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 一个版本：发布名一行，下面一排规格标签，多个版本之间用细线分开。
/// 每一行是独立的点按目标：多个版本时打开详情并预选这个版本。
class _VersionRow extends StatelessWidget {
  const _VersionRow({
    super.key,
    required this.face,
    required this.badge,
    required this.divided,
    required this.last,
    required this.hovered,
    required this.onHover,
    required this.onTap,
  });
  final _VersionFace face;
  final String? badge;
  final bool divided;
  final bool last;
  final bool hovered;
  final ValueChanged<bool> onHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final release = face.release;
    return AppSurfaceAction(
      onTap: onTap,
      // 长按复制发布名（文件名），方便到别处搜索或比对。
      onLongPress: release == null
          ? null
          : () => unawaited(LongPressCopy.copy(context, release)),
      onHover: onHover,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        color: hovered
            ? scheme.onSurface.withValues(alpha: .05)
            : scheme.onSurface.withValues(alpha: 0),
        padding: EdgeInsets.fromLTRB(14, divided ? 0 : 8, 14, last ? 14 : 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (divided) ...[
              Container(height: 1, color: AppEdge.of(scheme.brightness)),
              const SizedBox(height: 10),
            ],
            if (face.release != null)
              Text(
                face.release!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: .9),
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            if (face.specs.isNotEmpty || badge != null) ...[
              if (face.release != null) const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final spec in face.specs) _SpecChip(spec: spec),
                  if (badge != null) _SpecChip.badge(badge!),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SpecChip extends StatelessWidget {
  const _SpecChip({required this.spec}) : badgeLabel = null;
  const _SpecChip.badge(String label)
    : spec = const _Spec(''),
      badgeLabel = label;
  final _Spec spec;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final gold = _cautionColor(scheme.brightness);
    final badge = badgeLabel != null;
    final (Color background, Color foreground, FontWeight weight) = badge
        ? (scheme.primary, scheme.onPrimary, FontWeight.w700)
        : switch (spec.tone) {
            _SpecTone.resolution => (
              scheme.primary.withValues(alpha: dark ? .20 : .12),
              dark ? scheme.primary : scheme.onPrimaryContainer,
              FontWeight.w700,
            ),
            _SpecTone.range => (
              gold.withValues(alpha: dark ? .16 : .14),
              gold,
              FontWeight.w700,
            ),
            _SpecTone.neutral => (
              scheme.onSurface.withValues(alpha: dark ? .07 : .06),
              scheme.onSurface.withValues(alpha: .82),
              FontWeight.w500,
            ),
          };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          badgeLabel ?? spec.label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: foreground,
            fontWeight: weight,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
