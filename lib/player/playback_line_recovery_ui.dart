import 'dart:async';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../media_server/playback.dart';
import '../media_server/errors.dart';
import 'player_controller.dart';

typedef PlaybackSwitchChoiceCallback = Future<void> Function(
  SwitchResumeChoice choice, {
  int? audioIndex,
  int? subtitleIndex,
  bool acceptDefaultAudio,
  bool turnSubtitlesOff,
});

String? playbackClassifiedFailureTitle(
  MediaServerFailureKind? kind,
  AppLocalizations l,
) => switch (kind) {
  MediaServerFailureKind.certificate => l.playbackCertificateStopped,
  MediaServerFailureKind.forbidden => l.playbackPermissionStopped,
  MediaServerFailureKind.rateLimited => l.playbackRateLimited,
  _ => null,
};

/// The native video remains a sibling; this only presents an actionable status.
class PlaybackLineRecoveryPanel extends StatefulWidget {
  const PlaybackLineRecoveryPanel({
    super.key,
    required this.recovering,
    required this.onCancel,
    required this.onChooseLines,
    required this.onRetry,
    this.lineName,
    this.failure,
    this.primaryFocusNode,
    this.failureKind,
    this.retryAfter,
    this.onDismiss,
  });
  final bool recovering;
  final String? lineName, failure;
  final FocusNode? primaryFocusNode;
  final MediaServerFailureKind? failureKind;
  final DateTime? retryAfter;
  final VoidCallback onCancel, onChooseLines, onRetry;
  final VoidCallback? onDismiss;

  @override
  State<PlaybackLineRecoveryPanel> createState() =>
      _PlaybackLineRecoveryPanelState();
}

class _PlaybackLineRecoveryPanelState extends State<PlaybackLineRecoveryPanel> {
  Timer? _retryTimer;
  final _waitingFocus = FocusNode(
    debugLabel: 'playback retry wait alternative',
  );

  Duration get _retryWait =>
      widget.retryAfter?.difference(DateTime.now()) ?? Duration.zero;

  @override
  void initState() {
    super.initState();
    _scheduleRetryUpdate(requestFocus: true);
  }

  @override
  void didUpdateWidget(PlaybackLineRecoveryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryAfter != widget.retryAfter) {
      _scheduleRetryUpdate(requestFocus: true);
    }
  }

  void _scheduleRetryUpdate({bool requestFocus = false}) {
    _retryTimer?.cancel();
    final wait = _retryWait;
    if (wait <= Duration.zero) return;
    if (requestFocus && widget.primaryFocusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _retryWait > Duration.zero) _waitingFocus.requestFocus();
      });
    }
    _retryTimer = Timer(
      wait < const Duration(seconds: 1) ? wait : const Duration(seconds: 1),
      () {
        if (!mounted) return;
        setState(() {});
        _scheduleRetryUpdate();
      },
    );
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _waitingFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final recovering = widget.recovering;
    final lineName = widget.lineName, failure = widget.failure;
    final retryWait = _retryWait;
    final waiting = retryWait > Duration.zero;
    final retryLabel = waiting
        ? l.playbackRetryAfter((retryWait.inMicroseconds / 1000000).ceil())
        : switch (widget.failureKind) {
            MediaServerFailureKind.certificate => l.playbackRetryAfterRepair,
            MediaServerFailureKind.forbidden => l.playbackRetryAfterPermission,
            _ => l.retry,
          };
    return Column(
      key: const Key('playback-line-recovery'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (recovering) const CupertinoActivityIndicator(),
                const SizedBox(height: 12),
                Text(
                  recovering
                      ? l.playbackReconnecting
                      : playbackClassifiedFailureTitle(widget.failureKind, l) ??
                            l.playbackRecoveryStopped,
                  textAlign: TextAlign.center,
                ),
                if (lineName != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    lineName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (!recovering && failure != null) ...[
                  const SizedBox(height: 8),
                  Text(failure, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 8),
                Text(
                  l.playbackRecoveryPositionKept,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              AppButton(
                key: Key(
                  recovering
                      ? 'playback-recovery-cancel'
                      : 'playback-recovery-retry',
                ),
                autofocus: true,
                focusNode: widget.primaryFocusNode,
                onPressed: recovering
                    ? widget.onCancel
                    : waiting
                    ? null
                    : widget.onRetry,
                child: Text(recovering ? l.cancelAction : retryLabel),
              ),
              AppButton(
                key: const Key('playback-recovery-lines'),
                focusNode: _waitingFocus,
                autofocus: waiting,
                onPressed: widget.onChooseLines,
                child: Text(l.playbackChooseLine),
              ),
              if (!recovering && widget.onDismiss != null)
                AppButton(
                  key: const Key('playback-recovery-close'),
                  onPressed: widget.onDismiss,
                  child: Text(l.closePlayer),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A user's choices are local to this exact plan. No default silently opts in
/// to replacing an audio track, disabling subtitles, or starting over.
class PlaybackSwitchConfirmation extends StatefulWidget {
  const PlaybackSwitchConfirmation({
    super.key,
    required this.plan,
    required this.onConfirm,
    this.cancelFocusNode,
  });
  final PlaybackSwitchPlan plan;
  final PlaybackSwitchChoiceCallback onConfirm;
  final FocusNode? cancelFocusNode;
  @override
  State<PlaybackSwitchConfirmation> createState() =>
      _PlaybackSwitchConfirmationState();
}

class _PlaybackSwitchConfirmationState
    extends State<PlaybackSwitchConfirmation> {
  int? _audio, _subtitle;
  bool _defaultAudio = false, _subtitlesOff = false, _busy = false;
  String? _error;
  bool get _ready =>
      (!widget.plan.audioNeedsChoice || _audio != null || _defaultAudio) &&
      (!widget.plan.subtitleNeedsChoice || _subtitle != null || _subtitlesOff);

  @override
  void didUpdateWidget(PlaybackSwitchConfirmation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plan, widget.plan)) {
      _audio = null;
      _subtitle = null;
      _defaultAudio = false;
      _subtitlesOff = false;
      _busy = false;
      _error = null;
    }
  }

  Future<void> _confirm(SwitchResumeChoice choice) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(
        choice,
        audioIndex: _audio,
        subtitleIndex: _subtitle,
        acceptDefaultAudio: _defaultAudio,
        turnSubtitlesOff: _subtitlesOff,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).playbackLineFailureHint,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _track(MediaStreamInfo track, {required bool audio}) => AppListTile(
    key: ValueKey(
      'playback-confirm-${audio ? 'audio' : 'subtitle'}-${track.index}',
    ),
    title: Text(track.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    selected: audio ? _audio == track.index : _subtitle == track.index,
    onTap: _busy
        ? null
        : () => setState(() {
            if (audio) {
              _audio = track.index;
              _defaultAudio = false;
            } else {
              _subtitle = track.index;
              _subtitlesOff = false;
            }
          }),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), plan = widget.plan;
    return Column(
      key: const Key('playback-switch-confirmation'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.playbackSwitchNeedsChoice,
                  style: AppUiTheme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (!plan.canTryCurrentPosition)
                  Text(l.playbackPositionUnavailable)
                else if (!plan.timelineConfirmed && plan.positionTicks > 0)
                  Text(l.playbackTimelineUncertain),
                if (plan.audioNeedsChoice) ...[
                  const SizedBox(height: 12),
                  Text(l.playbackAudioUnavailable),
                  for (final track in plan.audioChoices)
                    _track(track, audio: true),
                  AppListTile(
                    key: const Key('playback-confirm-default-audio'),
                    title: Text(l.playbackUseDefaultAudio),
                    selected: _defaultAudio,
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _defaultAudio = true;
                            _audio = null;
                          }),
                  ),
                ],
                if (plan.subtitleNeedsChoice) ...[
                  const SizedBox(height: 12),
                  Text(l.playbackSubtitleUnavailable),
                  for (final track in plan.subtitleChoices)
                    _track(track, audio: false),
                  AppListTile(
                    key: const Key('playback-confirm-subtitles-off'),
                    title: Text(l.playbackContinueWithoutSubtitles),
                    selected: _subtitlesOff,
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _subtitlesOff = true;
                            _subtitle = null;
                          }),
                  ),
                ],
                if (_error != null) Text(_error!),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              AppButton(
                key: const Key('playback-confirm-cancel'),
                autofocus: true,
                focusNode: widget.cancelFocusNode,
                onPressed: _busy
                    ? null
                    : () => unawaited(_confirm(SwitchResumeChoice.cancel)),
                child: Text(l.cancelAction),
              ),
              AppButton(
                key: const Key('playback-confirm-beginning'),
                onPressed: _busy || !_ready
                    ? null
                    : () => unawaited(_confirm(SwitchResumeChoice.beginning)),
                child: Text(l.playbackStartFromBeginning),
              ),
              if (plan.canTryCurrentPosition)
                AppButton(
                  key: const Key('playback-confirm-resume'),
                  onPressed: _busy || !_ready
                      ? null
                      : () => unawaited(
                          _confirm(SwitchResumeChoice.currentPosition),
                        ),
                  child: Text(l.playbackContinueAtPosition),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget playbackSwitchConfirmation(
  PlayerController controller, {
  FocusNode? cancelFocusNode,
}) => PlaybackSwitchConfirmation(
  plan: controller.switchConfirmation!,
  onConfirm: controller.confirmMediaSourceSwitch,
  cancelFocusNode: cancelFocusNode,
);

bool playbackNeedsLineStatus(PlayerController c) {
  if (c.switchConfirmation != null) return true;
  // Trying another saved line is not a blocking "backup line" panel.
  // Failure still offers retry and line choice once the attempts stop.
  final tryingAnotherLine =
      c.isRecovering &&
      c.pendingLineId != null &&
      c.pendingLineId != c.activeLineId;
  if (tryingAnotherLine) return false;
  return c.playbackLines.isNotEmpty &&
      !c.sessionExpired &&
      (c.isRecovering || c.disconnected || c.error == PlayerErrorKind.load);
}

class PlayerLineStatus extends StatelessWidget {
  const PlayerLineStatus({
    super.key,
    required this.controller,
    required this.onChooseLines,
    this.onDismiss,
    this.primaryFocusNode,
  });
  final PlayerController controller;
  final VoidCallback onChooseLines;
  final VoidCallback? onDismiss;
  final FocusNode? primaryFocusNode;
  @override
  Widget build(BuildContext context) {
    // The active line chooser owns the same confirmation. Keep a single
    // visible decision surface while its route is above the player.
    if (ModalRoute.of(context)?.isCurrent == false) {
      return const SizedBox.shrink();
    }
    final c = controller;
    final pending = c.playbackLines
        .where((line) => line.id == c.pendingLineId)
        .firstOrNull;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppUiTheme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: c.switchConfirmation != null
              ? playbackSwitchConfirmation(c, cancelFocusNode: primaryFocusNode)
              : PlaybackLineRecoveryPanel(
                  recovering: c.isRecovering,
                  primaryFocusNode: primaryFocusNode,
                  failure: c.playbackLineFailure,
                  failureKind: c.loadFailure?.kind,
                  retryAfter: c.playbackRetryAfter,
                  lineName: pending == null ? null : playbackLineLabel(pending),
                  onCancel: c.cancelLineRecovery,
                  onChooseLines: onChooseLines,
                  onRetry: c.retryPlayback,
                  onDismiss: onDismiss,
                ),
        ),
      ),
    );
  }
}
