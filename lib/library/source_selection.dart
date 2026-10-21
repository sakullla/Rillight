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

class _SourceSelectionFrame extends StatelessWidget {
  const _SourceSelectionFrame({
    required this.title,
    required this.scroll,
    required this.content,
    required this.footer,
    this.caption,
  });

  final String title;
  final ScrollController scroll;
  final Widget content;
  final Widget footer;
  final Widget? caption;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final hairline = BorderSide(color: scheme.outlineVariant);
    return AppModalFrame(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              decoration: BoxDecoration(border: Border(bottom: hairline)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    key: const Key('source-selection-title'),
                    style: theme.textTheme.titleLarge,
                  ),
                  if (caption != null) ...[const SizedBox(height: 6), caption!],
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const Key('source-selection-content'),
                controller: scroll,
                primary: false,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: content,
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: BoxDecoration(border: Border(top: hairline)),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机底部弹层的框架：顶部拖拽条、标题区、可滚内容与贴底页脚，
/// 结构与 [_SourceSelectionFrame] 一一对应，只是外框换成贴底圆角弹层。
class _SourceSelectionSheetFrame extends StatelessWidget {
  const _SourceSelectionSheetFrame({
    required this.title,
    required this.scroll,
    required this.content,
    required this.footer,
    this.caption,
  });

  final String title;
  final ScrollController scroll;
  final Widget content;
  final Widget footer;
  final Widget? caption;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final hairline = BorderSide(color: scheme.outlineVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
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
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          decoration: BoxDecoration(border: Border(bottom: hairline)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                key: const Key('source-selection-title'),
                style: theme.textTheme.titleLarge,
              ),
              if (caption != null) ...[const SizedBox(height: 6), caption!],
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const Key('source-selection-content'),
            controller: scroll,
            primary: false,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: content,
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(border: Border(top: hairline)),
          child: SafeArea(top: false, child: footer),
        ),
      ],
    );
  }
}

/// 查询中占位的来源骨架卡：与 [_SourceCard] 同外形（服务器标记圆块 +
/// 两行文字），骨架到结果的切换不跳动。
class _SourceCardSkeleton extends StatelessWidget {
  const _SourceCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: AppEdge.of(scheme.brightness, strong: true),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(
                width: 36,
                height: 36,
                borderRadius: BorderRadius.circular(AppRadii.md),
                animated: animate,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBlock(width: 96, height: 14, animated: animate),
                    const SizedBox(height: 8),
                    SkeletonBlock(
                      width: double.infinity,
                      height: 12,
                      animated: animate,
                    ),
                    const SizedBox(height: 6),
                    SkeletonBlock(width: 168, height: 12, animated: animate),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
      var dto = await origin.permit.dispatch(
        (c) => c.getItem(origin.source.itemId),
      );
      EpisodeSource? episode;
      if (dto.isEpisode && dto.seriesId != null) {
        episode = EpisodeSource.fromMediaItem(origin.source, dto);
        dto = await origin.permit.dispatch((c) => c.getItem(dto.seriesId!));
      }
      if (!mounted || !stillHere() || !origin.permit.isValid) return;
      final item = QueryItem(
        SourceReference(account: origin.source.account, itemId: dto.id),
        origin.libraryId,
        dto,
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
        builder: (context) =>
            _SourceSelectionDialog(controller: controller!, episode: episode),
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
    this.phoneSheet = false,
    this.runtime,
    this.scopedOrigin,
    this.itemId,
    this.selectedGeneration,
    this.stillHere,
  });
  final SameSourceQueryController controller;
  final EpisodeSource? episode;

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
  SavedServer? _passwordTarget;
  ServerEntryTicket? _pendingEntry;
  bool _busy = false;
  bool _resolved = false;
  String? _error;
  String? _resolution;
  String? _range;
  String? _video;
  String? _subtitle;
  String? _audio;
  final ScrollController _scroll = ScrollController();

  bool get _sheetResolving => widget.phoneSheet && !_resolved;

  @override
  void initState() {
    super.initState();
    _resolved = !widget.phoneSheet;
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
      var dto = await origin.permit.dispatch(
        (c) => c.getItem(origin.source.itemId),
      );
      EpisodeSource? episode;
      if (dto.isEpisode && dto.seriesId != null) {
        episode = EpisodeSource.fromMediaItem(origin.source, dto);
        dto = await origin.permit.dispatch((c) => c.getItem(dto.seriesId!));
      }
      if (!mounted || !stillHere() || !origin.permit.isValid) {
        _closeAfterFrame();
        return;
      }
      _resolvedEpisode = episode;
      final item = QueryItem(
        SourceReference(account: origin.source.account, itemId: dto.id),
        origin.libraryId,
        dto,
      );
      unawaited(
        widget.controller.start(origin: item, scope: QueryScope(pageSize: 24)),
      );
      if (mounted) setState(() => _resolved = true);
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
    _pendingEntry?.cancel();
    _scroll.dispose();
    super.dispose();
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
              : AppLocalizations.of(context).serversConnectionFailed,
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
          () => _error = AppLocalizations.of(context).serversConnectionFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTarget(QueryItem item) async {
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
      _error = null;
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
        await entry.prepareCommit();
        if (!mounted || controller.origin == null) {
          entry.cancel();
          return;
        }
        if (!entry.commit()) throw StateError('Target entry revoked');
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
      if (navigator.mounted && route?.isCurrent == true) navigator.pop();
      overlay?.close();
      router.go(
        '/item/${Uri.encodeComponent(target.source.itemId)}',
        extra: destination,
      );
    } catch (_) {
      entry?.cancel();
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).serversConnectionFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lookupEpisode(BuildContext context, QueryItem target) async {
    if (_busy) return;
    final verified = await confirmEpisodeMapping(context);
    if (!context.mounted) return;
    if (controller.origin == null) {
      Navigator.of(context).pop();
      return;
    }
    if (verified == null) return;
    final e = episode!;
    final mapped = verified ? withConfirmedEpisodeMapping(e) : e;
    await controller.lookupEpisode(
      target: target,
      episode: mapped,
      verifiedNumberingScheme: verified ? userConfirmedEpisodeNumbering : null,
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

  Widget _filterBar(
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
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(l.sourceSelectionClearFilters),
        ),
    ];
    if (controls.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        key: const Key('source-selection-filters'),
        height: 44,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: Row(children: controls),
        ),
      ),
    );
  }

  Widget _closeButton() => AppButton(
    key: const Key('source-selection-close'),
    autofocus: PresentationScope.of(context).isTv,
    onPressed: () => Navigator.pop(context),
    variant: AppButtonVariant.plain,
    child: const Text('关闭'),
  );

  /// 桌面/TV 走居中对话框；手机底部弹层走带拖拽条的弹层框架，两者共用
  /// 标题、内容与页脚，键盘快捷键只保留在桌面/TV。
  Widget _frame({
    required String title,
    required Widget content,
    required Widget footer,
    Widget? caption,
  }) {
    if (widget.phoneSheet) {
      return _SourceSelectionSheetFrame(
        title: title,
        scroll: _scroll,
        content: content,
        footer: footer,
        caption: caption,
      );
    }
    return _DialogKeyboard(
      autofocus: !PresentationScope.of(context).isTv,
      child: _SourceSelectionFrame(
        title: title,
        scroll: _scroll,
        content: content,
        footer: footer,
        caption: caption,
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
          // 弹层解析来源中：骨架卡占位，页脚只有解析指示与关闭。
          return _frame(
            title: l.sourceSelectionAction,
            content: const Column(
              children: [
                _SourceCardSkeleton(),
                _SourceCardSkeleton(),
                _SourceCardSkeleton(),
              ],
            ),
            footer: Row(
              children: [
                const CupertinoActivityIndicator(),
                const Spacer(),
                _closeButton(),
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
      final servers = controller.query.registry.project();
      final access = controller.query.registry.access;
      final comparisons =
          [
            for (final candidate in controller.comparisons)
              if (candidate.source.reference.account.configuredServerId !=
                      controller.origin!.reference.account.configuredServerId &&
                  (candidate.decision.confirmed ||
                      candidate.decision.kind == MatchKind.candidate))
                candidate,
          ]..sort((a, b) {
            final confirm = (b.decision.confirmed ? 1 : 0).compareTo(
              a.decision.confirmed ? 1 : 0,
            );
            if (confirm != 0) return confirm;
            return _bestScore(b).compareTo(_bestScore(a));
          });
      final shown = [
        for (final comparison in comparisons)
          if (_accepts(comparison.source.item)) comparison,
      ];
      final badges = _bestBadges(shown, l);
      final passwordTarget = _passwordTarget;
      final theme = AppUiTheme.of(context);
      final scheme = theme.colorScheme;
      if (passwordTarget != null) {
        return _frame(
          title: l.sourceSelectionPasswordTitle,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                passwordTarget.displayName,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
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
      final resolutions = _facetOptions(comparisons, (face) => face.resolution);
      final ranges = _facetOptions(
        comparisons,
        (face) => face.range,
        _rangeOrder,
      );
      final videos = _facetOptions(
        comparisons,
        (face) => face.video,
        _videoOrder,
      );
      final subtitles = _facetOptions(
        comparisons,
        (face) => face.subtitle,
        _subtitleOrder,
      );
      final sounds = _facetOptions(
        comparisons,
        (face) => face.audio,
        _audioOrder,
      );
      final unlocked = servers.every(
        (server) =>
            access.allows(server.id) ||
            controller.entryFor(server.id)?.isValid == true,
      );
      final hasMore = controller.sources.any(
        (source) => source.hasMore && !source.failed,
      );
      final failed = controller.sources.any((source) => source.failed);
      String? serverName(String id) =>
          servers.where((server) => server.id == id).firstOrNull?.displayName;
      return _frame(
        title: l.sourceSelectionAction,
        caption: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controller.origin!.item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              l.sourceSelectionHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            _filterBar(
              l,
              resolutions: resolutions,
              ranges: ranges,
              videos: videos,
              subtitles: subtitles,
              sounds: sounds,
            ),
            for (final server in servers)
              if (!access.allows(server.id) &&
                  controller.entryFor(server.id)?.isValid != true)
                _LockedServerRow(
                  server: server,
                  lockedLabel: l.serversLocked,
                  unlockLabel: l.sourceSelectionUnlock,
                  enabled: !_busy,
                  onUnlock: () {
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    setState(() {
                      _passwordTarget = server;
                      _error = null;
                    });
                  },
                ),
            if (controller.loading && shown.isEmpty) ...const [
              _SourceCardSkeleton(),
              _SourceCardSkeleton(),
              _SourceCardSkeleton(),
            ],
            if (controller.complete && comparisons.isEmpty && unlocked)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    l.sourceSelectionEmpty,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            if (controller.complete && comparisons.isNotEmpty && shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    l.sourceSelectionNoMatch,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            for (final comparison in shown)
              _SourceCard(
                cardKey: ValueKey(
                  'source-selection-item-${comparison.source.reference.account.configuredServerId}-${comparison.source.reference.itemId}',
                ),
                serverName:
                    serverName(
                      comparison.source.reference.account.configuredServerId,
                    ) ??
                    '',
                meta: _sourceMeta(l, comparison.source.item),
                caution: comparison.decision.confirmed
                    ? null
                    : l.sourceSelectionCheckDetails,
                faces: _versionFaces(comparison.source.item),
                badges: [
                  for (
                    var i = 0;
                    i < _versionFaces(comparison.source.item).length;
                    i++
                  )
                    badges[_versionKey(comparison, i)],
                ],
                onOpen: _busy ? null : () => _openTarget(comparison.source),
                lookup:
                    episode != null &&
                        comparison.decision.confirmed &&
                        comparison.source.item.isSeries
                    ? AppButton(
                        onPressed: _busy
                            ? null
                            : () => _lookupEpisode(context, comparison.source),
                        variant: AppButtonVariant.tinted,
                        child: Text(l.aggregationEpisodeLookup),
                      )
                    : null,
              ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AppButton(
                  onPressed: _busy
                      ? null
                      : () {
                          for (final source in controller.sources.where(
                            (source) => source.failed,
                          )) {
                            unawaited(controller.retry(source.key));
                          }
                        },
                  variant: AppButtonVariant.outlined,
                  style: const AppButtonStyle(
                    minimumSize: Size(double.infinity, 40),
                  ),
                  child: Text(l.sourceSelectionRetry),
                ),
              ),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(top: 4),
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
                  variant: AppButtonVariant.outlined,
                  style: const AppButtonStyle(
                    minimumSize: Size(double.infinity, 40),
                  ),
                  child: Text(l.sourceSelectionMore),
                ),
              ),
            for (final result in controller.episodes)
              _EpisodeStatusRow(
                label: _episodeStatusLabel(l, result.lookup.status),
                retryLabel: l.aggregationRetry,
                onRetry: result.lookup.status == EpisodeLookupStatus.queryFailed
                    ? () => _lookupEpisode(
                        context,
                        controller.comparisons
                            .firstWhere(
                              (comparison) =>
                                  comparison.source.reference == result.target,
                            )
                            .source,
                      )
                    : null,
                onOpen: result.lookup.source == null
                    ? null
                    : () {
                        final target = controller.comparisons
                            .firstWhere(
                              (comparison) =>
                                  comparison.source.reference == result.target,
                            )
                            .source;
                        final ref = result.lookup.source!.reference;
                        _openTarget(
                          QueryItem(
                            ref,
                            target.libraryId,
                            MediaItem(
                              id: ref.itemId,
                              name: l.aggregationEpisodeConfirmed,
                              type: 'Episode',
                            ),
                          ),
                        );
                      },
              ),
          ],
        ),
        footer: Row(
          children: [
            if (controller.loading) ...[
              const CupertinoActivityIndicator(),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                controller.loading && comparisons.isEmpty
                    ? l.sourceSelectionSearching
                    : l.sourceSelectionFound(
                        _filtering ? shown.length : comparisons.length,
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _closeButton(),
          ],
        ),
      );
    },
  );
}

class _VersionFace {
  const _VersionFace({
    required this.chips,
    required this.note,
    required this.resolution,
    required this.range,
    required this.video,
    required this.subtitle,
    required this.audio,
    required this.rank,
    required this.bitrate,
  });

  final List<String> chips;
  final String? note;
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

String? _releaseNote(String? detail, List<String> chips) {
  if (detail == null || detail.trim().isEmpty) return null;
  var text = detail;
  final ordered = [...chips]..sort((a, b) => b.length.compareTo(a.length));
  for (final chip in ordered) {
    if (chip.isEmpty) continue;
    text = text.replaceAll(chip, ' ');
  }
  text = text.replaceAll(RegExp(r'[·\s]+'), ' ').trim();
  if (text.isEmpty) return null;
  return text;
}

_VersionFace _faceFor(ItemMediaSource source) {
  final view = source.presentation;
  final parts = view.headline == '—'
      ? const <String>[]
      : view.headline
            .split(' · ')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();
  final chips = <String>[];
  String? resolution;
  String? range;
  String? audio;
  final video = _videoFromStreams(source) ?? _videoFromParts(parts);
  final subtitle = _subtitleKey(source);
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
      chips.add(parts.join(' · '));
    } else {
      for (final token in quality) {
        if (_resolutionRank(token) > 0) resolution ??= token;
        range ??= _rangeLabel(token);
        if (!chips.contains(token)) chips.add(token);
      }
      if (parts.length >= 2 && !chips.contains(parts[1])) chips.add(parts[1]);
      if (parts.length >= 3) {
        audio = _audioKey(parts[2]);
        if (!chips.contains(parts[2])) chips.add(parts[2]);
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
  if (size != null && !chips.contains(size)) chips.add(size);
  if (rate != null && !chips.contains(rate)) chips.add(rate);
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
    if (resolution != null && !chips.contains(resolution)) {
      chips.insert(0, resolution);
    }
  }
  return _VersionFace(
    chips: chips,
    note: _releaseNote(view.detail, chips),
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
  final faces = <_VersionFace>[];
  for (final source in item.mediaSources) {
    final face = _faceFor(source);
    if (face.chips.isNotEmpty ||
        face.note != null ||
        face.resolution != null ||
        face.range != null ||
        face.video != null ||
        face.subtitle != null ||
        face.audio != null) {
      faces.add(face);
    }
  }
  return faces;
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

int _bestScore(SourceComparison comparison) {
  var best = 0;
  for (final face in _versionFaces(comparison.source.item)) {
    final score = face.rank * 1000000000 + face.bitrate;
    if (score > best) best = score;
  }
  return best;
}

String _versionKey(SourceComparison comparison, int index) =>
    '${comparison.source.reference.account.configuredServerId}:${comparison.source.reference.itemId}:$index';

List<String> _facetOptions(
  List<SourceComparison> comparisons,
  String? Function(_VersionFace face) read, [
  List<String> order = _resolutionOrder,
]) {
  final found = <String>{};
  for (final comparison in comparisons) {
    for (final face in _versionFaces(comparison.source.item)) {
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

Map<String, String> _bestBadges(
  List<SourceComparison> shown,
  AppLocalizations l10n,
) {
  final ranked = <_RankedVersion>[];
  for (final comparison in shown) {
    final faces = _versionFaces(comparison.source.item);
    for (var index = 0; index < faces.length; index++) {
      ranked.add(
        _RankedVersion(
          _versionKey(comparison, index),
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

String _sourceMeta(AppLocalizations l10n, MediaItem item) {
  final watched = _watchedLabel(l10n, item.userData.lastPlayedDate);
  return [
    item.name,
    if (item.isSeries && (item.childCount ?? 0) > 0)
      l10n.sourceSelectionEpisodeCount(item.childCount!),
    ?watched,
  ].join(' · ');
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

String _episodeStatusLabel(AppLocalizations l10n, EpisodeLookupStatus status) {
  return switch (status) {
    EpisodeLookupStatus.missing => l10n.aggregationMissingEpisode,
    EpisodeLookupStatus.queryFailed => l10n.aggregationEpisodeFailed,
    EpisodeLookupStatus.confirmed => l10n.aggregationEpisodeConfirmed,
    EpisodeLookupStatus.uncertain ||
    EpisodeLookupStatus.conflict ||
    EpisodeLookupStatus.ambiguous => l10n.aggregationEpisodeUncertain,
  };
}

String _serverInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first);
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
    return AppButton(
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      variant: AppButtonVariant.filled,
      style: AppButtonStyle(
        backgroundColor: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        foregroundColor: foreground,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: const StadiumBorder(),
        side: BorderSide(
          color: selected
              ? AppInk.transparent
              : AppEdge.of(scheme.brightness, strong: true),
        ),
        textStyle: theme.textTheme.labelMedium,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 4)],
          if (mark != null) ...[
            Text(mark!),
            if (label != mark) const SizedBox(width: 4),
          ],
          if (mark == null || label != mark) Text(label),
          const SizedBox(width: 2),
          const Icon(CupertinoIcons.chevron_down, size: 12),
        ],
      ),
    );
  }
}

class _LockedServerRow extends StatelessWidget {
  const _LockedServerRow({
    required this.server,
    required this.lockedLabel,
    required this.unlockLabel,
    required this.enabled,
    required this.onUnlock,
  });

  final SavedServer server;
  final String lockedLabel;
  final String unlockLabel;
  final bool enabled;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        key: ValueKey('source-selection-server-${server.id}'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: AppEdge.of(scheme.brightness, strong: true),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.lock,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      lockedLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AppButton(
                key: ValueKey('source-selection-verify-${server.id}'),
                onPressed: enabled ? onUnlock : null,
                variant: AppButtonVariant.tinted,
                child: Text(unlockLabel),
              ),
            ],
          ),
        ),
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
    this.caution,
    this.lookup,
  });

  final Key cardKey;
  final String serverName;
  final String meta;
  final String? caution;
  final List<_VersionFace> faces;
  final List<String?> badges;
  final VoidCallback? onOpen;
  final Widget? lookup;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final fill = _hover
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerHigh;
    return Padding(
      key: widget.cardKey,
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: AppEdge.of(scheme.brightness, strong: true),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSurfaceAction(
              onTap: widget.onOpen,
              onHover: (value) => setState(() => _hover = value),
              borderRadius: BorderRadius.circular(AppRadii.lg),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  12,
                  12,
                  widget.lookup == null ? 12 : 4,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ServerMark(name: widget.serverName),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.serverName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.meta,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (widget.caution != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              widget.caution!,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onTertiaryContainer,
                              ),
                            ),
                          ],
                          for (
                            var index = 0;
                            index < widget.faces.length;
                            index++
                          )
                            _VersionBlock(
                              face: widget.faces[index],
                              badge: index < widget.badges.length
                                  ? widget.badges[index]
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.lookup != null)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                  child: widget.lookup,
                ),
              ),
          ],
        ),
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
    final scheme = theme.colorScheme;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Text(
        _serverInitial(name),
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _VersionBlock extends StatelessWidget {
  const _VersionBlock({required this.face, required this.badge});
  final _VersionFace face;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    if (face.note == null && face.chips.isEmpty && badge == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (face.note != null)
            Text(
              face.note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          if (face.chips.isNotEmpty || badge != null) ...[
            if (face.note != null) const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final chip in face.chips) _SpecChip(label: chip),
                if (badge != null) _SpecChip(label: badge!, emphasize: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SpecChip extends StatelessWidget {
  const _SpecChip({required this.label, this.emphasize = false});
  final String label;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasize ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: emphasize
            ? null
            : Border.all(color: AppEdge.of(scheme.brightness)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: emphasize ? scheme.onPrimary : scheme.onSurface,
            fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _EpisodeStatusRow extends StatelessWidget {
  const _EpisodeStatusRow({
    required this.label,
    required this.retryLabel,
    required this.onRetry,
    required this.onOpen,
  });

  final String label;
  final String retryLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: AppEdge.of(scheme.brightness, strong: true),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSurfaceAction(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
            ),
            if (onRetry != null)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                  child: AppButton(
                    onPressed: onRetry,
                    variant: AppButtonVariant.plain,
                    child: Text(retryLabel),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
