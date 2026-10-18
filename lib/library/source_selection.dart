import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../media_server/media_server_client.dart';
import '../aggregation/query/aggregation_query.dart';
import '../aggregation/query/same_source_query.dart';
import '../auth/auth_scope.dart';
import '../auth/server_entry_coordinator.dart';
import '../auth/server_password_form.dart';
import '../auth/tv_server_access_page.dart';
import '../auth/server_list_store.dart';
import '../app/l10n/app_localizations.dart';
import '../app/presentation_environment.dart';
import '../search/search_action.dart';
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
    required this.content,
    required this.action,
  });
  final String title;
  final Widget content;
  final Widget action;
  @override
  Widget build(BuildContext context) => AppModalFrame(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height - 48,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    key: const Key('source-selection-title'),
                    style: AppUiTheme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const Key('source-selection-content'),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: content,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Align(alignment: Alignment.centerRight, child: action),
          ),
        ],
      ),
    ),
  );
}

/// Mounted in every gated detail tree, independent of global search.
class SourceSelectionAction extends StatefulWidget {
  const SourceSelectionAction({super.key, this.itemId});

  /// Ordinary selected-server details resolve the same permit as playback,
  /// without opening a decoder or publishing a target-server entry.
  final String? itemId;
  @override
  State<SourceSelectionAction> createState() => _SourceSelectionActionState();
}

class _SourceSelectionActionState extends State<SourceSelectionAction> {
  bool _loading = false;
  Future<void> _show() async {
    final scopedOrigin = DetailSourceScope.maybeOf(context);
    final runtime = PlayerScope.of(context).runtime;
    if (runtime == null ||
        (scopedOrigin != null && !scopedOrigin.permit.isValid)) {
      return;
    }
    final route = ModalRoute.of(context);
    bool stillHere() => route?.isCurrent != false;
    setState(() => _loading = true);
    SameSourceQueryController? controller;
    try {
      final origin =
          scopedOrigin ??
          await runtime.resolve(PlayerOpenRequest(itemId: widget.itemId!));
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
      unawaited(controller.start(origin: item, scope: QueryScope()));
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

  @override
  Widget build(BuildContext context) {
    final origin = DetailSourceScope.maybeOf(context);
    if ((origin == null && widget.itemId == null) ||
        (origin != null && !origin.permit.isValid)) {
      return const SizedBox.shrink();
    }
    return AppButton.icon(
      key: const Key('source-selection-open'),
      onPressed: _loading ? null : _show,
      icon: const Icon(CupertinoIcons.arrow_left_right),
      label: Text(AppLocalizations.of(context).sourceSelectionAction),
      variant: AppButtonVariant.filled,
    );
  }
}

class _SourceSelectionDialog extends StatefulWidget {
  const _SourceSelectionDialog({required this.controller, this.episode});
  final SameSourceQueryController controller;
  final EpisodeSource? episode;
  @override
  State<_SourceSelectionDialog> createState() => _SourceSelectionDialogState();
}

class _SourceSelectionDialogState extends State<_SourceSelectionDialog> {
  SameSourceQueryController get controller => widget.controller;
  EpisodeSource? get episode => widget.episode;
  SavedServer? _passwordTarget;
  ServerEntryTicket? _pendingEntry;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pendingEntry?.cancel();
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      if (controller.origin == null) {
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
          ]..sort(
            (a, b) => (b.decision.confirmed ? 1 : 0).compareTo(
              a.decision.confirmed ? 1 : 0,
            ),
          );
      final passwordTarget = _passwordTarget;
      if (passwordTarget != null) {
        return _DialogKeyboard(
          autofocus: !PresentationScope.of(context).isTv,
          child: _SourceSelectionFrame(
            title: l.sourceSelectionPasswordTitle,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(passwordTarget.displayName),
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
            action: AppButton(
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
      return _DialogKeyboard(
        autofocus: !PresentationScope.of(context).isTv,
        child: _SourceSelectionFrame(
          title: l.sourceSelectionAction,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) Text(_error!),
              Text(
                controller.origin!.item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppUiTheme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(l.sourceSelectionHint),
              for (final server in servers)
                if (!access.allows(server.id) &&
                    controller.entryFor(server.id)?.isValid != true)
                  AppListTile(
                    key: ValueKey('source-selection-server-${server.id}'),
                    leading: const Icon(CupertinoIcons.lock),
                    title: Text(server.displayName),
                    subtitle: Text(l.serversLocked),
                    trailing: AppButton(
                      key: ValueKey('source-selection-verify-${server.id}'),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _passwordTarget = server;
                              _error = null;
                            }),
                      variant: AppButtonVariant.plain,
                      child: Text(l.sourceSelectionUnlock),
                    ),
                  ),
              if (!controller.complete)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CupertinoActivityIndicator()),
                ),
              if (controller.complete &&
                  comparisons.isEmpty &&
                  servers.every(
                    (server) =>
                        access.allows(server.id) ||
                        controller.entryFor(server.id)?.isValid == true,
                  ))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(l.sourceSelectionEmpty),
                ),
              if (controller.sources.any((source) => source.failed))
                AppButton(
                  onPressed: _busy
                      ? null
                      : () {
                          for (final source in controller.sources.where(
                            (s) => s.failed,
                          )) {
                            unawaited(controller.retry(source.key));
                          }
                        },
                  variant: AppButtonVariant.plain,
                  child: Text(l.sourceSelectionRetry),
                ),
              if (controller.sources.any(
                (source) => source.hasMore && !source.failed,
              ))
                AppButton(
                  onPressed: _busy
                      ? null
                      : () {
                          for (final source in controller.sources.where(
                            (s) => s.hasMore && !s.failed,
                          )) {
                            unawaited(controller.loadMore(source.key));
                          }
                        },
                  variant: AppButtonVariant.plain,
                  child: Text(l.sourceSelectionMore),
                ),
              for (final comparison in comparisons)
                AppListTile(
                  key: ValueKey(
                    'source-selection-item-${comparison.source.reference.account.configuredServerId}-${comparison.source.reference.itemId}',
                  ),
                  title: Text(
                    servers
                            .where(
                              (s) =>
                                  s.id ==
                                  comparison
                                      .source
                                      .reference
                                      .account
                                      .configuredServerId,
                            )
                            .firstOrNull
                            ?.displayName ??
                        '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      comparison.source.item.name,
                      if (comparison.source.item.mediaSources.firstOrNull
                          case final version?)
                        if (version.presentation.headline != '—')
                          version.presentation.headline,
                      if (!comparison.decision.confirmed)
                        l.sourceSelectionCheckDetails,
                    ].join(' · '),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing:
                      episode != null &&
                          comparison.decision.confirmed &&
                          comparison.source.item.isSeries
                      ? AppButton(
                          onPressed: () =>
                              _lookupEpisode(context, comparison.source),
                          variant: AppButtonVariant.plain,
                          child: Text(l.aggregationEpisodeLookup),
                        )
                      : null,
                  onTap: _busy ? null : () => _openTarget(comparison.source),
                ),
              for (final result in controller.episodes)
                AppListTile(
                  title: Text(
                    result.lookup.status == EpisodeLookupStatus.missing
                        ? l.aggregationMissingEpisode
                        : result.lookup.status ==
                              EpisodeLookupStatus.queryFailed
                        ? l.aggregationEpisodeFailed
                        : result.lookup.status == EpisodeLookupStatus.confirmed
                        ? l.aggregationEpisodeConfirmed
                        : l.aggregationEpisodeUncertain,
                  ),

                  trailing:
                      result.lookup.status == EpisodeLookupStatus.queryFailed
                      ? AppButton(
                          onPressed: () => _lookupEpisode(
                            context,
                            controller.comparisons
                                .firstWhere(
                                  (c) => c.source.reference == result.target,
                                )
                                .source,
                          ),
                          variant: AppButtonVariant.plain,
                          child: Text(l.aggregationRetry),
                        )
                      : null,
                  onTap: result.lookup.source == null
                      ? null
                      : () {
                          final target = controller.comparisons
                              .firstWhere(
                                (c) => c.source.reference == result.target,
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
          action: AppButton(
            key: const Key('source-selection-close'),
            autofocus: PresentationScope.of(context).isTv,
            onPressed: () => Navigator.pop(context),
            variant: AppButtonVariant.plain,
            child: Text('关闭'),
          ),
        ),
      );
    },
  );
}
