part of 'player_controller.dart';

class _PlaybackContentFailure extends PlaybackRecoveryFailure {
  const _PlaybackContentFailure(this.error)
    : super(PlaybackRecoveryFailureKind.contentUnavailable);

  final PlayerErrorKind error;
}

/// Last successful line, then the other saved lines on the same server.
List<ServerLine> automaticPlaybackLineOrder({
  required List<ServerLine> lines,
  String? lastSuccessfulLineId,
  String? activeLineId,
}) {
  if (lines.isEmpty) return const [];
  final preferred = lines.any((line) => line.id == lastSuccessfulLineId)
      ? lastSuccessfulLineId
      : activeLineId;
  if (preferred == null || !lines.any((line) => line.id == preferred)) {
    return List<ServerLine>.of(lines);
  }
  return [
    for (final line in lines)
      if (line.id == preferred) line,
    for (final line in lines)
      if (line.id != preferred) line,
  ];
}

/// Same-server line policy and transactions. Native commands still pass through
/// the controller's command barrier; configuration commits keep the account lease.
extension PlayerLineTransactions on PlayerController {
  Future<bool> _startHelperRecovery() async {
    final deadline = recoveryDeadlineUtc;
    if (_initialRecoveryConsumed ||
        deadline == null ||
        runtime != null ||
        switchDispatcher == null) {
      return false;
    }
    _initialRecoveryConsumed = true;
    final revision = ++_lineRevision;
    final budget = PlaybackRecoveryBudget(
      total: deadline.difference(DateTime.now().toUtc()),
    );
    final attemptDeadline = recoveryAttemptDeadlineUtc ?? deadline;
    final attempt = budget.child(
      attemptDeadline.difference(DateTime.now().toUtc()),
    );
    _lineBudget = budget;
    _lineTransactionOpening = true;
    isRecovering = true;
    _attachRecoveryBudget(attempt);
    void current() {
      attempt.check();
      if (_disposed ||
          _revoked ||
          _operations.isClosed ||
          revision != _lineRevision) {
        throw const PlaybackRecoveryCancelled();
      }
    }

    void expire() {
      if (_disposed || _revoked || revision != _lineRevision) return;
      _operations.invalidate();
      _trackNativeRetirement(
        _operations.interrupt(backend.stop, ensureRetired: true),
      );
    }

    var succeeded = false;
    try {
      current();
      final operation = _beginOperation(lineTransaction: true);
      if (operation == null) throw const PlaybackRecoveryCancelled();
      await attempt.run(() => _start(operation), onCancel: expire);
      current();
      if (_accepts(operation) &&
          error == null &&
          !loading &&
          !disconnected &&
          state.phase != PlaybackPhase.failed) {
        final line = playbackLines.where(playbackLineIsCurrent).single;
        void live() => _requireOpenedLine(operation, current);
        await attempt.run(
          () => _persistPlaybackLine(
            line.id,
            playbackLineSelection,
            live,
            budget: attempt,
          ),
          onCancel: expire,
        );
        succeeded = true;
      }
    } catch (failure) {
      if (failure is MediaServerException) loadFailure = failure;
      playbackLineFailure = _lineFailureText(failure);
    } finally {
      if (revision == _lineRevision) {
        _lineTransactionOpening = false;
        _attachRecoveryBudget(null);
      }
    }
    if (revision != _lineRevision || _disposed || _revoked) return true;
    if (_hasContentError) {
      isRecovering = false;
      _lineBudget = null;
      _emit();
      return true;
    }
    if (succeeded) {
      isRecovering = false;
      _lineBudget = null;
      _emit();
    } else {
      isRecovering = false;
      loading = false;
      isPlaying = false;
      disconnected = true;
      error = PlayerErrorKind.load;
      state.phase = PlaybackPhase.failed;
      await _recoverPlaybackLines(
        automatic: true,
        sharedBudget: budget,
        alreadyAttempted: recoveryAttemptedLineIds.toSet(),
      );
      _emit();
    }
    return true;
  }

  Future<bool> _startAutomaticLines() async {
    final owner = runtime;
    if (owner == null || origin != null || _disposed || _revoked) return false;
    final request =
        openRequest ??
        PlayerOpenRequest(
          itemId: itemId,
          mediaSourceId: preferredMediaSourceId,
        );
    final id =
        request.source?.account.configuredServerId ??
        owner.auth.session?.server.id;
    if (id == null) return false;
    final server = owner.registry.server(id);
    if (!server.lineSelection.isAutomatic || server.lines.isEmpty) return false;
    final revision = ++_lineRevision;
    final budget = PlaybackRecoveryBudget(total: recoveryTimeout);
    _lineBudget = budget;
    var attempts = 0;
    PlaybackRecoveryCandidate candidate(
      ServerLine line,
    ) => PlaybackRecoveryCandidate(line.id, (window) async {
      void current() {
        window.check();
        if (_disposed ||
            _revoked ||
            _operations.isClosed ||
            revision != _lineRevision) {
          throw const PlaybackRecoveryCancelled();
        }
      }

      void expire() {
        if (_disposed || _revoked || revision != _lineRevision) return;
        _operations.invalidate();
        _trackNativeRetirement(
          _operations.interrupt(backend.stop, ensureRetired: true),
        );
      }

      current();
      final target = await window.run(
        () => owner.resolveInitialLine(request, line.id, window.remaining),
      );
      current();
      // A previous attempt may have proved a concrete version/track selection.
      // Carry that proof into the same strict preflight as a later disconnect.
      if (resolved != null && origin != null) {
        return _attemptPlaybackLine(
          line,
          const LineSelection.auto(),
          window,
          current,
          compensate: false,
        );
      }
      origin = target;
      client = target.client;
      pendingLineId = line.id;
      _lineTransactionOpening = true;
      _attachRecoveryBudget(window);
      try {
        final operation = _beginOperation(lineTransaction: true);
        if (operation == null) throw const PlaybackRecoveryCancelled();
        await window.run(() => _start(operation), onCancel: expire);
        current();
        _requireOpenedLine(operation, current);
        void live() => _requireOpenedLine(operation, current);
        await window.run(
          () => _persistPlaybackLine(
            line.id,
            const LineSelection.auto(),
            live,
            budget: window,
          ),
          onCancel: expire,
        );
        return true;
      } finally {
        if (revision == _lineRevision) {
          _lineTransactionOpening = false;
          _attachRecoveryBudget(null);
        }
      }
    });
    final ordered = automaticPlaybackLineOrder(
      lines: server.lines,
      lastSuccessfulLineId: server.lastSuccessfulLineId,
      activeLineId: server.activeLineId,
    );
    final result = await PlaybackRecoveryCoordinator().run(
      original: candidate(ordered.first),
      candidates: [for (final line in ordered.skip(1)) candidate(line)],
      // Already ordered. Don't let the coordinator pull another line forward.
      lastSuccessfulLineId: ordered.first.id,
      budget: budget,
      onAttempt: (line, _) {
        isRecovering = attempts++ > 0;
        pendingLineId = line;
        loading = true;
        _emit();
      },
    );
    final currentAttempt = revision == _lineRevision && !_disposed && !_revoked;
    if (currentAttempt) {
      final opened = result.status == PlaybackRecoveryStatus.succeeded;
      final needsChoice =
          result.status == PlaybackRecoveryStatus.needsSelection;
      final content =
          !opened && !needsChoice && _retainContentFailure(result.error);
      isRecovering = false;
      loading = false;
      if (!needsChoice) pendingLineId = null;
      // Nothing opened: drop the failed candidate so start() can resolve
      // and open through the ordinary path.
      if (!opened && !needsChoice && !content) {
        origin = null;
        resolved = null;
      }
      _emit();
      if (identical(_lineBudget, budget) && _confirmLine == null) {
        _lineBudget = null;
      }
      // A failed automatic pass must not swallow the ordinary open.
      return opened || needsChoice || content;
    }
    if (identical(_lineBudget, budget) && _confirmLine == null) {
      _lineBudget = null;
    }
    return true;
  }

  LineSelection get playbackLineSelection {
    final actual = origin;
    if (runtime != null && actual != null) {
      return runtime!.registry
          .server(actual.source.account.configuredServerId)
          .lineSelection;
    }
    return _savedLineSelection ??
        initialLineSelection ??
        LineSelection.fixed(
          activeLineId ?? playbackLines.firstOrNull?.id ?? '',
        );
  }

  void _installLineTransactions() {
    runtime?.registerLinePlayer(
      this,
      () => _disposed || _revoked
          ? null
          : origin?.source.account.configuredServerId,
      (selection, guard) => selectPlaybackLine(selection, guard: guard),
    );
  }

  void _startNetworkObservation() {
    if (_networkChanges != null || _disposed || _revoked) return;
    _networkChanges = NetworkChangeMonitor();
    _networkChangeSubscription = _networkChanges!.changes.listen((_) {
      // A topology notification is not evidence that the playing stream failed.
      // Remember it until the transport reports a real failure.
      _networkChanged = true;
    });
  }

  void _disposeLineTransactions() {
    _finishLineConfirmation(const PlaybackRecoveryCancelled());
    ++_lineRevision;
    _lineBudget?.cancel();
    runtime?.unregisterLinePlayer(this);
    unawaited(_networkChangeSubscription?.cancel());
    unawaited(_networkChanges?.dispose());
  }

  void _attachRecoveryBudget(PlaybackRecoveryBudget? budget) {
    if (backend is VideoBackendRecoveryBudget) {
      (backend as VideoBackendRecoveryBudget).recoveryBudget = budget;
    }
  }

  void cancelLineRecovery() {
    _holdAutomaticLineRecovery = true;
    _finishLineConfirmation(const PlaybackRecoveryCancelled());
    ++_lineRevision;
    _lineRollback?.call();
    _lineRollback = null;
    _lineBudget?.cancel();
    _lineRecovery = null;
    _invalidateHelperLineCommit();
    _confirmLine = null;
    switchConfirmation = null;
    pendingLineId = null;
    if (isRecovering || _lineTransactionOpening || loading) {
      _operations.invalidate();
      _trackNativeRetirement(
        _operations.interrupt(backend.stop, ensureRetired: true),
      );
      loading = false;
      isPlaying = false;
      disconnected = true;
      state.phase = PlaybackPhase.failed;
      state.buffering = false;
    }
    isRecovering = false;
    _lineTransactionOpening = false;
    _suspendLinePreference = false;
    _emit();
  }

  void _invalidateHelperLineCommit() {
    if (switchDispatcher != null) {
      unawaited(
        switchDispatcher!({'action': 'cancelLine'})
            .catchError((Object _) => <String, dynamic>{}),
      );
    }
  }

  Future<void> switchLine(String lineId) =>
      selectPlaybackLine(LineSelection.fixed(lineId));

  void _finishLineConfirmation([Object? failure]) {
    final result = _lineConfirmationResult;
    _lineConfirmationResult = null;
    if (result == null || result.isCompleted) return;
    if (failure == null) {
      result.complete();
    } else {
      result.completeError(failure);
    }
  }

  /// The host must retain the pending transaction until the helper user's
  /// choice has actually committed, failed, expired, or been cancelled.
  void cancelPendingPlaybackLineRequest() {
    if (_hostLineRequestRevision == _lineRevision) cancelLineRecovery();
  }

  Future<void> selectPlaybackLineWithConfirmation(
    LineSelection selection, {
    required DateTime deadlineUtc,
    required void Function() guard,
    required Future<void> Function() onNeedsSelection,
  }) async {
    final work = selectPlaybackLine(
      selection,
      guard: guard,
      deadlineUtc: deadlineUtc,
    );
    final revision = _lineRevision;
    _hostLineRequestRevision = revision;
    try {
      await work;
    } catch (failure) {
      final result = _lineConfirmationResult;
      if (_lineRevision != revision ||
          failure is! PlaybackRecoveryFailure ||
          failure.kind != PlaybackRecoveryFailureKind.needsSelection ||
          result == null) {
        rethrow;
      }
      try {
        guard();
        await onNeedsSelection();
        await result.future.timeout(
          deadlineUtc.difference(DateTime.now().toUtc()),
        );
        guard();
      } catch (_) {
        if (_lineRevision == revision) cancelLineRecovery();
        rethrow;
      }
    } finally {
      if (_hostLineRequestRevision == revision) {
        _hostLineRequestRevision = null;
        if (_lineRevision == revision) _lineSelectionDeadlineUtc = null;
      }
    }
  }

  Future<void> selectPlaybackLine(
    LineSelection selection, {
    void Function()? guard,
    DateTime? deadlineUtc,
  }) async {
    _finishLineConfirmation(const PlaybackRecoveryCancelled());
    _lineSelectionDeadlineUtc = deadlineUtc;
    final wasRecovering = isRecovering || _lineTransactionOpening;
    if (wasRecovering) cancelLineRecovery();
    final revision = ++_lineRevision;
    _lineBudget?.cancel();
    final budget = PlaybackRecoveryBudget(
      total: deadlineUtc == null
          ? recoveryTimeout
          : deadlineUtc.difference(DateTime.now().toUtc()),
    );
    _lineBudget = budget;
    void current() {
      guard?.call();
      budget.check();
      if (_disposed ||
          _revoked ||
          _operations.isClosed ||
          revision != _lineRevision) {
        throw StateError('Playback line selection cancelled');
      }
      origin?.permit.requireValid();
    }

    playbackLineFailure = null;
    _confirmLine = null;
    switchConfirmation = null;
    try {
      current();
      if (selection.isAutomatic) {
        // The mode is the whole choice. A dead line must not reject the save,
        // and playback does not have to be running.
        final savedLine =
            playbackLines.where(playbackLineIsCurrent).firstOrNull ??
            _playbackLineById(activeLineId ?? '') ??
            playbackLines.firstOrNull;
        if (savedLine == null) {
          throw StateError('Playback line is not on this server');
        }
        await budget.run(
          () => _persistPlaybackLine(
            savedLine.id,
            selection,
            current,
            budget: budget,
          ),
        );
        current();
        _emit();
        return;
      }
      final selected = selection.fixedLineId;
      final line = selected == null
          ? playbackLines.where(playbackLineIsCurrent).firstOrNull
          : _playbackLineById(selected);
      if (line == null) throw StateError('Playback line is not on this server');
      if (playbackLineIsCurrent(line) &&
          !disconnected &&
          state.phase != PlaybackPhase.failed &&
          !wasRecovering) {
        final operation = _operations.current;
        await budget.run(
          () => _persistPlaybackLine(
            line.id,
            selection,
            () => _requireOpenedLine(operation, current),
            budget: budget,
          ),
        );
        current();
        _emit();
        return;
      }
      await _attemptPlaybackLine(
        line,
        selection,
        budget,
        current,
        compensate: true,
        confirmationGuard: current,
      );
    } catch (failure) {
      if (revision == _lineRevision && !_disposed && !_revoked) {
        playbackLineFailure = _lineFailureText(failure);
        _emit();
      }
      rethrow;
    } finally {
      if (revision == _lineRevision) _lineSelectionDeadlineUtc = null;
      if (identical(_lineBudget, budget) && _confirmLine == null) {
        _lineBudget = null;
        _attachRecoveryBudget(null);
      }
    }
  }

  Future<void> _persistPlaybackLine(
    String lineId,
    LineSelection selection,
    void Function() current, {
    PlaybackRecoveryBudget? budget,
  }) async {
    current();
    final actual = origin;
    if (runtime != null && actual != null) {
      await runtime!.commitLine(actual, lineId, selection, current);
    } else if (switchDispatcher != null) {
      await switchDispatcher!({
        'action': 'commitLine',
        'deadlineUtc': DateTime.now()
            .toUtc()
            .add((budget ?? _lineBudget)?.remaining ?? recoveryTimeout)
            .toIso8601String(),
        'line': lineId,
        'selection': selection.toJson(),
        'item': itemId,
        'version': resolved?.mediaSource.id,
      });
    } else {
      throw StateError('Playback line persistence unavailable');
    }
    current();
    _savedLineSelection = selection;
    activeLineId = lineId;
    pendingLineId = null;
  }

  // A first frame is not a transaction receipt: a transport failure can arrive
  // while the configuration store is still saving. Check the same operation at
  // the store's commit point so that failed playback is rolled back and the
  // existing recovery budget can continue to the next candidate.
  void _requireOpenedLine(
    PlaybackOperation? operation,
    void Function() current,
  ) {
    current();
    if (sessionExpired) {
      throw const PlaybackRecoveryFailure(
        PlaybackRecoveryFailureKind.unauthorized,
      );
    }
    if (_hasContentError) throw _PlaybackContentFailure(error!);
    if (!_accepts(operation) ||
        error != null ||
        loading ||
        disconnected ||
        state.phase == PlaybackPhase.failed) {
      throw loadFailure ??
          const PlaybackRecoveryFailure(PlaybackRecoveryFailureKind.network);
    }
  }

  bool get _hasContentError =>
      error == PlayerErrorKind.noStream || error == PlayerErrorKind.notPlayable;

  bool _retainContentFailure(Object? failure) {
    if (failure is! _PlaybackContentFailure) return false;
    error = failure.error;
    loading = false;
    isPlaying = false;
    disconnected = false;
    state.phase = PlaybackPhase.failed;
    state.buffering = false;
    playbackLineFailure = null;
    return true;
  }

  Future<void> _recoverPlaybackLines({
    bool automatic = false,
    LineSelection? selection,
    PlaybackRecoveryBudget? sharedBudget,
    Set<String> alreadyAttempted = const {},
    int? intentRevision,
    void Function()? intentGuard,
  }) {
    if (_disposed ||
        _revoked ||
        sessionExpired ||
        _backgroundReleased ||
        _operations.isClosed ||
        playbackLines.isEmpty ||
        (automatic &&
            (!playbackLineSelection.isAutomatic || _hasContentError))) {
      return Future.value();
    }
    final existing = _lineRecovery;
    if (existing != null) return existing;
    _holdAutomaticLineRecovery = true;
    final failure = loadFailure;
    if (automatic &&
        failure != null &&
        {
          PlaybackRecoveryFailureKind.unauthorized,
          PlaybackRecoveryFailureKind.forbidden,
          PlaybackRecoveryFailureKind.rateLimited,
          PlaybackRecoveryFailureKind.certificate,
          PlaybackRecoveryFailureKind.identity,
        }.contains(PlaybackRecoveryCoordinator.classify(failure))) {
      return Future.value();
    }
    final revision = intentRevision ?? ++_lineRevision;
    final budget =
        sharedBudget ?? PlaybackRecoveryBudget(total: recoveryTimeout);
    if (!identical(_lineBudget, budget)) _lineBudget?.cancel();
    _lineBudget = budget;
    final chosen = selection ?? playbackLineSelection;
    final previousPosition = position;
    final original =
        playbackLines.where(playbackLineIsCurrent).firstOrNull ??
        playbackLines.first;
    final lines = List<ServerLine>.of(playbackLines);
    final preferred = origin == null
        ? null
        : runtime?.registry
              .server(origin!.source.account.configuredServerId)
              .lastSuccessfulLineId;
    final ordered = chosen.isAutomatic
        ? automaticPlaybackLineOrder(
            lines: lines,
            lastSuccessfulLineId: preferred,
            activeLineId: original.id,
          )
        : <ServerLine>[original];
    isRecovering = true;
    loading = true;
    controlsVisible = true;
    _networkChanged = false;
    _emit();
    PlaybackRecoveryCandidate candidate(ServerLine line) =>
        PlaybackRecoveryCandidate(line.id, (window) async {
          void current() {
            intentGuard?.call();
            window.check();
            if (_disposed || _revoked || revision != _lineRevision) {
              throw const PlaybackRecoveryCancelled();
            }
            origin?.permit.requireValid();
          }

          try {
            current();
            return await _attemptPlaybackLine(
              line,
              chosen,
              window,
              current,
              compensate: false,
              confirmationGuard: intentGuard,
            );
          } finally {
            if (revision == _lineRevision) _attachRecoveryBudget(null);
          }
        });
    final work = () async {
      final first = ordered.first;
      final result = await PlaybackRecoveryCoordinator().run(
        original: alreadyAttempted.contains(first.id)
            ? PlaybackRecoveryCandidate(first.id, (_) async => false)
            : candidate(first),
        candidates: [
          if (chosen.isAutomatic)
            for (final line in ordered.skip(1))
              if (!alreadyAttempted.contains(line.id)) candidate(line),
        ],
        budget: budget,
        lastSuccessfulLineId: first.id,
        onAttempt: (line, _) {
          pendingLineId = line;
          isRecovering = true;
          loading = true;
          _emit();
        },
      );
      if (revision != _lineRevision || _disposed || _revoked) return;
      isRecovering = false;
      if (result.status != PlaybackRecoveryStatus.succeeded) {
        loading = false;
        isPlaying = false;
        disconnected = true;
        state.phase = PlaybackPhase.failed;
        state.buffering = false;
        position = previousPosition;
        playbackLineFailure = _lineFailureText(
          result.error ?? const PlaybackRecoveryCancelled(),
        );
        if (result.error != null &&
            PlaybackRecoveryCoordinator.classify(result.error!) ==
                PlaybackRecoveryFailureKind.unauthorized) {
          sessionExpired = true;
        }
        _retainContentFailure(result.error);
      }
      if (result.status != PlaybackRecoveryStatus.needsSelection) {
        pendingLineId = null;
      }
      _emit();
    }();
    _lineRecovery = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_lineRecovery, work)) _lineRecovery = null;
        if (identical(_lineBudget, budget) && _confirmLine == null) {
          _lineBudget = null;
        }
      }),
    );
    return work;
  }

  Future<MediaServerClient> _preparePlaybackLine(
    ServerLine line,
    PlaybackRecoveryBudget budget,
    void Function() current,
  ) async {
    final actual = origin;
    if (runtime != null && actual != null) {
      final target = await budget.run(
        () => runtime!.resolveLine(
          actual,
          line.id,
          resolved?.mediaSource.id ?? preferredMediaSourceId,
          timeout: budget.remaining,
        ),
      );
      current();
      return target.client;
    }
    final token = client.accessToken;
    final userId = client.userId;
    final expected = playbackServerIdentity;
    if (token == null || userId == null || expected == null) {
      throw StateError('Playback identity unavailable');
    }
    final address = Uri.parse(line.address);
    final info = await budget.run(() => client.getPublicInfo(address));
    current();
    if (info.id != expected) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
    // The prepared client outlives this recovery attempt after a successful
    // commit. Its session guard must not expire with the preparation deadline.
    // Individual preparation requests remain wrapped in budget.run/current.
    final probe = client.withRequestGuard(() {
      if (_disposed || _revoked || _operations.isClosed) {
        throw const PlaybackRecoveryCancelled();
      }
      origin?.permit.requireValid();
    });
    probe.attachSession(
      baseUrl: address,
      accessToken: token,
      userId: userId,
      userAgent: client.customUserAgent,
    );
    try {
      final user = await budget.run(probe.getUser);
      current();
      if (user.id != userId) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidCredentials,
        );
      }
      final target = await budget.run(() => probe.getItem(itemId));
      current();
      if (target.id != itemId) {
        throw const MediaServerException(
          MediaServerFailureKind.incompatibleServer,
        );
      }
      return probe;
    } catch (_) {
      probe.clearSession();
      rethrow;
    }
  }

  Future<PlaybackSwitchPlan?> _inspectPlaybackLine(
    MediaServerClient next,
    PlaybackRecoveryBudget budget,
    void Function() current,
  ) async {
    final previous = resolved;
    if (previous == null) return null;
    final info = await budget.run(
      () => next.inspectPlaybackInfo(
        itemId: itemId,
        mediaSourceId: previous.mediaSource.id,
        startPosition: position,
        maxStreamingBitrate: maxStreamingBitrate,
      ),
    );
    current();
    final targets = info.mediaSources.where(
      (s) => s.id == previous.mediaSource.id,
    );
    if (targets.length != 1) {
      throw const PlaybackRecoveryFailure(
        PlaybackRecoveryFailureKind.needsSelection,
      );
    }
    final target = targets.single;
    // Same stable version is necessary, but a changed timeline is not equivalent.
    final timeline = target.runtime == previous.mediaSource.runtime;
    final plan = PlaybackSwitchPlan.inspect(
      original: previous.mediaSource,
      target: target,
      positionTicks: ticksFromDuration(position),
      paused: _pauseIntent,
      maxStreamingBitrate: maxStreamingBitrate,
      audioIndex: audioStreamIndex,
      subtitleIndex: subtitleStreamIndex,
      sameVersion: timeline,
    );
    if (secondarySubtitleStreamIndex != null &&
        target.streamByIndex(secondarySubtitleStreamIndex!)?.isSubtitle !=
            true) {
      throw const PlaybackRecoveryFailure(
        PlaybackRecoveryFailureKind.needsSelection,
      );
    }
    return plan;
  }

  Future<bool> _attemptPlaybackLine(
    ServerLine line,
    LineSelection selection,
    PlaybackRecoveryBudget budget,
    void Function() current, {
    required bool compensate,
    void Function()? confirmationGuard,
  }) async {
    final prepared = await _preparePlaybackLine(line, budget, current);
    final plan = await _inspectPlaybackLine(prepared, budget, current);
    current();
    if (plan != null && (plan.needsConfirmation || !plan.timelineConfirmed)) {
      switchConfirmation = plan;
      _switchOriginal = resolved;
      pendingLineId = line.id;
      final revision = _lineRevision;
      final confirmationOrigin = origin;
      final deadline = _lineSelectionDeadlineUtc;
      final result = _lineConfirmationResult = Completer<void>();
      // Local UI callers do not await a host receipt, but share its lifecycle.
      unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
      _confirmLine = (choice, audio, subtitle, off, defaultAudio) async {
        if (choice == SwitchResumeChoice.cancel) {
          _finishLineConfirmation(const PlaybackRecoveryCancelled());
          _confirmLine = null;
          switchConfirmation = null;
          pendingLineId = null;
          prepared.clearSession();
          _emit();
          return;
        }
        if (revision != _lineRevision ||
            !identical(resolved, _switchOriginal)) {
          throw StateError('Playback line confirmation expired');
        }
        plan.requireSelection(
          choice,
          audio: audio,
          subtitle: subtitle,
          acceptDefaultAudio: defaultAudio,
          turnSubtitlesOff: off,
        );
        _confirmLine = null;
        switchConfirmation = null;
        // Local choices get a bounded intent; helper choices keep the host's
        // original deadline, including time spent waiting for this decision.
        final confirmedBudget = PlaybackRecoveryBudget(
          total: deadline == null
              ? recoveryTimeout
              : deadline.difference(DateTime.now().toUtc()),
        );
        _lineBudget = confirmedBudget;
        void confirmed() {
          confirmedBudget.check();
          // The candidate window has retired once it asks for a decision.
          // Retain the enclosing host intent and absolute deadline instead.
          if (deadline != null) confirmationGuard?.call();
          if (_disposed || _revoked || revision != _lineRevision) {
            throw StateError('Playback line confirmation cancelled');
          }
          confirmationOrigin?.permit.requireValid();
        }

        try {
          await _openPlaybackLine(
            line,
            selection,
            prepared,
            plan,
            confirmedBudget,
            confirmed,
            compensate: true,
            startTicks: choice == SwitchResumeChoice.beginning
                ? 0
                : plan.positionTicks,
            audio: audio ?? (defaultAudio ? null : plan.audioIndex),
            subtitle: off ? null : (subtitle ?? plan.subtitleIndex),
          );
          if (identical(_lineConfirmationResult, result)) {
            _finishLineConfirmation();
          }
        } catch (failure) {
          if (identical(_lineConfirmationResult, result)) {
            _finishLineConfirmation(failure);
          }
          rethrow;
        } finally {
          if (identical(_lineBudget, confirmedBudget)) _lineBudget = null;
        }
      };
      _emit();
      throw const PlaybackRecoveryFailure(
        PlaybackRecoveryFailureKind.needsSelection,
      );
    }
    await _openPlaybackLine(
      line,
      selection,
      prepared,
      plan,
      budget,
      current,
      compensate: compensate,
      startTicks: plan?.positionTicks ?? ticksFromDuration(position),
      audio: plan?.audioIndex ?? audioStreamIndex,
      subtitle: plan?.subtitleIndex ?? subtitleStreamIndex,
    );
    return true;
  }

  Future<void> _openPlaybackLine(
    ServerLine line,
    LineSelection selection,
    MediaServerClient prepared,
    PlaybackSwitchPlan? plan,
    PlaybackRecoveryBudget budget,
    void Function() current, {
    required bool compensate,
    required int startTicks,
    required int? audio,
    required int? subtitle,
  }) async {
    final revision = _lineRevision;
    final oldOrigin = origin;
    final oldClient = client;
    final oldResolved = resolved;
    final oldLine = activeLineId;
    final oldAudio = audioStreamIndex;
    final oldSubtitle = subtitleStreamIndex;
    final oldSecondary = secondarySubtitleStreamIndex;
    final oldPrimaryFile = primarySubtitleFileId;
    final oldSecondaryFile = secondarySubtitleFileId;
    final paused = plan?.paused ?? _pauseIntent;
    final oldPosition = position;
    void restoreConnection() {
      client = oldClient;
      origin = oldOrigin;
      resolved = oldResolved;
      activeLineId = oldLine;
      pendingLineId = null;
      position = oldPosition;
      secondarySubtitleStreamIndex = oldSecondary;
      primarySubtitleFileId = oldPrimaryFile;
      secondarySubtitleFileId = oldSecondaryFile;
    }

    _lineRollback = restoreConnection;
    void expire() {
      if (_disposed || _revoked || revision != _lineRevision) return;
      _operations.invalidate();
      _trackNativeRetirement(
        _operations.interrupt(backend.stop, ensureRetired: true),
      );
    }

    _lineTransactionOpening = true;
    _attachRecoveryBudget(budget);
    try {
      current();
      final stopped = _stopSession();
      _operations.invalidate();
      await budget.run(
        () => Future.wait([
          stopped,
          _operations.interrupt(backend.stop, ensureRetired: true),
        ]),
        onCancel: expire,
      );
      current();
      client = prepared;
      if (oldOrigin != null) {
        origin = PlaybackOrigin(
          source: oldOrigin.source,
          work: oldOrigin.work,
          libraryId: oldOrigin.libraryId,
          permit: oldOrigin.permit,
          client: prepared,
        );
      }
      pendingLineId = line.id;
      final operation = _beginOperation(lineTransaction: true);
      if (operation == null) throw StateError('Playback closed');
      _suspendLinePreference = true;
      await budget.run(
        () => oldResolved == null
            ? _start(operation, skipStop: true, startPaused: paused)
            : _open(
                operation: operation,
                startTicks: startTicks,
                audio: audio,
                subtitle: subtitle,
                subtitleOff: subtitle == null,
                requestedSourceId: oldResolved.mediaSource.id,
                startPaused: paused,
                strictTracks: true,
              ),
        onCancel: expire,
      );
      current();
      _requireOpenedLine(operation, current);
      if (oldSecondary != secondarySubtitleStreamIndex ||
          oldPrimaryFile != primarySubtitleFileId ||
          oldSecondaryFile != secondarySubtitleFileId) {
        throw const PlaybackRecoveryFailure(
          PlaybackRecoveryFailureKind.needsSelection,
        );
      }
      await budget.run(
        () => _persistPlaybackLine(
          line.id,
          selection,
          () => _requireOpenedLine(operation, current),
          budget: budget,
        ),
        onCancel: expire,
      );
      current();
      _lineRollback = null;
      playbackLineFailure = null;
    } catch (failure) {
      final cancelled = _disposed || _revoked || budget.isCancelled;
      if (_disposed || _revoked || revision != _lineRevision) rethrow;
      // Invalidate the target even when its metadata/open completes late.
      expire();
      restoreConnection();
      var restored = false;
      if (compensate &&
          !cancelled &&
          !budget.isExpired &&
          oldResolved != null) {
        try {
          current();
          final restoration = budget.child(const Duration(seconds: 8));
          _attachRecoveryBudget(restoration);
          await restoration.run(() async {
            await _nativeRetirement;
            current();
            final operation = _beginOperation(lineTransaction: true);
            if (operation == null) return;
            await _open(
              operation: operation,
              startTicks: ticksFromDuration(oldPosition),
              audio: oldAudio,
              subtitle: oldSubtitle,
              subtitleOff: oldSubtitle == null,
              requestedSourceId: oldResolved.mediaSource.id,
              startPaused: paused,
              strictTracks: true,
            );
            restored =
                _accepts(operation) &&
                !loading &&
                !disconnected &&
                error == null &&
                state.phase != PlaybackPhase.failed;
          }, onCancel: expire);
        } catch (_) {
          restored = false;
        }
      }
      if (!restored) {
        isPlaying = false;
        loading = false;
        disconnected = true;
        error = PlayerErrorKind.load;
        state.phase = PlaybackPhase.failed;
        state.buffering = false;
        position = oldPosition;
      }
      playbackLineFailure = _lineFailureText(failure);
      _emit();
      rethrow;
    } finally {
      if (identical(_lineRollback, restoreConnection)) _lineRollback = null;
      if (revision == _lineRevision) {
        _lineTransactionOpening = false;
        _suspendLinePreference = false;
        _attachRecoveryBudget(null);
      }
    }
  }

  String _lineFailureText(Object failure) {
    if (failure is MediaServerException && failure.statusCode == 403) {
      return '服务器请求过多，请稍后重试';
    }
    if (failure is _PlaybackContentFailure) {
      return failure.error == PlayerErrorKind.noStream ? '没有可播放的流' : '此项目无法播放';
    }
    if (failure is PlaybackRecoveryFailure) {
      return switch (failure.kind) {
        PlaybackRecoveryFailureKind.certificate => '证书验证失败，请检查服务器证书',
        PlaybackRecoveryFailureKind.identity => '这个地址属于另一台服务器',
        PlaybackRecoveryFailureKind.unauthorized => '登录已失效，请重新登录',
        PlaybackRecoveryFailureKind.forbidden => '没有播放权限，请检查账号权限',
        PlaybackRecoveryFailureKind.rateLimited => '服务器请求过多，请稍后重试',
        PlaybackRecoveryFailureKind.needsSelection => '目标线路无法保留当前播放选择，请确认后继续',
        _ => '连接失败，换条线路试试',
      };
    }
    return failure is MediaServerException
        ? switch (failure.kind) {
            MediaServerFailureKind.certificate => '证书验证失败，请检查服务器证书',
            MediaServerFailureKind.incompatibleServer => '这个地址属于另一台服务器',
            MediaServerFailureKind.sessionExpired ||
            MediaServerFailureKind.authorizationExpired ||
            MediaServerFailureKind.invalidCredentials => '登录已失效，请重新登录',
            MediaServerFailureKind.forbidden => '没有播放权限，请检查账号权限',
            MediaServerFailureKind.rateLimited => '服务器请求过多，请稍后重试',
            _ => '连接失败，换条线路试试',
          }
        : '线路未切换或未保存，请重试';
  }
}
