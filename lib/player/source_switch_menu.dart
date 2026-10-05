import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../aggregation/query/same_source_query.dart';
import '../aggregation/query/aggregation_query.dart';
import '../app/l10n/app_localizations.dart';
import '../library/episode_mapping_dialog.dart';
import 'playback_models.dart';
import 'player_window_host.dart';
import 'player_controller.dart';

class SourceSwitchButton extends StatelessWidget {
  const SourceSwitchButton({super.key, required this.controller});
  final PlayerController controller;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('player-manual-switch'),
    tooltip: AppLocalizations.of(context).switchManual,
    icon: const Icon(Icons.swap_horiz),
    onPressed: () => showSourceSwitchMenu(context, controller),
  );
}

Future<void> showSourceSwitchMenu(
  BuildContext context,
  PlayerController controller,
) async {
  controller.setControlsPinned(true, owner: controller);
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => SourceSwitchMenu(controller: controller),
    );
  } finally {
    await controller.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
    controller.setControlsPinned(false, owner: controller);
  }
}

/// UI only: all selection, preflight, confirmation and restoration go through
/// the same transaction used by host IPC. No UI fallback changes auth.client.
class SourceSwitchMenu extends StatefulWidget {
  const SourceSwitchMenu({super.key, required this.controller});
  final PlayerController controller;
  @override
  State<SourceSwitchMenu> createState() => _SourceSwitchMenuState();
}

class _SourceSwitchMenuState extends State<SourceSwitchMenu> {
  SameSourceQueryController? _comparison;
  Map<String, dynamic>? _hostCatalogue;
  final Map<SourceReference, List<PlaybackMediaSource>> _episodeVersions = {};
  bool _busy = false;
  bool _locking = false;
  String? _error;
  int? _audio, _subtitle;
  bool _defaultAudio = false, _subtitleOff = false;
  PlaybackSwitchPlan? _seenPlan;
  PlayerController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (!identical(_seenPlan, c.switchConfirmation)) {
      _seenPlan = c.switchConfirmation;
      _audio = null;
      _subtitle = null;
      _defaultAudio = false;
      _subtitleOff = false;
    }
    if (mounted) {
      setState(() {});
      if (c.permissionRevoked) {
        final route = ModalRoute.of(context);
        // Imperative dialogs are not cleared by a GoRouter stack replacement.
        // Remove this route after its redacted frame, without a reverse
        // animation retaining any source names or selectable candidates.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && route?.isActive == true) {
            Navigator.of(context).removeRoute(route!);
          }
        });
      }
    }
  }

  Future<void> _load() async {
    final runtime = c.runtime, origin = c.origin;
    if (runtime == null || origin == null) {
      if (c.switchDispatcher == null) return;
      await _act(() async {
        _hostCatalogue = await c.switchDispatcher!({
          'action': 'catalogue',
          'item': c.itemId,
        });
      });
      return;
    }
    try {
      final dto = await origin.permit.dispatch(
        (client) => client.getItem(origin.work.itemId),
      );
      if (!mounted) return;
      final comparison = SameSourceQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      _comparison = comparison;
      comparison.addListener(_changed);
      await comparison.start(
        origin: QueryItem(origin.work, origin.libraryId, dto),
        scope: QueryScope(region: origin.source.account.region),
      );
      if (c.item?.isEpisode != true) {
        for (final candidate in comparison.comparisons.where(
          (candidate) => candidate.decision.confirmed,
        )) {
          try {
            final target = await runtime.resolve(
              PlayerOpenRequest(
                itemId: candidate.source.reference.itemId,
                source: candidate.source.reference,
                work: candidate.source.reference.item,
                libraryId: candidate.source.libraryId,
                regionGeneration: origin.permit.regionGeneration,
              ),
            );
            final info = await target.permit.dispatch(
              (client) => client.getPlaybackInfo(itemId: target.source.itemId),
            );
            if (mounted && origin.permit.isValid && target.permit.isValid) {
              _episodeVersions[candidate.source.reference] = info.mediaSources;
              setState(() {});
            }
          } catch (_) {
            if (mounted && origin.permit.isValid) {
              setState(
                () =>
                    _error = AppLocalizations.of(context).sourceOperationFailed,
              );
            }
          }
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).sourceOperationFailed,
        );
      }
    }
  }

  Future<void> _lookupHostEpisode(Map<String, dynamic> target) async {
    final verified = await confirmEpisodeMapping(context);
    if (!mounted || verified == null || c.permissionRevoked) return;
    await _act(() async {
      _hostCatalogue = await c.switchDispatcher!({
        'action': 'catalogue',
        'item': c.itemId,
        'mapTarget': target['target'],
        'mappingAccepted': verified,
      });
    });
  }

  Future<void> _lookupEpisode(SourceComparison candidate) async {
    final comparison = _comparison;
    final origin = c.origin;
    final item = c.item;
    if (comparison == null || origin == null || item?.isEpisode != true) return;
    final verified = await confirmEpisodeMapping(context);
    if (!mounted || verified == null || !origin.permit.isValid) return;
    await _act(() async {
      final episode = EpisodeSource.fromEmby(origin.source, item!);
      await comparison.lookupEpisode(
        target: candidate.source,
        episode: verified ? withConfirmedEpisodeMapping(episode) : episode,
        verifiedNumberingScheme: verified
            ? userConfirmedEpisodeNumbering
            : null,
      );
      if (!mounted || !origin.permit.isValid) return;
      final result = comparison.episodes
          .where((e) => e.target == candidate.source.reference)
          .firstOrNull;
      if (result?.lookup.status != EpisodeLookupStatus.confirmed) return;
      final target = await c.runtime!.resolve(
        PlayerOpenRequest(
          itemId: result!.lookup.source!.reference.itemId,
          source: result.lookup.source!.reference,
          work: candidate.source.reference.item,
          libraryId: candidate.source.libraryId,
          regionGeneration: origin.permit.regionGeneration,
        ),
      );
      final info = await target.permit.dispatch(
        (client) => client.getPlaybackInfo(itemId: target.source.itemId),
      );
      if (mounted && origin.permit.isValid && target.permit.isValid) {
        _episodeVersions[candidate.source.reference] = info.mediaSources;
      }
    });
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) _error = AppLocalizations.of(context).sourceOperationFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lock() async {
    if (_locking) return;
    setState(() => _locking = true);
    try {
      // Safety revocation is independent of catalogue/preflight activity.
      // It must cancel in-flight work, not wait for that work to enable UI.
      await c.lockPrivateRegion();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).sourceOperationFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _locking = false);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _comparison?.removeListener(_changed);
    _comparison?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (c.permissionRevoked) {
      return AlertDialog(content: Text(l.aggregationPrivateLocked));
    }
    final origin = c.origin;
    final plan = c.switchConfirmation;
    final servers = origin == null
        ? const []
        : c.runtime!.registry.project(origin.source.account.region);
    final server = servers
        .where((s) => s.id == origin?.source.account.configuredServerId)
        .firstOrNull;
    final actualAccount =
        c.activeOrigin?.source.account ?? origin?.source.account;
    final actualServer = servers
        .where((s) => s.id == actualAccount?.configuredServerId)
        .firstOrNull;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AlertDialog(
        title: Text(l.switchManual),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            children: [
              Text(
                '${l.switchActual}: ${c.activeMediaSourceId == null ? l.aggregationUnknown : actualServer?.displayName ?? _hostCatalogue?['serverName'] ?? c.client.baseUrl?.host ?? '—'} · ${c.activeMediaSourceId ?? '—'} · ${c.activeLineId ?? '—'}',
              ),
              if (c.preferenceResolution?.failure != null)
                Text('${c.preferenceResolution!.failure}'),
              if (_busy ||
                  c.pendingMediaSourceId != null ||
                  c.pendingLineId != null) ...[
                const LinearProgressIndicator(),
                Text(l.switchPending),
              ],
              if (_error != null)
                Text(_error!, key: const Key('switch-menu-error')),
              if (c.disconnectDetail != null) Text(c.disconnectDetail!),
              if (c.trackFailure != null) Text(c.trackFailure!),
              Text(
                l.switchLine,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final line in server?.lines ?? [])
                ListTile(
                  title: Text(line.nickname ?? line.hostLabel),
                  selected: Uri.parse(line.address) == c.client.baseUrl,
                  onTap: _busy ? null : () => _act(() => c.switchLine(line.id)),
                ),
              for (final line
                  in (_hostCatalogue?['lines'] as List? ?? const []))
                ListTile(
                  title: Text(line['label'] as String),
                  onTap: _busy
                      ? null
                      : () => _act(() => c.switchLine(line['id'] as String)),
                ),
              Text(
                l.switchVersion,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final source in c.mediaSources)
                ListTile(
                  key: ValueKey('switch-version-${source.id}'),
                  title: Text(source.presentation.headline),
                  selected: source.id == c.activeMediaSourceId,
                  onTap: _busy
                      ? null
                      : () => _act(() => c.switchMediaSource(source.id)),
                ),
              Text(
                l.switchCrossSource,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final target
                  in (_hostCatalogue?['targets'] as List? ?? const []))
                ListTile(
                  key: ValueKey(
                    'switch-host-target-${target['key'] ?? target['label']}',
                  ),
                  title: Text(target['label'] as String),
                  subtitle: Text(_reason(target['reason'] as String)),
                  onTap: _busy
                      ? null
                      : target['canMap'] == true
                      ? () => _lookupHostEpisode(
                          Map<String, dynamic>.from(target as Map),
                        )
                      : target['confirmed'] != true
                      ? null
                      : () => _act(
                          () => c.switchHostTarget(
                            Map<String, dynamic>.from(target as Map),
                          ),
                        ),
                ),
              if (c.item?.isEpisode == true)
                Text(l.aggregationEpisodeUncertain),
              for (final candidate
                  in _comparison?.comparisons ?? <SourceComparison>[]) ...[
                Text(
                  '${candidate.source.item.name} · ${candidate.source.reference.account.configuredServerId} · ${candidate.decision.reason}',
                ),
                if (c.item?.isEpisode == true && candidate.decision.confirmed)
                  TextButton(
                    key: ValueKey(
                      'switch-episode-map-${candidate.source.reference.account.configuredServerId}',
                    ),
                    onPressed: _busy ? null : () => _lookupEpisode(candidate),
                    child: Text(l.aggregationEpisodeLookup),
                  ),
                for (final result in _comparison!.episodes.where(
                  (e) => e.target == candidate.source.reference,
                ))
                  Text(
                    result.lookup.status == EpisodeLookupStatus.confirmed
                        ? l.aggregationEpisodeConfirmed
                        : result.lookup.status == EpisodeLookupStatus.missing
                        ? l.aggregationMissingEpisode
                        : result.lookup.status ==
                              EpisodeLookupStatus.queryFailed
                        ? l.aggregationEpisodeFailed
                        : l.aggregationEpisodeUncertain,
                  ),
                for (final version
                    in _episodeVersions[candidate.source.reference] ??
                        const <PlaybackMediaSource>[])
                  ListTile(
                    key: ValueKey(
                      'switch-target-${candidate.source.reference.account.configuredServerId}-${version.id}',
                    ),
                    title: Text(version.name ?? version.id),
                    onTap: _busy || !candidate.decision.confirmed
                        ? null
                        : () => _act(
                            () => c.switchConfirmedSource(
                              candidate,
                              version.id,
                              episode: c.item?.isEpisode == true
                                  ? _comparison!.episodes
                                        .where(
                                          (e) =>
                                              e.target ==
                                              candidate.source.reference,
                                        )
                                        .firstOrNull
                                  : null,
                            ),
                          ),
                  ),
              ],
              if (plan != null) ...[
                Text(l.switchTimeline),
                Text(
                  '${plan.positionTicks / 10000000}s → ${plan.targetRuntimeTicks == null ? '—' : plan.targetRuntimeTicks! / 10000000}s',
                ),
                if (plan.audioNeedsChoice || plan.subtitleNeedsChoice)
                  Text(l.switchMissingLanguage),
                if (plan.audioNeedsChoice) ...[
                  for (final track in plan.audioChoices)
                    ListTile(
                      title: Text(
                        track.displayTitle ??
                            track.language ??
                            '${track.index}',
                      ),
                      selected: track.index == _audio,
                      onTap: () => setState(() {
                        _audio = track.index;
                        _defaultAudio = false;
                      }),
                    ),
                  CheckboxListTile(
                    title: Text(l.switchDefaultAudio),
                    value: _defaultAudio,
                    onChanged: (value) => setState(() {
                      _defaultAudio = value == true;
                      _audio = null;
                    }),
                  ),
                ],
                if (plan.subtitleNeedsChoice) ...[
                  for (final track in plan.subtitleChoices)
                    ListTile(
                      title: Text(
                        track.displayTitle ??
                            track.language ??
                            '${track.index}',
                      ),
                      selected: track.index == _subtitle,
                      onTap: () => setState(() {
                        _subtitle = track.index;
                        _subtitleOff = false;
                      }),
                    ),
                  CheckboxListTile(
                    title: Text(l.switchSubtitlesOff),
                    value: _subtitleOff,
                    onChanged: (value) => setState(() {
                      _subtitleOff = value == true;
                      _subtitle = null;
                    }),
                  ),
                ],
                Wrap(
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _act(
                              () => c.confirmMediaSourceSwitch(
                                SwitchResumeChoice.cancel,
                              ),
                            ),
                      child: Text(l.cancelAction),
                    ),
                    TextButton(
                      onPressed: _busy || !plan.canTryCurrentPosition
                          ? null
                          : () => _confirm(SwitchResumeChoice.currentPosition),
                      child: Text(l.switchCurrentPosition),
                    ),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm(SwitchResumeChoice.beginning),
                      child: Text(l.switchBeginning),
                    ),
                  ],
                ),
              ],
              if (c.canRestoreOriginalSource)
                TextButton(
                  onPressed: _busy ? null : () => _act(c.restoreOriginalSource),
                  child: Text(l.switchRestore),
                ),
            ],
          ),
        ),
        actions: [
          if ((c.origin?.source.account.region ??
                  c.openRequest?.source?.account.region) ==
              AccessRegion.private)
            FilledButton(
              key: const Key('player-lock-private'),
              onPressed: _locking ? null : _lock,
              child: Text(l.privateLock),
            ),
          TextButton(
            key: const Key('source-switch-close'),
            onPressed: () async {
              if (c.switchConfirmation != null) {
                await c.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l.cancelAction),
          ),
        ],
      ),
    );
  }

  String _reason(String reason) {
    final l = AppLocalizations.of(context);
    return switch (reason) {
      'confirmed' => l.aggregationEpisodeConfirmed,
      'missing' => l.aggregationMissingEpisode,
      'queryFailed' => l.aggregationEpisodeFailed,
      'uncertain' => l.aggregationEpisodeUncertain,
      'unknownVersion' => l.aggregationUnknown,
      'versionQueryFailed' => l.aggregationFailed,
      _ => reason,
    };
  }

  Future<void> _confirm(SwitchResumeChoice choice) => _act(
    () => c.confirmMediaSourceSwitch(
      choice,
      audioIndex: _audio,
      subtitleIndex: _subtitle,
      acceptDefaultAudio: _defaultAudio,
      turnSubtitlesOff: _subtitleOff,
    ),
  );
}
