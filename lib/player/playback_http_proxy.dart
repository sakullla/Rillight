import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../emby/emby_url.dart';

import 'cache/http_cache_policy.dart';
import 'cache/hls_cache_index.dart';
import 'cache/hls_fmp4_probe.dart';
import 'cache/matroska_cache_index.dart';
import 'cache/mp4_cache_index.dart';
import 'cache/response_read_ahead.dart';
import 'cache/session_byte_cache.dart';
import 'cache/session_read_ahead.dart';
import 'cache/sealed_media_route.dart';

enum PlaybackResourceRole {
  media,
  playlist,
  segment,
  initialization,
  key,
  subtitle,
}

enum PlaybackCacheStream { conservative, stable }

/// A per-session loopback transport. The native core never receives Emby credentials;
/// every redirect, HLS child resource and subtitle is authorized separately.
class PlaybackHttpProxy {
  PlaybackHttpProxy._(
    this._server,
    this.origin,
    this.headers,
    this._cache,
    this.dynamicSource,
    this.sessionBuffering,
    this.readAheadBytes,
    this.readAheadConcurrency,
    this.continuousTransfers,
    this.onStreamChanged,
    Future<SessionByteCache>? pendingCache,
    this.mediaHeaderTimeout,
    this.otherHeaderTimeout,
    this.bodyStallTimeout,
    this.verifiedSnapshotTtl,
    this.integrityRecheck,
  ) : _secret = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join() {
    _cacheReady = pendingCache?.then((value) => _cache = value);
    _cacheReady?.ignore();
    _client.autoUncompress = true;
    // Read-ahead lanes must not occupy foreground seek/subtitle connections.
    _client.maxConnectionsPerHost = _maxRequests + 4;
    _client.connectionTimeout = const Duration(seconds: 15);
    _server.listen((request) => unawaited(_serve(request)));
  }

  final HttpServer _server;
  final HttpClient _client = HttpClient();
  Uint8List? _warmPrefix;
  String? _warmIdentity;
  final Uri? origin;
  final Map<String, String> headers;
  final String _secret;
  SessionByteCache? _cache;
  SessionByteCache? get cache => _cache;
  Future<SessionByteCache>? _cacheReady;
  final bool dynamicSource;

  /// Explicit playback-only storage policy. The cache must be session-owned
  /// and deleted on close; never use this opt-in for a persistent HTTP cache.
  final bool sessionBuffering;
  final int readAheadBytes;
  final int readAheadConcurrency;
  final bool continuousTransfers;

  /// Header budget for a media response. One fast response must not shrink it.
  final Duration mediaHeaderTimeout;

  /// Header budget for playlists, subtitles and other non-media responses.
  final Duration otherHeaderTimeout;

  /// How long a live body may go quiet before the transfer is retired.
  final Duration bodyStallTimeout;

  /// How long a verified timeline or byte snapshot stays visible while busy.
  final Duration verifiedSnapshotTtl;

  /// Minimum gap before another checksum pass of an unchanged snapshot.
  final Duration integrityRecheck;

  SessionReadAhead? _readAhead;
  final _readAheadBypass = <String>{};
  MatroskaCacheIndex? _timelineIndex;
  Mp4CacheIndex? _mp4TimelineIndex;
  String? _timelineIdentity;
  String? _timelineResource;
  int _timelineAttemptRevision = -1;
  Duration? _timelineAttemptDuration;
  DateTime? _lastIntegrityCheck;
  DateTime? _lastSuccessfulTimelineAt;
  DateTime? _timelineRetryAfter;
  String? _mappingUnknownReason;
  int? _selectedVideoTrackId;
  int? _selectedAudioTrackId;
  int _trackSelectionVersion = 0;
  List<CachedTimeRange> _cachedTimeline = const [];
  List<CachedByteRange> _cachedBytes = const [];
  String? _byteIdentity;
  int _byteRevision = -1;
  int _byteCoverageRevision = -1;
  DateTime? _lastByteIntegrityCheck;
  bool _refreshingBytes = false;
  int _timelineSequence = 0;
  bool _refreshingTimeline = false;
  final FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged;
  final _routes = SealedMediaRoutes();
  final _refreshedUrls = <String, Uri>{};
  final _privateSubtitles = <String, String>{};
  final _roles = <String, PlaybackResourceRole>{};
  final _hlsNext = <String, _HlsNext>{};
  final _hlsOwners = <String, Set<String>>{};
  final _hlsPlaylists = <String, _HlsPlaylistState>{};
  final _hlsSegmentOwners = <String, String>{};
  final _hlsDependencyKeys = <String>{};
  final _hlsActiveOwners = <String>{};
  final _hlsProbeCache = <String, HlsFmp4ProbeResult>{};
  String? _hlsUnknownReason;
  final _representations = <String, _Representation>{};
  final _reads = <_ProxyRead>{};
  final _loads = <String, _SharedLoad>{};
  final _writes = <Future<bool>>{};
  int _active = 0;
  Completer<void> _requestReleased = Completer<void>();
  int _admissionWaits = 0;
  int _admissionRejected = 0;
  int _activeSegmentPrefetchRequests = 0;
  int _seekGeneration = 0;
  int _hlsIndexBytes = 0;
  int _segmentPrefetchGeneration = 0;
  final _segmentPrefetchJobs = <String, _SegmentPrefetchJob>{};
  final _pendingSegmentPrefetch = <String, _HlsNext>{};
  final _hlsPrefetchWindows = <String, _HlsPrefetchWindow>{};
  Future<void>? _segmentPrefetchCapacityWakeup;
  int _segmentPrefetchPeak = 0;
  int _segmentPrefetchPreemptions = 0;
  int _segmentPrefetchHandoffs = 0;
  int _segmentPrefetchDownloadedBytes = 0;
  int? _segmentPrefetchRefusal;
  bool _serialUpstream = false;
  // Demuxers keep their main response open while probing the index and seeking.
  // Limit connections separately from cache workspace: a stalled old response
  // must not queue all of the reads needed to start decoding.
  static const _maxRequests = 8;
  static const _cachedResponseWorkspace = 1024 * 1024;
  int _cacheWorkspace = 0;
  int _nextRepresentation = 0;
  int _upstreamBytes = 0;
  int _mediaDownloadBytes = 0;
  int _controlDownloadBytes = 0;
  final int _repeatedDownloadBytes = 0;
  int _recoveryAttempts = 0;
  int _recoveries = 0;
  int _recoveryFailures = 0;
  int _cancelled = 0;
  String? _lastValidationFailure;
  int? _lastUpstreamStatus;
  String? _readAheadBypassReason;
  String? _lastUpstreamResourceRole;
  String? _lastRequestedResourceRole;
  int _lastRequestedRedirectCount = 0;
  int? _lastMediaUpstreamStatus;
  final _upstreamPhases = <String, int>{};
  String? _lastUpstreamPhase;
  String? _lastUpstreamFailureKind;
  int? _lastUpstreamPhaseElapsedMs;
  int _mediaHeaderTimeouts = 0;
  int? _authenticationStatus;
  int? _prefetchAuthenticationStatus;
  int _inFlight = 0;
  int _inFlightPeak = 0;
  final _samples = <(DateTime, int)>[];
  PlaybackCacheStream _stream = PlaybackCacheStream.conservative;
  bool _closed = false;
  bool _playbackActive = true;
  final _responseReadAheads = <ResponseReadAhead>{};
  _BufferedResponse? _bufferedResponse;
  List<CachedByteRange> _responseByteRanges = const [];
  String? _responseByteIdentity;
  bool _refreshingResponseBytes = false;
  DateTime? _responseIntegrityAt;
  int _responseIntegrityRevision = -1;
  int _responseCoverageRevision = -1;
  int _responseReadAheadSequence = 0;

  int get upstreamBytes => _upstreamBytes;
  void refreshSourceUrl(Uri route, Uri url) {
    if (_closed ||
        dynamicSource ||
        !sessionBuffering ||
        (url.scheme != 'https' && url.scheme != 'http') ||
        route.host != '127.0.0.1' ||
        route.port != _server.port ||
        !route.path.startsWith('/$_secret/')) {
      throw StateError('Invalid media renewal');
    }
    final token = route.path.substring('/$_secret/'.length).split('/').first;
    final resource = _routes.open(token);
    if (resource == null || resource.role != PlaybackResourceRole.media.index) {
      throw StateError('Invalid media renewal route');
    }
    _refreshedUrls[resource.identity] = url;
    if (_bufferedResponse?.key == resource.identity) {
      _discardBufferedResponse();
    }
    _prefetchAuthenticationStatus = null;
    if (_lastMediaUpstreamStatus == 403) _lastMediaUpstreamStatus = null;
    if (_warmIdentity == resource.identity) {
      _warmPrefix = null;
      _warmIdentity = null;
    }
    if (_authenticationStatus == 403) _authenticationStatus = null;
    _readAheadBypass.remove(resource.identity);
    _readAheadBypassReason = null;
    if (_readAhead?.resource == resource.identity) {
      _readAhead?.retryAfterSourceRenewal();
    }
    // Interrupt only requests still awaiting their first response. Their
    // existing retry loop will pick up the renewed route; keep the downstream
    // reader alive and never splice an unvalidated in-flight response body.
    for (final read in _reads) {
      if (read.resourceKey == resource.identity && read.response == null) {
        for (final request in read.requests.toList()) {
          request.abort();
        }
      }
    }
  }

  void resumeAfterDiskRecovery() => _readAhead?.resumeAfterDiskRecovery();
  Future<void> retryReadAhead() async {
    if (_closed) return;
    final previous = _readAhead;
    _readAhead = null;
    _timelineIndex = null;
    _mp4TimelineIndex = null;
    _timelineIdentity = null;
    _timelineAttemptRevision = -1;
    _lastIntegrityCheck = null;
    _timelineRetryAfter = null;
    _mappingUnknownReason = null;
    _cachedTimeline = const [];
    _clearByteCoverage();
    _timelineSequence++;
    if (_hlsPlaylists.isNotEmpty) _hlsUnknownReason = 'hlsTimingUnavailable';
    _readAheadBypass.clear();
    await previous?.close();
  }

  PlaybackCacheStream get stream => _stream;
  void setPlaybackActive(bool active) {
    if (_playbackActive == active) return;
    _playbackActive = active;
    _readAhead?.setPrefetchAllowed(active);
    for (final response in _responseReadAheads) {
      response.setPlaybackActive(active);
    }
    if (!active) _cancelSegmentPrefetch(clearPending: true);
  }

  void selectContainerTracks({int? videoTrackId, int? audioTrackId}) {
    if (_selectedVideoTrackId == videoTrackId &&
        _selectedAudioTrackId == audioTrackId) {
      return;
    }
    _cancelSegmentPrefetch(clearPending: true);
    _selectedVideoTrackId = videoTrackId;
    _selectedAudioTrackId = audioTrackId;
    _trackSelectionVersion++;
    _timelineIndex = null;
    _mp4TimelineIndex = null;
    _timelineAttemptRevision = -1;
    _lastIntegrityCheck = null;
    _timelineRetryAfter = null;
    _mappingUnknownReason = null;
    _cachedTimeline = const [];
    _timelineSequence++;
  }

  List<CachedTimeRange> get _visibleCachedTimeline {
    final degradation = cache?.diagnostics['degradation'];
    return degradation == null || degradation == 'disk-timeout'
        ? _cachedTimeline
        : const [];
  }

  void _clearByteCoverage() {
    _cachedBytes = const [];
    _byteIdentity = null;
    _byteRevision = -1;
    _byteCoverageRevision = -1;
    _lastByteIntegrityCheck = null;
    _timelineSequence++;
  }

  void _publishByteCoverage(
    String resource,
    _Representation representation,
    List<CachedByteRange> ranges, {
    required int scannedRevision,
  }) {
    _cachedBytes = [
      for (final range in ranges)
        if (range.start >= 0 &&
            range.start < representation.total &&
            range.end > range.start)
          CachedByteRange(range.start, min(range.end, representation.total)),
    ];
    _byteIdentity = '$resource:${representation.generation}';
    // Writes completed during the asynchronous scan were not necessarily
    // included. Do not mark them verified until the following snapshot.
    _byteRevision = scannedRevision;
    _byteCoverageRevision = cache!.coverageRevision;
    _lastByteIntegrityCheck = DateTime.now();
    _timelineSequence++;
  }

  _Representation? get _byteRepresentation {
    if (_closed ||
        cache == null ||
        !sessionBuffering ||
        _hlsNext.isNotEmpty ||
        _hlsPlaylists.isNotEmpty ||
        _cacheReadsUncertain ||
        cache!.diagnostics['closed'] == true) {
      return null;
    }
    final resource = _timelineResource ?? _readAhead?.resource;
    if (resource == null || _roles[resource] != PlaybackResourceRole.media) {
      return null;
    }
    final representation = _representations[resource];
    return representation != null && representation.total > 0
        ? representation
        : null;
  }

  bool get _byteCoverageCurrent {
    final representation = _byteRepresentation;
    final resource = _timelineResource ?? _readAhead?.resource;
    if (representation == null ||
        resource == null ||
        _byteIdentity != '$resource:${representation.generation}') {
      return false;
    }
    if (cache!.diagnostics['degradation'] == 'disk-timeout' &&
        (_lastByteIntegrityCheck == null ||
            DateTime.now().difference(_lastByteIntegrityCheck!) >=
                verifiedSnapshotTtl)) {
      return false;
    }
    if (_byteCoverageRevision != cache!.coverageRevision) {
      // Sliding-window reclamation must remove the consumed part immediately,
      // without blanking all remaining verified download progress between scans.
      _cachedBytes = cache!.retainAvailableRanges(
        resource: resource,
        generation: representation.generation,
        verified: _cachedBytes,
      );
      _byteCoverageRevision = cache!.coverageRevision;
      _timelineSequence++;
    }
    return true;
  }

  void _retainByteCoverageWhileBusy() {
    final verified = _lastByteIntegrityCheck;
    if (!_byteCoverageCurrent ||
        verified == null ||
        DateTime.now().difference(verified) > verifiedSnapshotTtl) {
      _clearByteCoverage();
    }
  }

  String? get _timelineUnknownReason {
    if (_closed) return 'closed';
    if (cache == null || !sessionBuffering) return 'cacheDisabled';
    final degradation = cache!.diagnostics['degradation'];
    if (degradation != null && degradation != 'disk-timeout') {
      return 'cacheUncertain';
    }
    if (_hlsPlaylists.isNotEmpty) return _hlsUnknownReason;
    if (_hlsNext.isNotEmpty && _readAhead == null) {
      return 'hlsTimingUnavailable';
    }
    if (_timelineIdentity == null) {
      return 'indexUnavailable';
    }
    if (_cachedTimeline.isEmpty && _mappingUnknownReason != null) {
      return _mappingUnknownReason;
    }
    if (_cachedTimeline.isEmpty &&
        _timelineIndex == null &&
        _mp4TimelineIndex == null) {
      return _mappingUnknownReason ?? 'mediaMappingUnavailable';
    }
    return null;
  }

  double get upstreamBytesPerSecond {
    _pruneSamples();
    return _samples.fold<int>(0, (sum, sample) => sum + sample.$2).toDouble();
  }

  Map<String, Object?> get diagnostics {
    final byteCurrent = _byteCoverageCurrent;
    final responseBytes = _responseCoverageCurrent;
    final buffered = _bufferedResponse;
    return {
      ...?cache?.diagnostics,
      'upstreamBytes': _upstreamBytes,
      'mediaDownloadBytes': _mediaDownloadBytes,
      'controlDownloadBytes': _controlDownloadBytes,
      'repeatedDownloadBytes': _repeatedDownloadBytes,
      'recoveryAttempts': _recoveryAttempts,
      'recoveries': _recoveries,
      'recoveryFailures': _recoveryFailures,
      'cancelledReads': _cancelled,
      'lastValidationFailure': _lastValidationFailure,
      'lastUpstreamStatus': _lastUpstreamStatus,
      'lastUpstreamResourceRole': _lastUpstreamResourceRole,
      'lastMediaUpstreamStatus': _lastMediaUpstreamStatus,
      'lastRequestedResourceRole': _lastRequestedResourceRole,
      'lastRequestedRedirectCount': _lastRequestedRedirectCount,
      'upstreamConnectingRequests': _upstreamPhases['connect'] ?? 0,
      'upstreamAwaitingHeadersRequests': _upstreamPhases['headers'] ?? 0,
      'mediaHeaderTimeouts': _mediaHeaderTimeouts,
      'lastUpstreamPhase': _lastUpstreamPhase,
      'lastUpstreamFailureKind': _lastUpstreamFailureKind,
      'lastUpstreamPhaseElapsedMs': _lastUpstreamPhaseElapsedMs,
      'authenticationStatus': _authenticationStatus,
      'prefetchAuthenticationStatus': _prefetchAuthenticationStatus,
      'proxyInFlightBytes': _inFlight,
      'proxyInFlightPeakBytes': _inFlightPeak,
      'registeredResources': _roles.length,
      'registryBudgetBytes': _roles.length * 4096,
      'streamPolicy': _stream.name,
      'sessionBuffering': sessionBuffering,
      'configuredReadAheadBytes': readAheadBytes,
      'activeRequests': _active,
      'admissionWaits': _admissionWaits,
      'admissionRejected': _admissionRejected,
      'activeSegmentPrefetchRequests': _activeSegmentPrefetchRequests,
      'upstreamBytesPerSecond': upstreamBytesPerSecond,
      'cacheWorkspaceBytes': _cacheWorkspace,
      'timelineIdentity': _timelineIdentity ?? '',
      'timelineSequence': _timelineSequence,
      'timelineResourcePresent':
          _timelineResource != null || _readAhead != null,
      'timelineRepresentationPresent':
          _representations[_timelineResource ?? _readAhead?.resource] != null,
      'timelineRepresentationComplete':
          _representations[_timelineResource ?? _readAhead?.resource]?.complete,
      'timelineRepresentationStrongValidator':
          _representations[_timelineResource ?? _readAhead?.resource]
              ?.policy
              .strongEtag !=
          null,
      'timelineRepresentationTotalBytes':
          _representations[_timelineResource ?? _readAhead?.resource]?.total,
      'timelineUnknownReason': _timelineUnknownReason,
      'cachedTimeRanges': [
        for (final range in _visibleCachedTimeline)
          {
            'startMs': range.start.inMilliseconds,
            'endMs': range.end.inMilliseconds,
          },
      ],
      'cachedByteIdentity': responseBytes
          ? _responseByteIdentity
          : byteCurrent
          ? _byteIdentity
          : '',
      'cachedByteTotal': responseBytes
          ? buffered!.representation.total
          : byteCurrent
          ? _byteRepresentation!.total
          : null,
      'cachedByteRanges': [
        if (responseBytes)
          for (final range in _responseByteRanges)
            {
              'start': range.start + buffered!.representation.responseStart,
              'end': range.end + buffered.representation.responseStart,
            }
        else if (byteCurrent)
          for (final range in _cachedBytes)
            {'start': range.start, 'end': range.end},
      ],
      'cachedByteCoveredBytes':
          (responseBytes
                  ? _responseByteRanges
                  : byteCurrent
                  ? _cachedBytes
                  : const <CachedByteRange>[])
              .fold<int>(0, (sum, range) => sum + range.end - range.start),
      'timelineCuePoints': _timelineIndex?.points.length ?? 0,
      'timelineTrackSelectionVersion': _trackSelectionVersion,
      'timelineVideoTrackIdentified': _selectedVideoTrackId != null,
      'timelineAudioTrackIdentified': _selectedAudioTrackId != null,
      'readAheadBypassedResources': _readAheadBypass.length,
      'readAheadBypassReason': _readAheadBypassReason,
      'hlsNextSegments': _hlsNext.length,
      'hlsIndexBytes': _hlsIndexBytes,
      'hlsPlaylists': _hlsPlaylists.length,
      'hlsActivePlaylists': _hlsActiveOwners.length,
      'segmentPrefetchActive': _segmentPrefetchJobs.isNotEmpty,
      'segmentPrefetchActiveSlots': _segmentPrefetchJobs.length,
      'segmentPrefetchActivePeak': _segmentPrefetchPeak,
      'segmentPrefetchPending': _pendingSegmentPrefetch.length,
      'segmentPrefetchPreemptions': _segmentPrefetchPreemptions,
      'segmentPrefetchHandoffs': _segmentPrefetchHandoffs,
      'segmentPrefetchDownloadedBytes': _segmentPrefetchDownloadedBytes,
      'segmentPrefetchRefusal': _segmentPrefetchRefusal,
      'serialUpstream': _serialUpstream,
      'playbackActive': _playbackActive,
      'responseReadAheadActive': _responseReadAheads
          .where((b) => !b.stopped)
          .length,
      'responseReadAheadRetained': _responseReadAheads.length,
      'responseReadAheadPublishedBytes': _responseReadAheads.fold<int>(
        0,
        (sum, response) =>
            sum + (response.diagnostics['readAheadPublishedBytes'] as int),
      ),
      ...?_readAhead?.diagnostics,
    };
  }

  static Future<PlaybackHttpProxy> create({
    Uri? origin,
    Map<String, String> headers = const {},
    FutureOr<SessionByteCache>? cache,
    bool dynamicSource = false,
    bool sessionBuffering = false,
    int readAheadBytes = 0,
    int readAheadConcurrency = 1,
    bool continuousTransfers = false,
    FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged,
    Duration mediaHeaderTimeout = const Duration(seconds: 45),
    Duration otherHeaderTimeout = const Duration(seconds: 20),
    Duration bodyStallTimeout = const Duration(seconds: 15),
    Duration verifiedSnapshotTtl = const Duration(seconds: 5),
    Duration integrityRecheck = const Duration(seconds: 2),
  }) async => PlaybackHttpProxy._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    origin,
    Map.unmodifiable(headers),
    cache is SessionByteCache ? cache : null,
    dynamicSource,
    sessionBuffering,
    readAheadBytes,
    readAheadConcurrency,
    continuousTransfers,
    onStreamChanged,
    cache is Future<SessionByteCache> ? cache : null,
    mediaHeaderTimeout,
    otherHeaderTimeout,
    bodyStallTimeout,
    verifiedSnapshotTtl,
    integrityRecheck,
  );

  Duration bufferedEnd(Duration position, Duration demuxerEnd) {
    var end = demuxerEnd < position ? position : demuxerEnd;
    final degradation = cache?.diagnostics['degradation'];
    if (degradation != null && degradation != 'disk-timeout') return end;
    for (final range in _visibleCachedTimeline) {
      if (range.start <= end && range.end > end) end = range.end;
    }
    return end;
  }

  Future<void> refreshTimeline(
    Duration duration, {
    bool verifyChecksum = true,
  }) async {
    if (_bufferedResponse != null) {
      _cachedTimeline = const [];
      await _refreshResponseCoverage();
      return;
    }
    await _refreshTimeTimeline(duration, verifyChecksum: verifyChecksum);
    if (_timelineUnknownReason == null && _cachedTimeline.isNotEmpty) {
      if (_byteIdentity != null) _clearByteCoverage();
      return;
    }
    if (_mappingUnknownReason == 'integrityUnavailable') {
      _retainByteCoverageWhileBusy();
      return;
    }
    if (_mappingUnknownReason == 'cacheChangedDuringIndex') {
      // A time pass can lose its revision either during the integrity query
      // or later while indexing. Keep its verified islands when still current;
      // if another write made them stale, take one independent byte snapshot.
      // An empty verified result needs no second disk query.
      if (_cachedBytes.isNotEmpty && !_byteCoverageCurrent) {
        await _refreshByteCoverage();
      }
      return;
    }
    await _refreshByteCoverage();
  }

  void _timelineRetry(String reason) {
    final last = _lastSuccessfulTimelineAt;
    // A busy optional snapshot is not evidence of eviction. Briefly retain
    // the last verified display while retrying. A fresh complete scan retracts
    // missing bytes; identity changes and close clear immediately. Unrelated
    // uncommitted RAM eviction must not blank the whole display between scans.
    // A persistent inability to verify expires the last snapshot.
    if (last == null ||
        DateTime.now().difference(last) > verifiedSnapshotTtl ||
        cache?.diagnostics['closed'] == true) {
      _cachedTimeline = const [];
    }
    _mappingUnknownReason = reason;
    _timelineAttemptRevision = -1;
    // Optional indexing must not restart its entire allocation/read workload
    // on every 250 ms diagnostics tick while playback or publication is busy.
    // Byte coverage is refreshed independently during this cooldown.
    _timelineRetryAfter = reason == 'indexBudgetOrReadUnavailable'
        ? DateTime.now().add(integrityRecheck)
        : null;
    _timelineSequence++;
  }

  bool get _responseCoverageCurrent {
    final buffered = _bufferedResponse;
    if (_closed ||
        buffered == null ||
        _cacheReadsUncertain ||
        _responseByteIdentity != buffered.buffer.resource ||
        _responseIntegrityAt == null ||
        DateTime.now().difference(_responseIntegrityAt!) >=
            verifiedSnapshotTtl) {
      return false;
    }
    if (_responseCoverageRevision != cache!.coverageRevision) {
      // Reclaiming one consumed block retracts only that part. Keep the other
      // verified islands visible while the next asynchronous scan is pending.
      _responseByteRanges = cache!.retainAvailableRanges(
        resource: buffered.buffer.resource,
        generation: 0,
        verified: _responseByteRanges,
      );
      _responseCoverageRevision = cache!.coverageRevision;
      _timelineSequence++;
    }
    return true;
  }

  Future<void> _refreshResponseCoverage() async {
    final buffered = _bufferedResponse;
    if (buffered == null || _refreshingResponseBytes || _closed) return;
    if (_responseByteIdentity == buffered.buffer.resource &&
        _responseIntegrityRevision == cache!.contentRevision &&
        _responseIntegrityAt != null &&
        DateTime.now().difference(_responseIntegrityAt!) < integrityRecheck) {
      return;
    }
    _refreshingResponseBytes = true;
    final revision = cache!.contentRevision;
    try {
      final ranges = await cache!.availableRanges(
        resource: buffered.buffer.resource,
        generation: 0,
        verifyChecksum: true,
      );
      if (_closed || !identical(buffered, _bufferedResponse)) return;
      if (ranges == null) return;
      _responseByteRanges = ranges;
      _responseByteIdentity = buffered.buffer.resource;
      _responseIntegrityAt = DateTime.now();
      _responseIntegrityRevision = revision;
      _responseCoverageRevision = cache!.coverageRevision;
      _timelineSequence++;
    } finally {
      _refreshingResponseBytes = false;
    }
  }

  bool get _cacheReadsUncertain {
    final degradation = cache?.diagnostics['degradation'];
    // Slow publication is independent of the read/verification workers. Keep
    // recent verified coverage; actual loss, expiry and identity changes still
    // retract it. Otherwise one busy write also appears as a playback hole.
    return degradation != null && degradation != 'disk-timeout';
  }

  Future<void> _refreshByteCoverage() async {
    final representation = _byteRepresentation;
    final resource = _timelineResource ?? _readAhead?.resource;
    if (representation == null || resource == null) {
      if (_byteIdentity != null) _clearByteCoverage();
      return;
    }
    if (_refreshingBytes) return;
    final identity = '$resource:${representation.generation}';
    final revision = cache!.contentRevision;
    if (_byteIdentity == identity &&
        _byteRevision == revision &&
        _lastByteIntegrityCheck != null &&
        DateTime.now().difference(_lastByteIntegrityCheck!) <
            integrityRecheck) {
      return;
    }
    _refreshingBytes = true;
    try {
      final ranges = await cache!.availableRanges(
        resource: resource,
        generation: representation.generation,
        verifyChecksum: true,
      );
      if (_closed ||
          _representations[resource]?.generation != representation.generation ||
          resource != (_timelineResource ?? _readAhead?.resource) ||
          _cacheReadsUncertain) {
        if (_byteIdentity == identity) _clearByteCoverage();
        return;
      }
      if (ranges == null) {
        _retainByteCoverageWhileBusy();
        return;
      }
      // availableRanges filters entries against the live cache after its
      // asynchronous disk check. Concurrent new writes are scanned next.
      _publishByteCoverage(
        resource,
        representation,
        ranges,
        scannedRevision: revision,
      );
    } catch (_) {
      _retainByteCoverageWhileBusy();
    } finally {
      _refreshingBytes = false;
    }
  }

  Future<void> _refreshTimeTimeline(
    Duration duration, {
    bool verifyChecksum = true,
  }) async {
    if (_hlsPlaylists.isNotEmpty) {
      await _refreshHlsTimeline(duration);
      return;
    }
    // Index validated session bytes independently of the optional disk
    // read-ahead worker. A plain 200 response or small demuxer range can have
    // complete media metadata and playable groups without creating that worker.
    final resource = _timelineResource ?? _readAhead?.resource;
    final representation = _representations[resource];
    if (_closed ||
        _refreshingTimeline ||
        cache == null ||
        resource == null ||
        representation == null ||
        !representation.complete ||
        duration <= Duration.zero) {
      if (representation == null && _cachedTimeline.isNotEmpty) {
        _cachedTimeline = const [];
        _timelineSequence++;
      }
      return;
    }
    final identity = '$resource:${representation.generation}';
    final trackSelectionVersion = _trackSelectionVersion;
    final retryAfter = _timelineRetryAfter;
    if (_timelineIdentity == identity &&
        _timelineAttemptDuration == duration &&
        retryAfter != null &&
        DateTime.now().isBefore(retryAfter)) {
      return;
    }
    bool stillCurrent() =>
        !_closed &&
        _timelineIdentity == identity &&
        trackSelectionVersion == _trackSelectionVersion &&
        resource == (_timelineResource ?? _readAhead?.resource) &&
        _representations[resource]?.generation == representation.generation;
    final snapshotRevision = cache!.contentRevision;
    final coverageRevision = cache!.coverageRevision;
    bool revisionCurrent() {
      if (cache!.coverageRevision == coverageRevision) return true;
      if (stillCurrent()) {
        _timelineRetry('cacheChangedDuringIndex');
      }
      return false;
    }

    final lastIntegrityCheck = _lastIntegrityCheck;
    if (_timelineIdentity == identity &&
        _timelineAttemptRevision == snapshotRevision &&
        _timelineAttemptDuration == duration &&
        cache!.diagnostics['degradation'] == null &&
        (!verifyChecksum ||
            lastIntegrityCheck != null &&
                DateTime.now().difference(lastIntegrityCheck) <
                    integrityRecheck)) {
      return;
    }
    if (!_reserveCacheWorkspace(1024 * 1024)) return;
    _refreshingTimeline = true;
    _charge(1024 * 1024);
    CacheRangeLease? indexLease;
    try {
      if (_timelineIdentity != identity) {
        _timelineIdentity = identity;
        _timelineAttemptRevision = -1;
        _lastIntegrityCheck = null;
        _timelineIndex = null;
        _mp4TimelineIndex = null;
        _mappingUnknownReason = null;
        _cachedTimeline = const [];
        _timelineSequence++;
      }
      _timelineAttemptRevision = snapshotRevision;
      _timelineAttemptDuration = duration;
      if (verifyChecksum) _lastIntegrityCheck = DateTime.now();
      final bytes = await cache!.availableRanges(
        resource: resource,
        generation: representation.generation,
        verifyChecksum: verifyChecksum,
      );
      if (!stillCurrent()) return;
      if (bytes == null) {
        _timelineRetry('integrityUnavailable');
        return;
      }
      if (!revisionCurrent()) {
        // availableRanges has already removed missing or replaced entries
        // after its checksum pass. A retracted block invalidates the time index,
        // but these verified byte islands remain conservative for this exact
        // representation and can be shown without another disk scan.
        if (verifyChecksum && _byteRepresentation != null) {
          _publishByteCoverage(
            resource,
            representation,
            bytes,
            scannedRevision: snapshotRevision,
          );
        }
        return;
      }
      // Reuse the already verified cache scan for the phone byte track.
      // Running a second disk checksum pass would consume the same pending
      // budget and delay both playback diagnostics and the foreground reads.
      if (verifyChecksum) {
        _publishByteCoverage(
          resource,
          representation,
          bytes,
          scannedRevision: snapshotRevision,
        );
      }
      // Indexing a partially cached Matroska file can issue many immediate
      // memory reads. Yield to the isolate event queue so seek/cancel and HTTP
      // reads remain responsive, and bound this optional snapshot's work.
      final indexWatch = Stopwatch()..start();
      // Building a long movie's immutable sample index is one-time work. A
      // 250 ms total deadline on a TV can discard it on every attempt, causing
      // repeated allocation/GC and preventing any temporal cache coverage.
      // Keep short cooperative slices, but allow the initial build to finish.
      var indexBudget = _timelineIndex == null && _mp4TimelineIndex == null
          ? const Duration(seconds: 3)
          : const Duration(milliseconds: 250);
      var lastYield = Duration.zero;
      Future<void> checkpoint() async {
        if (!stillCurrent() || indexWatch.elapsed > indexBudget) {
          throw TimeoutException('Cache timeline indexing budget exceeded');
        }
        if (indexWatch.elapsed - lastYield >= const Duration(milliseconds: 4)) {
          await Future<void>.delayed(Duration.zero);
          lastYield = indexWatch.elapsed;
          if (!stillCurrent() || indexWatch.elapsed > indexBudget) {
            throw TimeoutException('Cache timeline indexing budget exceeded');
          }
        }
      }

      var indexReads = 0;
      Future<Uint8List?> read(int offset, int length) async {
        if (++indexReads % 16 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await checkpoint();
        final output = BytesBuilder(copy: false);
        while (output.length < length) {
          final position = offset + output.length;
          final remaining = length - output.length;
          // Optional metadata must not become foreground demand and evict the
          // audio/video working set. Reuse one protected snapshot's scratch
          // block (charged to the existing transfer budget) across nearby
          // header reads without promoting it into the playback RAM cache.
          var hit = await indexLease?.read(
            position,
            maxLength: remaining,
            countHit: false,
          );
          if (hit == null) {
            await indexLease?.close();
            indexLease = await cache!.protectRange(
              resource: resource,
              generation: representation.generation,
              offset: position,
              length: remaining,
            );
            hit = await indexLease?.read(
              position,
              maxLength: remaining,
              countHit: false,
            );
          }
          if (hit == null || hit.bytes.isEmpty) return null;
          output.add(hit.bytes);
        }
        return output.takeBytes();
      }

      final index =
          _timelineIndex ??
          await MatroskaCacheIndex.load(
            total: representation.total,
            read: read,
          );
      if (!stillCurrent()) return;
      _timelineIndex = index;
      if (index != null) {
        _mappingUnknownReason = null;
        final ranges = await index.ranges(bytes, duration, read: read);
        if (!stillCurrent() || !revisionCurrent()) return;
        _cachedTimeline = ranges;
      } else {
        final mp4 =
            _mp4TimelineIndex ??
            await Mp4CacheIndex.load(
              total: representation.total,
              read: read,
              selectedVideoTrackId: _selectedVideoTrackId,
              selectedAudioTrackId: _selectedAudioTrackId,
              checkpoint: checkpoint,
            );
        if (!stillCurrent() || !revisionCurrent()) return;
        _mp4TimelineIndex = mp4;
        // Mapping changing cache ranges remains a short bounded operation,
        // even when this refresh also had to build the immutable index.
        indexWatch.reset();
        lastYield = Duration.zero;
        indexBudget = const Duration(milliseconds: 250);
        final ranges = mp4 == null
            ? const <CachedTimeRange>[]
            : await mp4.rangesWithBudget(
                bytes,
                duration,
                checkpoint: checkpoint,
              );
        if (!stillCurrent() || !revisionCurrent()) return;
        _cachedTimeline = ranges;
        _mappingUnknownReason = mp4 == null
            ? 'containerTrackOrTimingUnknown'
            : null;
      }
      _lastSuccessfulTimelineAt = DateTime.now();
      _timelineRetryAfter = _mappingUnknownReason == null
          ? null
          : DateTime.now().add(integrityRecheck);
      _timelineSequence++;
    } catch (_) {
      if (stillCurrent()) {
        _timelineRetry('indexBudgetOrReadUnavailable');
      }
    } finally {
      await indexLease?.close();
      _charge(-1024 * 1024);
      _releaseCacheWorkspace(1024 * 1024);
      _refreshingTimeline = false;
    }
  }

  Future<void> _refreshHlsTimeline(Duration duration) async {
    if (_closed ||
        _refreshingTimeline ||
        cache == null ||
        duration <= Duration.zero) {
      return;
    }
    _refreshingTimeline = true;
    try {
      final owners = _hlsActiveOwners.where(_hlsPlaylists.containsKey).toList()
        ..sort();
      final identity = 'hls:${owners.join(':')}';
      if (_timelineIdentity != identity) {
        _timelineIdentity = identity;
        _cachedTimeline = const [];
        _timelineSequence++;
      }
      if (owners.isEmpty || owners.length > 2) {
        _hlsUnknownReason = 'hlsSelectionUnverified';
        _cachedTimeline = const [];
        _timelineSequence++;
        return;
      }
      final resources = <Uri, HlsCachedResource>{};
      var probesLeft = 2;
      final mapped = <_HlsMappedPlaylist>[];
      for (final owner in owners) {
        final state = _hlsPlaylists[owner]!;
        final index = state.index;
        if (index == null ||
            index.isLive ||
            index.mediaSequence != 0 ||
            index.segments.any(
              (segment) =>
                  segment.discontinuitySequence !=
                  index.segments.first.discontinuitySequence,
            )) {
          _hlsUnknownReason = 'hlsPlaylistMappingUnavailable';
          _cachedTimeline = const [];
          _timelineSequence++;
          return;
        }
        for (final segment in index.segments) {
          if (segment.mapUri == null || segment.keyUri != null) continue;
          final media = await _hlsResource(segment.uri);
          final init = await _hlsResource(segment.mapUri!);
          if (media == null || init == null) {
            state.verified.remove(segment.sequence);
            continue;
          }
          resources[segment.uri] = media.availability;
          resources[segment.mapUri!] = init.availability;
          final signature =
              '${media.key}:${media.representation.generation}:'
              '${segment.byteRange?.start ?? -1}:${segment.byteRange?.end ?? -1}:'
              '${init.key}:${init.representation.generation}:'
              '${segment.mapRange?.start ?? -1}:${segment.mapRange?.end ?? -1}';
          if (!media.availability.contains(segment.byteRange) ||
              !init.availability.contains(segment.mapRange)) {
            state.verified.remove(segment.sequence);
            _hlsProbeCache.remove(signature);
            continue;
          }
          var verified = state.verified[segment.sequence];
          if (verified != null && verified.identity != signature) {
            state.verified.remove(segment.sequence);
            verified = null;
          }
          if (verified == null &&
              probesLeft > 0 &&
              media.availability.contains(segment.byteRange) &&
              init.availability.contains(segment.mapRange)) {
            probesLeft--;
            var result = _hlsProbeCache[signature];
            if (result == null && _reserveCacheWorkspace(1024 * 1024)) {
              _charge(1024 * 1024);
              try {
                if (await _hlsVerifyReadable(init, segment.mapRange) &&
                    await _hlsVerifyReadable(media, segment.byteRange)) {
                  final initStart = segment.mapRange?.start ?? 0;
                  final initLength = segment.mapRange == null
                      ? init.representation.total
                      : segment.mapRange!.end - initStart;
                  final mediaStart = segment.byteRange?.start ?? 0;
                  final mediaLength = segment.byteRange == null
                      ? media.representation.total
                      : segment.byteRange!.end - mediaStart;
                  result = await probeHlsFmp4Segment(
                    initializationLength: initLength,
                    segmentLength: mediaLength,
                    readInitialization: (offset, length) =>
                        _hlsReadExact(init, initStart + offset, length),
                    readSegment: (offset, length) =>
                        _hlsReadExact(media, mediaStart + offset, length),
                  );
                }
              } finally {
                _charge(-1024 * 1024);
                _releaseCacheWorkspace(1024 * 1024);
              }
              if (result != null) {
                if (_hlsProbeCache.length >= 64) {
                  _hlsProbeCache.remove(_hlsProbeCache.keys.first);
                }
                _hlsProbeCache[signature] = result;
              }
            }
            if (result != null) {
              verified = _HlsVerifiedProbe(signature, result);
              state.verified[segment.sequence] = verified;
            }
          }
        }
        final first = state.verified[index.segments.first.sequence]?.result;
        if (first == null) continue;
        final times = <int, HlsVerifiedSegmentTime>{};
        var consistent = true;
        for (final segment in index.segments) {
          final result = state.verified[segment.sequence]?.result;
          if (result == null) continue;
          if (result.hasVideo != first.hasVideo ||
              result.hasAudio != first.hasAudio) {
            consistent = false;
            break;
          }
          final start = result.start - first.start;
          final end = result.end - first.start;
          if (start < Duration.zero || end <= start) {
            consistent = false;
            break;
          }
          times[segment.sequence] = HlsVerifiedSegmentTime(
            start: start,
            end: end,
            timelineEpoch: 0,
            decodeStartVerified: true,
            requiresInitialization: true,
          );
        }
        if (!consistent) continue;
        final timeline = HlsCacheIndex.parseMediaPlaylist(
          text: state.text,
          playlistUri: state.base,
          verifiedTimes: times,
        );
        if (timeline != null) {
          mapped.add(
            _HlsMappedPlaylist(
              timeline,
              first.hasVideo,
              first.hasAudio,
              first.start,
            ),
          );
        }
      }
      List<CachedTimeRange> ranges = const [];
      if (mapped.length == 1 &&
          (mapped.single.hasAudio && mapped.single.hasVideo ||
              mapped.single.hasAudio && _hlsPlaylists.length == 1)) {
        ranges = mapped.single.index.ranges(
          resources: resources,
          usableSessionKeys: const {},
        );
      } else if (mapped.length == 2) {
        final videos = mapped.where((item) => item.hasVideo && !item.hasAudio);
        final audios = mapped.where((item) => item.hasAudio && !item.hasVideo);
        if (videos.length == 1 &&
            audios.length == 1 &&
            videos.single.rawStart == audios.single.rawStart) {
          ranges = videos.single.index.ranges(
            resources: resources,
            usableSessionKeys: const {},
            selectedAudio: audios.single.index,
          );
        }
      }
      _cachedTimeline = [
        for (final range in ranges)
          if (range.start < duration && range.end > Duration.zero)
            CachedTimeRange(
              range.start < Duration.zero ? Duration.zero : range.start,
              range.end > duration ? duration : range.end,
            ),
      ];
      _hlsUnknownReason = _cachedTimeline.isEmpty
          ? 'hlsTimingUnavailable'
          : null;
      _timelineSequence++;
    } catch (_) {
      _cachedTimeline = const [];
      _hlsUnknownReason = 'hlsCacheUncertain';
      _timelineSequence++;
    } finally {
      _refreshingTimeline = false;
    }
  }

  Future<_HlsResource?> _hlsResource(Uri uri) async {
    final key = _hlsRouteIdentity(uri);
    final representation = key == null ? null : _representations[key];
    if (key == null ||
        representation == null ||
        !representation.complete ||
        representation.total <= 0 ||
        representation.total > 16 * 1024 * 1024) {
      return null;
    }
    final bytes = await cache!.availableRanges(
      resource: key,
      generation: representation.generation,
      verifyChecksum: true,
    );
    if (bytes == null || !identical(_representations[key], representation)) {
      return null;
    }
    return _HlsResource(
      key,
      representation,
      HlsCachedResource(length: representation.total, ranges: bytes),
    );
  }

  Future<bool> _hlsVerifyReadable(
    _HlsResource resource,
    CachedByteRange? requested,
  ) async {
    final start = requested?.start ?? 0;
    final end = requested?.end ?? resource.representation.total;
    if (start < 0 ||
        end <= start ||
        end > resource.representation.total ||
        end - start > 16 * 1024 * 1024) {
      return false;
    }
    var cursor = start;
    while (cursor < end) {
      final hit = await cache!.read(
        resource: resource.key,
        generation: resource.representation.generation,
        offset: cursor,
        maxLength: min(64 * 1024, end - cursor),
        countHit: false,
      );
      if (hit == null ||
          hit.bytes.isEmpty ||
          !identical(_representations[resource.key], resource.representation)) {
        return false;
      }
      cursor += hit.bytes.length;
    }
    return true;
  }

  Future<Uint8List?> _hlsReadExact(
    _HlsResource resource,
    int offset,
    int length,
  ) async {
    if (length < 0 ||
        length > 512 * 1024 ||
        offset < 0 ||
        offset + length > resource.representation.total) {
      return null;
    }
    final output = BytesBuilder(copy: false);
    while (output.length < length) {
      final hit = await cache!.read(
        resource: resource.key,
        generation: resource.representation.generation,
        offset: offset + output.length,
        maxLength: min(64 * 1024, length - output.length),
        countHit: false,
      );
      if (hit == null ||
          hit.bytes.isEmpty ||
          !identical(_representations[resource.key], resource.representation)) {
        return null;
      }
      output.add(hit.bytes);
    }
    return output.takeBytes();
  }

  /// Remembers [bytes] for [url] so a later range that stays inside them is
  /// answered without another upstream request.
  void installWarmPrefix(Uri url, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) return;
    final token = _routes.seal(url, PlaybackResourceRole.media.index, '');
    final identity = _routes.open(token)?.identity;
    if (identity == null) return;
    _warmIdentity = identity;
    _warmPrefix = Uint8List.fromList(bytes);
  }

  Future<bool> _serveWarmPrefix(
    HttpRequest incoming,
    String key,
    Uri url,
    _ProxyRead read,
  ) async {
    final warm = _warmPrefix;
    if (warm == null || key != _warmIdentity || incoming.method != 'GET') {
      return false;
    }
    final header = incoming.headers.value(HttpHeaders.rangeHeader);
    final match = header == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header);
    if (match == null) return false;
    final start = int.parse(match.group(1)!);
    final endText = match.group(2)!;
    final requestedEnd = endText.isEmpty ? null : int.parse(endText);
    if (start < 0 || start >= warm.length) return false;
    if (requestedEnd != null && requestedEnd < start) return false;
    final inside = requestedEnd != null && requestedEnd < warm.length;
    final upstreamRange = requestedEnd == null
        ? 'bytes=${warm.length}-'
        : inside
        ? 'bytes=${warm.length}-${warm.length}'
        : 'bytes=${warm.length}-$requestedEnd';
    HttpClientResponse upstream;
    Uri effective;
    try {
      final fetched = await _fetch(
        incoming,
        url,
        allowRange: true,
        read: read,
        overrides: {'range': upstreamRange},
      );
      upstream = fetched.$1;
      effective = fetched.$2;
    } catch (_) {
      return false;
    }
    if (_cacheReady != null) {
      await Future.any([_cacheReady!, read.cancelledFuture]);
      read.check();
    }
    final parsed = MediaContentRange.parse(
      upstream.headers.value('content-range'),
    );
    if (upstream.statusCode != HttpStatus.partialContent ||
        parsed == null ||
        parsed.start != warm.length) {
      await upstream.drain<void>();
      return false;
    }
    if (!inside && requestedEnd != null && parsed.end > requestedEnd) {
      await upstream.drain<void>();
      return false;
    }
    final responseEnd = inside ? requestedEnd : parsed.end;
    if (responseEnd < start || responseEnd >= parsed.total) {
      await upstream.drain<void>();
      return false;
    }
    await _classify(PlaybackCacheStream.stable);
    // The prefetched bytes do not carry a current response validator.
    // Only the newly validated suffix enters this episode's cache. Its requested
    // range differs from the stitched response sent to the native decoder.
    final representation = _beginRepresentation(
      incoming,
      key,
      upstream,
      effective,
      requestedRange: upstreamRange,
    );
    final output = incoming.response;
    output.statusCode = HttpStatus.partialContent;
    output.headers.set('accept-ranges', 'bytes');
    final type = upstream.headers.contentType;
    if (type != null) output.headers.contentType = type;
    final etag = upstream.headers.value('etag');
    if (etag != null && etag.length <= 1024) output.headers.set('etag', etag);
    output.headers.set(
      'content-range',
      'bytes $start-$responseEnd/${parsed.total}',
    );
    output.contentLength = responseEnd - start + 1;
    final warmEnd = min(warm.length, responseEnd + 1);
    final blockSize = min(1024 * 1024, parsed.end - parsed.start + 1);
    final reserved =
        representation != null && _reserveCacheWorkspace(blockSize);
    Uint8List? assembly = reserved ? Uint8List(blockSize) : null;
    var assembled = 0;
    var blockStart = parsed.start;
    var received = 0;
    var complete = false;
    if (reserved) _charge(blockSize);
    void retain(Uint8List bytes) {
      var cursor = 0;
      while (cursor < bytes.length) {
        final length = min(blockSize - assembled, bytes.length - cursor);
        assembly!.setRange(assembled, assembled + length, bytes, cursor);
        cursor += length;
        assembled += length;
        if (assembled == blockSize) {
          _store(key, representation!, blockStart, assembly!);
          blockStart += assembled;
          assembled = 0;
          assembly = Uint8List(blockSize);
        }
      }
    }

    Stream<List<int>> body() async* {
      read.check();
      if (start < warmEnd) {
        read.outputStarted = true;
        yield Uint8List.sublistView(warm, start, warmEnd);
      }
      await for (final chunk in upstream) {
        read.check();
        _received(chunk.length, media: !inside);
        received += chunk.length;
        if (received > parsed.end - parsed.start + 1) {
          throw const HttpException('Invalid warm suffix length');
        }
        if (inside) continue;
        for (var offset = 0; offset < chunk.length; offset += 64 * 1024) {
          final piece = Uint8List.fromList(
            chunk.sublist(offset, min(offset + 64 * 1024, chunk.length)),
          );
          _charge(piece.length * 2);
          try {
            if (assembly != null &&
                _representations[key]?.generation ==
                    representation!.generation) {
              retain(piece);
            }
            read.outputStarted = true;
            yield piece;
          } finally {
            _charge(-piece.length * 2);
          }
        }
      }
      if (received != parsed.end - parsed.start + 1) {
        throw const HttpException('Truncated warm suffix');
      }
      complete = true;
      if (representation != null) representation.complete = true;
    }

    try {
      return await _sendBody(output, body());
    } finally {
      if (reserved) {
        if (!inside &&
            assembled > 0 &&
            (complete || representation.policy.strongEtag != null) &&
            _representations[key]?.generation == representation.generation) {
          _store(
            key,
            representation,
            blockStart,
            Uint8List.sublistView(assembly!, 0, assembled),
          );
        }
        _charge(-blockSize);
        _releaseCacheWorkspace(blockSize);
      }
      if (!complete &&
          representation != null &&
          representation.policy.strongEtag == null) {
        _invalidate(key, representation);
      }
    }
  }

  Uri register(
    Uri url, {
    PlaybackResourceRole role = PlaybackResourceRole.media,
    String context = '',
  }) {
    if (url.scheme == 'file' && role == PlaybackResourceRole.subtitle) {
      final path = _validatedPrivateSubtitle(url);
      if (_privateSubtitles.length >= 32) {
        throw StateError('Too many private subtitle routes');
      }
      final token = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _privateSubtitles[token] = path;
      _roles[token] = PlaybackResourceRole.subtitle;
      // The native subtitle decoder selects SRT/WebVTT/ASS from the sealed
      // URL suffix. Preserve only the already validated file extension.
      final extension = path.split('.').last.toLowerCase();
      return Uri.parse(
        'http://127.0.0.1:${_server.port}/$_secret/$token/subtitle.$extension',
      );
    }
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw ArgumentError('Only HTTP(S) media resources are allowed');
    }
    if (url.toString().length > 16384 || context.length > 4096) {
      throw ArgumentError('Media resource identifier is too large');
    }
    final token = _routes.seal(url, role.index, context);
    final suffix = url.path.split('/').last;
    return Uri.parse(
      'http://127.0.0.1:${_server.port}/$_secret/$token/${Uri.encodeComponent(suffix.substring(0, min(suffix.length, 128)))}',
    );
  }

  String _validatedPrivateSubtitle(Uri uri) {
    final file = File.fromUri(uri);
    final path = file.resolveSymbolicLinksSync();
    final canonical = File(path);
    final temp = Directory.systemTemp.resolveSymbolicLinksSync();
    final parent = canonical.parent;
    final parentPath = parent.parent.path;
    final insideTemp = Platform.isWindows
        ? parentPath.toLowerCase() == temp.toLowerCase()
        : parentPath == temp;
    final extension = canonical.uri.pathSegments.last
        .split('.')
        .last
        .toLowerCase();
    if (!insideTemp ||
        !parent.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('rillight-subtitles-') ||
        !const {'srt', 'ass', 'ssa', 'vtt'}.contains(extension) ||
        canonical.statSync().type != FileSystemEntityType.file ||
        canonical.lengthSync() > 16 * 1024 * 1024) {
      throw ArgumentError('External subtitle is not an app-private file');
    }
    return path;
  }

  Uri _withoutForeignCredentials(Uri url) {
    if (origin != null && url.origin == origin!.origin) return url;
    final tokens = headers.entries
        .where((e) => e.key.toLowerCase() == 'x-emby-token')
        .map((e) => e.value)
        .where((e) => e.isNotEmpty)
        .toSet();
    return withoutEmbyTokenValues(url, tokens);
  }

  Future<(HttpClientResponse, Uri)> _fetch(
    HttpRequest incoming,
    Uri url, {
    bool allowRange = true,
    required _ProxyRead read,
    String? method,
    Map<String, String?> overrides = const {},
    bool reportAuthentication = true,
  }) async {
    final started = DateTime.now();
    Object? lastFailure;
    for (var attempt = 0; attempt < 6; attempt++) {
      read.check();
      try {
        final result = await _fetchOnce(
          incoming,
          url,
          allowRange: allowRange,
          read: read,
          method: method,
          overrides: overrides,
          reportAuthentication: reportAuthentication,
        );
        final status = result.$1.statusCode;
        if ((method ?? incoming.method) == 'HEAD' ||
            (incoming.headers.value('x-rillight-prefetch') == '1' &&
                (status == 429 || status == 409)) ||
            !_retryableStatus(status) ||
            attempt == 5) {
          if (_retryableStatus(status) && attempt == 5) {
            _recoveryFailures++;
          } else if (attempt > 0 && status >= 200 && status < 400) {
            _recoveries++;
          }
          return result;
        }
        final retryAfter = _retryAfter(result.$1.headers.value('retry-after'));
        await _retireRejectedResponse(result.$1, read);
        for (final request in read.requests.toList()) {
          request.abort();
        }
        await _backoff(
          attempt,
          started,
          read,
          retryAfter: retryAfter,
          fastFailover: status == 502 || status == 504,
        );
        _recoveryAttempts++;
      } on SocketException catch (error) {
        lastFailure = error;
        if (attempt == 5) {
          _recoveryFailures++;
          rethrow;
        }
        for (final request in read.requests.toList()) {
          request.abort();
        }
        await _backoff(attempt, started, read);
        _recoveryAttempts++;
      } on TimeoutException catch (error) {
        lastFailure = error;
        if (attempt == 5) {
          _recoveryFailures++;
          rethrow;
        }
        for (final request in read.requests.toList()) {
          request.abort();
        }
        await _backoff(attempt, started, read);
        _recoveryAttempts++;
      } on HttpException catch (error) {
        lastFailure = error;
        if (attempt == 5) {
          _recoveryFailures++;
          rethrow;
        }
        for (final request in read.requests.toList()) {
          request.abort();
        }
        await _backoff(attempt, started, read);
        _recoveryAttempts++;
      }
    }
    throw StateError('Media recovery exhausted: $lastFailure');
  }

  static bool _retryableStatus(int status) =>
      status == 408 || status == 429 || status >= 500 && status <= 599;

  Future<void> _retireRejectedResponse(
    HttpClientResponse response,
    _ProxyRead read,
  ) async {
    if (identical(read.response, response)) read.response = null;
    // Do not return a failed keep-alive connection to the pool. A load balancer
    // may bind that connection to an unhealthy node; a fresh connection lets
    // the next retry be routed again. Never discard healthy cached bytes.
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (_) {
      try {
        await response.listen(null, onError: (Object _) {}).cancel();
      } on StateError {
        // Already owned by a response iterator.
      }
    }
  }

  static Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 120));
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now());
      return delay < Duration.zero ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }

  Future<void> _backoff(
    int attempt,
    DateTime started,
    _ProxyRead read, {
    Duration? retryAfter,
    bool fastFailover = false,
  }) async {
    final elapsed = DateTime.now().difference(started);
    final remaining = const Duration(seconds: 120) - elapsed;
    final seconds = min(15, 1 << attempt);
    final jitter = Random().nextInt(201) - 100;
    final base = fastFailover
        ? Duration(
            milliseconds:
                (attempt == 0 ? 150 : min(4000, 250 * (1 << attempt))) +
                jitter ~/ 2,
          )
        : Duration(milliseconds: min(15000, seconds * 1000 + jitter));
    final delay = retryAfter != null && retryAfter > base ? retryAfter : base;
    if (remaining <= Duration.zero || delay > remaining) {
      throw const _MediaRecoveryExhausted();
    }
    await Future.any([Future<void>.delayed(delay), read.cancelledFuture]);
    read.check();
  }

  Future<(HttpClientResponse, Uri)> _fetchOnce(
    HttpRequest incoming,
    Uri url, {
    required bool allowRange,
    required _ProxyRead read,
    String? method,
    required Map<String, String?> overrides,
    bool reportAuthentication = true,
  }) async {
    read.releaseUnconsumedResponse();
    void Function()? resumeReadAhead;
    var yieldedMediaTransfer = false;
    if (_serialUpstream && !read.readAheadProducer) {
      await _retireBufferedResponses(read);
    }
    if ((_serialUpstream || readAheadConcurrency == 1) &&
        !read.readAheadProducer) {
      yieldedMediaTransfer =
          (_readAhead?.diagnostics['readAheadConcurrentTransfers'] as int? ??
              0) >
          0;
      resumeReadAhead = await _readAhead?.yieldToForeground();
    }
    try {
      url = _refreshedUrls[read.resourceKey] ?? url;
      for (var redirects = 0; redirects <= 10; redirects++) {
        read.check();
        _lastRequestedResourceRole = _roles[read.resourceKey]?.name;
        _lastRequestedRedirectCount = redirects;
        url = _withoutForeignCredentials(url);
        final opening = _client.openUrl(method ?? incoming.method, url);
        final request = await _observeUpstream(
          'connect',
          () => opening.timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              unawaited(
                opening.then<void>(
                  (late) => late.abort(),
                  onError: (Object _) {},
                ),
              );
              throw const HttpException('Media connection timeout');
            },
          ),
        );
        read.requests.clear();
        read.requests.add(request);
        if (read.cancelled) {
          request.abort();
          read.check();
        }
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        for (final name in [
          'range',
          'if-range',
          'if-modified-since',
          'if-none-match',
        ]) {
          if (name == 'range' &&
              (!allowRange || url.path.toLowerCase().endsWith('.m3u8'))) {
            continue;
          }
          final value = overrides.containsKey(name)
              ? overrides[name]
              : incoming.headers.value(name);
          if (value != null) request.headers.set(name, value);
        }
        for (final header in headers.entries) {
          if (header.key.toLowerCase() == 'user-agent' ||
              (origin != null && url.origin == origin!.origin)) {
            request.headers.set(header.key, header.value);
          }
        }
        // A fast range says nothing about the next cold range or LB node.
        // Real media responses can take 30+ seconds to send headers and then
        // transfer at full speed. Keep a bounded budget without learning a
        // shorter deadline from one healthy response.
        final media = _roles[read.resourceKey] == PlaybackResourceRole.media;
        final headerDeadline = media ? mediaHeaderTimeout : otherHeaderTimeout;
        final response = await _observeUpstream(
          'headers',
          () => request.close().timeout(
            headerDeadline,
            onTimeout: () {
              if (media && !read.cancelled) _mediaHeaderTimeouts++;
              request.abort();
              throw TimeoutException('Media response timeout', headerDeadline);
            },
          ),
        );
        read.response = response;
        if (read.cancelled) read.releaseUnconsumedResponse();
        read.check();
        // A demuxer/index request can be the connection rejected by the origin,
        // not just a speculative lane. Resolve that contention before exposing
        // 403 as authentication failure to the player. A serial retry's genuine
        // 403 still follows the normal authentication path.
        if (!read.readAheadProducer &&
            !_serialUpstream &&
            const [403, 409, 429, 503].contains(response.statusCode) &&
            (yieldedMediaTransfer ||
                (_readAhead?.diagnostics['readAheadConcurrentTransfers']
                            as int? ??
                        0) >
                    0 ||
                _responseReadAheads.isNotEmpty)) {
          request.abort();
          await _retireRejectedResponse(response, read);
          read.requests.clear();
          _useSerialUpstream();
          read.claimRefusalRetry();
          final resumePrevious = resumeReadAhead;
          final resumeAfterRefusal = await _readAhead?.yieldToForeground(
            refusal: 'foreground-http-${response.statusCode}',
          );
          resumeReadAhead = () {
            resumeAfterRefusal?.call();
            resumePrevious?.call();
          };
          await _retireBufferedResponses(read);
          final retryAfter = _retryAfter(response.headers.value('retry-after'));
          if (retryAfter != null) {
            await _backoff(0, DateTime.now(), read, retryAfter: retryAfter);
          }
          _recoveryAttempts++;
          continue;
        }
        // A just-completed stream can still hold the origin's lease briefly.
        // This also affects the first request after switching sources: the new
        // transport has no representation yet. Retry one foreground media GET
        // on a fresh connection before publishing the refusal as an auth error.
        // Cache gap probes and their foreground fallback share this budget.
        if (response.statusCode == HttpStatus.forbidden &&
            (method ?? incoming.method) == 'GET' &&
            _roles[read.resourceKey] == PlaybackResourceRole.media &&
            (!read.readAheadProducer ||
                _representations[read.resourceKey]?.rangeSupported == true) &&
            _readAhead?.hasParallelTransfers != true &&
            read.claimRefusalRetry()) {
          await _retireRejectedResponse(response, read);
          for (final previous in read.requests.toList()) {
            previous.abort();
          }
          read.requests.clear();
          await _backoff(
            0,
            DateTime.now(),
            read,
            retryAfter: _retryAfter(response.headers.value('retry-after')),
          );
          _recoveryAttempts++;
          continue;
        }
        _lastUpstreamStatus = response.statusCode;
        final role = _roles[read.resourceKey];
        final speculative =
            incoming.headers.value('x-rillight-prefetch') == '1';
        _lastUpstreamResourceRole = role?.name;
        if (role != PlaybackResourceRole.subtitle &&
            reportAuthentication &&
            !speculative) {
          _lastMediaUpstreamStatus = response.statusCode;
        }
        if (reportAuthentication &&
            !speculative &&
            role != PlaybackResourceRole.subtitle &&
            (response.statusCode == HttpStatus.unauthorized ||
                response.statusCode == HttpStatus.forbidden)) {
          _authenticationStatus = response.statusCode;
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
            location != null) {
          await _discard(response, read);
          final next = url.resolve(location);
          if (next.toString().length > 16384 ||
              next.scheme != 'http' && next.scheme != 'https') {
            throw StateError('Unsupported media redirect');
          }
          url = next;
          continue;
        }
        return (response, url);
      }
      throw StateError('Too many media redirects');
    } finally {
      resumeReadAhead?.call();
    }
  }

  Future<T> _observeUpstream<T>(String phase, Future<T> Function() work) async {
    _upstreamPhases[phase] = (_upstreamPhases[phase] ?? 0) + 1;
    _lastUpstreamPhase = phase;
    final elapsed = Stopwatch()..start();
    try {
      return await work();
    } catch (error) {
      // Never expose exception messages: sockets and HTTP errors may contain
      // the original media URL, signed query, or server address.
      _lastUpstreamFailureKind = switch (error) {
        HandshakeException() => 'tls',
        SocketException() => 'socket',
        TimeoutException() => 'timeout',
        HttpException() => 'http',
        _ => 'other',
      };
      rethrow;
    } finally {
      _upstreamPhases[phase] = _upstreamPhases[phase]! - 1;
      _lastUpstreamPhaseElapsedMs = elapsed.elapsedMilliseconds;
    }
  }

  void _pruneSamples() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 1));
    _samples.removeWhere((sample) => sample.$1.isBefore(cutoff));
  }

  Future<bool> _advance(
    StreamIterator<List<int>> iterator,
    _ProxyRead read,
  ) async {
    try {
      final result = await Future.any<Object?>([
        iterator.moveNext(),
        read.cancelledFuture.then<Object?>((_) => null),
      ]).timeout(bodyStallTimeout);
      if (result == null) read.check();
      return result as bool;
    } on TimeoutException {
      for (final request in read.requests.toList()) {
        request.abort();
      }
      throw const HttpException('Media body stalled');
    }
  }

  void _received(int count, {bool media = true}) {
    _upstreamBytes += count;
    if (!media) {
      _controlDownloadBytes += count;
      return;
    }
    _mediaDownloadBytes += count;
    _pruneSamples();
    final now = DateTime.now();
    if (_samples.isNotEmpty &&
        now.difference(_samples.last.$1).inMilliseconds < 50) {
      final previous = _samples.removeLast();
      _samples.add((previous.$1, previous.$2 + count));
    } else {
      _samples.add((now, count));
    }
  }

  void _charge(int bytes) {
    _inFlight += bytes;
    _inFlightPeak = max(_inFlightPeak, _inFlight);
  }

  bool _reserveCacheWorkspace(int bytes) {
    // Each live transport retains at most its current forwarding chunk. Leave
    // 1 MiB for eight transports; the rest of the 4/12 MiB proxy budget is shared
    // by assemblies, cached reads and playlist rewriting. Under pressure cache
    // work is bypassed, so an index probe can still reach its upstream source.
    final limit =
        (_stream == PlaybackCacheStream.stable ? 11 : 3) * 1024 * 1024;
    if (_cacheWorkspace + bytes > limit) return false;
    _cacheWorkspace += bytes;
    return true;
  }

  void _releaseCacheWorkspace(int bytes) {
    _cacheWorkspace -= bytes;
    if (_pendingSegmentPrefetch.isNotEmpty) _pumpSegmentPrefetch();
  }

  Future<void> _discard(HttpClientResponse response, _ProxyRead read) async {
    final iterator = StreamIterator(response);
    read.iterators.add(iterator);
    try {
      while (await _advance(iterator, read)) {
        read.check();
        _received(iterator.current.length, media: false);
      }
    } finally {
      read.iterators.remove(iterator);
      await iterator.cancel();
    }
  }

  /// Published representation bytes survive cancellation. Seek preserves
  /// position-independent subtitle loads; close cancels every outstanding read.
  void cancelPendingReads({bool preserveSubtitles = false}) {
    _seekGeneration++;
    for (final buffered in _responseReadAheads) {
      buffered.cancelReaders();
    }
    if (_hlsPlaylists.isNotEmpty) {
      _hlsActiveOwners.clear();
      _cachedTimeline = const [];
      _hlsUnknownReason = 'hlsSelectionUnverified';
      _timelineSequence++;
    }
    _cancelSegmentPrefetch(clearPending: true);
    final ahead = _readAhead;
    if (ahead?.failed == true) {
      _readAhead = null;
      _readAheadBypass.remove(ahead!.resource);
      unawaited(ahead.close());
    } else {
      ahead?.stop();
    }
    for (final read in _reads.toList()) {
      if (preserveSubtitles &&
          _roles[read.resourceKey] == PlaybackResourceRole.subtitle) {
        continue;
      }
      if (!read.cancelled) {
        _cancelled++;
        read.cancel();
      }
    }
  }

  void _cancelSegmentPrefetch({
    bool clearPending = false,
    bool requeue = true,
    String? owner,
  }) {
    if (clearPending) {
      _pendingSegmentPrefetch.clear();
      _hlsPrefetchWindows.clear();
    }
    final jobs = owner == null
        ? _segmentPrefetchJobs.values.toList()
        : [
            _segmentPrefetchJobs[owner],
          ].whereType<_SegmentPrefetchJob>().toList();
    for (final job in jobs) {
      if (!clearPending && requeue) _queueSegmentPrefetch(job.next);
      job.cancel();
    }
    if (owner == null) _segmentPrefetchGeneration++;
  }

  void _scheduleSegmentPrefetch(String current) {
    final next = _hlsNext[current];
    if (_closed ||
        !_playbackActive ||
        _segmentPrefetchRefusal != null ||
        next == null ||
        cache == null ||
        cache!.diagnostics['degradation'] != null ||
        dynamicSource) {
      return;
    }
    if (sessionBuffering &&
        readAheadBytes > 0 &&
        _hlsPrefetchWindows[next.owner]?.anchor != current) {
      // Warm several complete VOD segments without increasing connection
      // concurrency. Bound the window by both segment count and cache budget.
      final storage = cache!;
      final budget = storage.diagnostics['diskLimitBytes'] is int
          ? storage.diskSessionLimitBytes ~/ 4
          : storage.memoryLimitBytes ~/ 2;
      _hlsPrefetchWindows[next.owner] = _HlsPrefetchWindow(
        current,
        min(readAheadBytes, min(32 * 1024 * 1024, budget)),
      );
    }
    _queueSegmentPrefetch(next);
    _pumpSegmentPrefetch();
  }

  void _queueSegmentPrefetch(_HlsNext next) {
    // Keep the latest demand for each media playlist. Two independent tracks
    // must not overwrite each other while a foreground read preempts prefetch.
    _pendingSegmentPrefetch.remove(next.owner);
    if (_pendingSegmentPrefetch.length >= 4) {
      _pendingSegmentPrefetch.remove(_pendingSegmentPrefetch.keys.first);
    }
    _pendingSegmentPrefetch[next.owner] = next;
  }

  bool get _segmentPrefetchPressured {
    final storage = cache;
    if (storage == null) return true;
    final data = storage.diagnostics;
    final pending = data['pendingBytes'] as int? ?? 0;
    final pendingLimit = data['pendingLimitBytes'] as int? ?? 0;
    final workspaceLimit =
        (_stream == PlaybackCacheStream.stable ? 11 : 3) * 1024 * 1024;
    return data['degradation'] != null ||
        data['pendingResizePending'] == true ||
        pendingLimit <= 0 ||
        pending >= pendingLimit ||
        _cacheWorkspace >= workspaceLimit;
  }

  void _armSegmentPrefetchCapacityWakeup() {
    final storage = cache;
    if (storage == null ||
        _pendingSegmentPrefetch.isEmpty ||
        _segmentPrefetchCapacityWakeup != null) {
      return;
    }
    final wakeup = storage.pendingChanged;
    _segmentPrefetchCapacityWakeup = wakeup;
    unawaited(
      wakeup.whenComplete(() {
        if (!identical(_segmentPrefetchCapacityWakeup, wakeup)) return;
        _segmentPrefetchCapacityWakeup = null;
        _pumpSegmentPrefetch();
      }),
    );
  }

  void _pumpSegmentPrefetch() {
    if (_closed || !_playbackActive || _segmentPrefetchRefusal != null) return;
    if (_segmentPrefetchPressured) {
      _armSegmentPrefetchCapacityWakeup();
      return;
    }
    // At most two playlist owners may speculate. Keep two of the eight proxy
    // request slots exclusively available to foreground playback/control.
    while (_segmentPrefetchJobs.length < 2 &&
        _active + _segmentPrefetchJobs.length < _maxRequests - 2 &&
        _pendingSegmentPrefetch.isNotEmpty) {
      final owner = _pendingSegmentPrefetch.keys
          .where((key) => !_segmentPrefetchJobs.containsKey(key))
          .firstOrNull;
      if (owner == null) break;
      final next = _pendingSegmentPrefetch.remove(owner)!;
      final window = _hlsPrefetchWindows[owner];
      final job = _SegmentPrefetchJob(next);
      _segmentPrefetchJobs[owner] = job;
      _segmentPrefetchPeak = max(
        _segmentPrefetchPeak,
        _segmentPrefetchJobs.length,
      );
      final generation = _segmentPrefetchGeneration;
      late final Future<void> task;
      task =
          (() async {
            if (_closed ||
                job.cancelled ||
                generation != _segmentPrefetchGeneration) {
              return;
            }
            final disk = cache!.diagnostics['diskLimitBytes'] is int;
            var limit = min(
              SessionReadAhead.requestBytes,
              disk
                  ? cache!.diskSessionLimitBytes ~/ 4
                  : cache!.memoryLimitBytes,
            );
            if (window != null) limit = min(limit, window.remainingBytes);
            if (limit <= 0) return;
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 5)
              ..maxConnectionsPerHost = 1;
            job.client = client;
            try {
              for (final url in [
                if (next.initialization != null) next.initialization!,
                next.url,
              ]) {
                if (_closed ||
                    job.cancelled ||
                    generation != _segmentPrefetchGeneration) {
                  return;
                }
                final resourceLimit = limit - job.bufferedBytes;
                if (resourceLimit <= 0) return;
                final request = await client
                    .getUrl(url)
                    .timeout(const Duration(seconds: 5));
                job.request = request;
                request.headers.set('x-rillight-prefetch', '1');
                request.headers.set('range', 'bytes=0-${resourceLimit - 1}');
                final deadline = Timer(
                  const Duration(seconds: 20),
                  request.abort,
                );
                try {
                  final response = await request.close().timeout(
                    const Duration(seconds: 20),
                  );
                  if (response.statusCode != 200 &&
                      response.statusCode != 206) {
                    if (const [
                      403,
                      409,
                      429,
                      503,
                    ].contains(response.statusCode)) {
                      _segmentPrefetchRefusal = response.statusCode;
                      _useSerialUpstream();
                      _cancelSegmentPrefetch(clearPending: true);
                    }
                    return;
                  }
                  final iterator = StreamIterator<List<int>>(response);
                  job.iterator = iterator;
                  var bytes = 0;
                  try {
                    while (bytes < resourceLimit &&
                        await iterator.moveNext().timeout(
                          const Duration(seconds: 15),
                        )) {
                      if (_closed ||
                          job.cancelled ||
                          generation != _segmentPrefetchGeneration) {
                        return;
                      }
                      bytes += iterator.current.length;
                      job.bufferedBytes += iterator.current.length;
                      job.progress.reset();
                      _segmentPrefetchDownloadedBytes +=
                          iterator.current.length;
                    }
                  } finally {
                    job.iterator = null;
                    await iterator.cancel();
                  }
                } finally {
                  deadline.cancel();
                  job.request = null;
                }
              }
              job.succeeded = true;
            } catch (_) {
              // Prefetch is optional; the foreground request uses normal recovery.
            } finally {
              client.close(force: true);
              job.client = null;
            }
          })().whenComplete(() {
            job.completed = true;
            if (identical(_segmentPrefetchJobs[owner], job)) {
              _segmentPrefetchJobs.remove(owner);
              if (job.succeeded &&
                  !job.cancelled &&
                  window != null &&
                  identical(_hlsPrefetchWindows[owner], window) &&
                  generation == _segmentPrefetchGeneration) {
                final route = _routes.open(next.url.pathSegments[1]);
                final rep = _representations[route?.identity];
                // Do not chain partial, uncacheable or stale unvalidated
                // segments: speculative bytes must be reusable by playback.
                if (route != null &&
                    rep != null &&
                    rep.complete &&
                    (rep.policy.fresh || rep.policy.strongEtag != null) &&
                    cache!.firstMissingOffset(
                          resource: route.identity,
                          generation: rep.generation,
                          offset: 0,
                          length: rep.total,
                        ) ==
                        null) {
                  window.remainingBytes -= job.bufferedBytes;
                  window.remainingSegments--;
                  final following = _hlsNext[route.identity];
                  if (following != null &&
                      window.remainingBytes > 0 &&
                      window.remainingSegments > 0) {
                    _queueSegmentPrefetch(following);
                  }
                }
              }
              _pumpSegmentPrefetch();
            }
          });
      job.task = task;
      unawaited(task);
    }
  }

  void cancelSubtitleReads() {
    for (final read in _reads.toList()) {
      if (_roles[read.resourceKey] == PlaybackResourceRole.subtitle &&
          !read.cancelled) {
        _cancelled++;
        read.cancel();
      }
    }
  }

  void _useSerialUpstream() {
    _serialUpstream = true;
    // Includes demuxer probes and subtitles, not only the read-ahead lanes.
    _client.maxConnectionsPerHost = 1;
  }

  Future<void> _retireBufferedResponses(_ProxyRead foreground) async {
    if (_responseReadAheads.isEmpty) return;
    // A single-stream origin needs the old response's lease released before
    // a demuxer seek/probe can start. These private buffers cannot be resumed
    // by splicing another unvalidated response into the old socket.
    final buffers = _responseReadAheads.toList();
    _responseReadAheads.clear();
    _bufferedResponse = null;
    await Future.wait(buffers.map((buffer) => buffer.close()));
    await Future.any([
      Future<void>.delayed(const Duration(milliseconds: 250)),
      foreground.cancelledFuture,
    ]);
    foreground.check();
  }

  Future<void> _classify(PlaybackCacheStream value) async {
    if (dynamicSource) value = PlaybackCacheStream.conservative;
    if (_stream == value) return;
    _stream = value;
    await onStreamChanged?.call(value);
  }

  bool _cacheableRequest(HttpRequest incoming, String key) =>
      cache != null &&
      incoming.method == 'GET' &&
      ![
        PlaybackResourceRole.key,
        PlaybackResourceRole.subtitle,
        PlaybackResourceRole.playlist,
      ].contains(_roles[key]) &&
      ![
        'if-range',
        'if-none-match',
        'if-modified-since',
      ].any((h) => incoming.headers.value(h) != null) &&
      (incoming.headers.value('range') == null ||
          RegExp(
            r'^bytes=(\d*)-(\d*)$',
          ).hasMatch(incoming.headers.value('range')!));

  void _invalidate(String key, _Representation representation) {
    if (_byteIdentity == '$key:${representation.generation}') {
      _clearByteCoverage();
    }
    if (_hlsDependencyKeys.contains(key)) {
      _cachedTimeline = const [];
      _hlsUnknownReason = 'hlsResourceChanged';
      _timelineSequence++;
    }
    if (_timelineResource == key || _readAhead?.resource == key) {
      _cachedTimeline = const [];
      _timelineIdentity = null;
      _timelineIndex = null;
      _mp4TimelineIndex = null;
      _mappingUnknownReason = null;
      _timelineSequence++;
    }
    if (_readAhead?.resource == key &&
        _readAhead?.generation == representation.generation) {
      unawaited(_readAhead!.close());
      _readAhead = null;
    }
    cache?.invalidate(key, generation: representation.generation);
    if (identical(_representations[key], representation)) {
      _representations.remove(key);
      if (_timelineResource == key) _timelineResource = null;
    }
  }

  void _store(
    String key,
    _Representation representation,
    int position,
    Uint8List bytes,
  ) {
    // put publishes its memory copy before yielding. Disk writes are bounded by
    // the storage queue; playback never waits on a disk timeout for each chunk.
    final write = cache!.put(
      resource: key,
      generation: representation.generation,
      offset: position,
      bytes: bytes,
    );
    _writes.add(write);
    unawaited(
      write.then(
        (_) {
          _writes.remove(write);
        },
        onError: (Object _) {
          _writes.remove(write);
        },
      ),
    );
  }

  Future<bool> _validate(
    HttpRequest incoming,
    String key,
    Uri url,
    _Representation representation,
    _ProxyRead read,
  ) async {
    if (representation.policy.fresh) return true;
    final etag = representation.policy.etag;
    final modified = representation.policy.lastModified;
    if (etag == null && modified == null) return false;
    Future<bool> validateRange() async {
      final (probe, effectiveProbe) = await _fetch(
        incoming,
        url,
        read: read,
        method: 'GET',
        overrides: {
          'range': 'bytes=0-0',
          'if-range': representation.policy.strongEtag,
          'if-none-match': null,
          'if-modified-since': null,
        },
      );
      final range = MediaContentRange.parse(
        probe.headers.value('content-range'),
      );
      final policy = MediaCachePolicy(
        probe.headers,
        allowSessionBuffering: sessionBuffering,
      );
      final valid =
          probe.statusCode == 206 &&
          range != null &&
          range.start == 0 &&
          range.end == 0 &&
          range.total == representation.total &&
          probe.contentLength == 1 &&
          (effectiveProbe == representation.effective || sessionBuffering) &&
          policy.storable &&
          policy.strongEtag == representation.policy.strongEtag &&
          probe.compressionState !=
              HttpClientResponseCompressionState.decompressed;
      if (valid) {
        await _discard(probe, read);
        representation.policy = policy;
        representation.effective = effectiveProbe;
      } else {
        for (final request in read.requests.toList()) {
          request.abort();
        }
        read.requests.clear();
      }
      return valid;
    }

    if (representation.headUnsupported &&
        representation.policy.strongEtag != null) {
      final valid = await validateRange();
      if (!valid) {
        _lastValidationFailure = 'rangeProbeFailed';
        _invalidate(key, representation);
      } else {
        _lastValidationFailure = null;
      }
      return valid;
    }
    final (response, effective) = await _fetch(
      incoming,
      url,
      read: read,
      method: 'HEAD',
      reportAuthentication: false,
      overrides: {
        'range': null,
        'if-range': null,
        'if-none-match': etag,
        'if-modified-since': etag == null ? modified : null,
      },
    );
    await _discard(response, read);
    final newPolicy = MediaCachePolicy(
      response.headers,
      allowSessionBuffering: sessionBuffering,
    );
    var valid =
        effective == representation.effective &&
        newPolicy.storable &&
        (response.statusCode == 304 &&
                (newPolicy.etag == null || newPolicy.etag == etag) ||
            response.statusCode == 200 &&
                etag != null &&
                newPolicy.strongEtag == representation.policy.strongEtag &&
                newPolicy.strongEtag != null &&
                response.contentLength == representation.total);
    var validatedPolicy = newPolicy;
    // Some Emby/CDN routes serve GET correctly but reject HEAD (including 502).
    // A failed HEAD is not evidence that cached video changed. Verify a tiny
    // conditional range instead; never drain an ignored Range's entire movie.
    if (!valid &&
        representation.policy.strongEtag != null &&
        (response.statusCode >= 500 ||
            response.statusCode == HttpStatus.forbidden ||
            response.statusCode == 405 ||
            (sessionBuffering && effective != representation.effective) ||
            (response.statusCode == 200 && newPolicy.strongEtag == null))) {
      valid = await validateRange();
      if (valid) {
        representation.headUnsupported =
            response.statusCode == HttpStatus.forbidden ||
            response.statusCode == HttpStatus.methodNotAllowed;
        validatedPolicy = representation.policy;
      }
    }
    if (!valid) {
      _lastValidationFailure =
          'status=${response.statusCode};length=${response.contentLength};'
          'sameRedirect=${effective == representation.effective};'
          'sameTag=${newPolicy.strongEtag == representation.policy.strongEtag};'
          'storable=${newPolicy.storable}';
      _invalidate(key, representation);
      return false;
    }
    if (response.headers['cache-control'] != null ||
        validatedPolicy != newPolicy) {
      representation.policy = validatedPolicy;
    }
    _lastValidationFailure = null;
    return true;
  }

  Future<Uint8List?> _loadGap(
    HttpRequest incoming,
    String key,
    Uri url,
    _Representation representation,
    int start,
    int end,
    _ProxyRead consumer,
  ) async {
    final identity = '$key:${representation.generation}:$start:$end';
    final load = _loads.putIfAbsent(identity, () {
      final producer = _ProxyRead(refusalParent: consumer)..resourceKey = key;
      final shared = _SharedLoad(producer);
      shared.future = (() async {
        var started = DateTime.now();
        // Keep validated bytes across broken connections. A lossy link must
        // not download the beginning of the same gap on every retry.
        final bytes = BytesBuilder(copy: false);
        for (var attempt = 0; attempt < 6; attempt++) {
          producer.check();
          Duration? retryAfter;
          var fastFailover = false;
          final cursor = start + bytes.length;
          try {
            final (response, effective) = await _fetchOnce(
              incoming,
              url,
              allowRange: true,
              read: producer,
              overrides: {
                'range': 'bytes=$cursor-$end',
                'if-range': representation.policy.strongEtag,
                'if-none-match': null,
                'if-modified-since': null,
              },
            );
            if (_retryableStatus(response.statusCode)) {
              retryAfter = _retryAfter(response.headers.value('retry-after'));
              fastFailover =
                  response.statusCode == 502 || response.statusCode == 504;
              await _retireRejectedResponse(response, producer);
              throw HttpException(
                'Temporary media status ${response.statusCode}',
              );
            }
            final range = MediaContentRange.parse(
              response.headers.value('content-range'),
            );
            final policy = MediaCachePolicy(
              response.headers,
              allowSessionBuffering: sessionBuffering,
            );
            if (response.statusCode != 206 ||
                range == null ||
                range.start != cursor ||
                range.end != end ||
                range.total != representation.total ||
                (!sessionBuffering && effective != representation.effective) ||
                policy.strongEtag != representation.policy.strongEtag ||
                !policy.storable ||
                response.contentLength != end - cursor + 1 ||
                response.compressionState ==
                    HttpClientResponseCompressionState.decompressed) {
              if (policy.strongEtag != null &&
                      policy.strongEtag != representation.policy.strongEtag ||
                  range != null && range.total != representation.total) {
                _invalidate(key, representation);
              }
              return null;
            }
            representation.policy = policy;
            final iterator = StreamIterator(response);
            producer.iterators.add(iterator);
            try {
              while (await _advance(iterator, producer)) {
                producer.check();
                _received(iterator.current.length);
                if (bytes.length + iterator.current.length > end - start + 1) {
                  throw const FormatException('Invalid range body');
                }
                bytes.add(iterator.current);
                if (iterator.current.isNotEmpty) {
                  if (attempt > 0) _recoveries++;
                  attempt = 0;
                  started = DateTime.now();
                }
              }
              producer.check();
              if (!identical(_representations[key], representation)) {
                return null;
              }
              if (bytes.length != end - start + 1) {
                throw const HttpException('Truncated range body');
              }
              final body = bytes.takeBytes();
              _store(key, representation, start, body);
              producer.check();
              return body;
            } finally {
              producer.iterators.remove(iterator);
              await iterator.cancel();
            }
          } on SocketException {
            if (producer.cancelled || attempt == 5) {
              if (!producer.cancelled) _recoveryFailures++;
              rethrow;
            }
          } on TimeoutException {
            if (producer.cancelled || attempt == 5) {
              if (!producer.cancelled) _recoveryFailures++;
              rethrow;
            }
          } on HttpException {
            if (producer.cancelled || attempt == 5) {
              if (!producer.cancelled) _recoveryFailures++;
              rethrow;
            }
          }
          for (final request in producer.requests.toList()) {
            request.abort();
          }
          producer.requests.clear();
          await _backoff(
            attempt,
            started,
            producer,
            retryAfter: retryAfter,
            fastFailover: fastFailover,
          );
          _recoveryAttempts++;
        }
        return null;
      })();
      return shared;
    });
    load.consumers++;
    // Cache-workspace admission bounds concurrent consumers, each working on
    // <=256 KiB, separately from the storage's pending budget. Include the copy.
    _charge((end - start + 1) * 2);
    try {
      final bytes = await Future.any([
        load.future,
        consumer.cancelledFuture.then<Uint8List?>((_) => null),
      ]);
      consumer.check();
      return bytes;
    } finally {
      _charge(-(end - start + 1) * 2);
      if (--load.consumers == 0) {
        _loads.remove(identity);
        load.producer.cancel();
      }
    }
  }

  bool _canReadAhead(
    HttpRequest incoming,
    String key,
    _Representation? rep, {
    bool allowSmallMediaRange = false,
  }) {
    final storage = cache;
    if (readAheadBytes <= 0 ||
        !_playbackActive ||
        storage == null ||
        rep == null ||
        _stream != PlaybackCacheStream.stable ||
        dynamicSource ||
        ![
          PlaybackResourceRole.media,
          PlaybackResourceRole.segment,
        ].contains(_roles[key]) ||
        !_cacheableRequest(incoming, key) ||
        _readAheadBypass.contains(key) ||
        (_readAhead?.resource == key && _readAhead!.failed) ||
        rep.policy.strongEtag == null ||
        !rep.rangeSupported ||
        storage.diskSessionLimitBytes < 2 * SessionReadAhead.blockBytes ||
        storage.diagnostics['diskLimitBytes'] == null ||
        storage.diagnostics['degradation'] != null) {
      return false;
    }
    final range = MediaByteRange.resolve(
      incoming.headers.value('range'),
      rep.total,
    );
    if (range == null) return false;
    if (range.length >= 1024 * 1024) return true;
    // Native readers may request one AVIO-sized slice at a time. Once the
    // representation is known, stream these slices from the same bounded
    // producer instead of paying a new HTTP round trip per 64 KiB. Keep tiny
    // metadata probes and the EOF index suffix on the foreground cache path.
    // A short initial response cannot seed a larger producer range.
    return allowSmallMediaRange &&
        sessionBuffering &&
        _roles[key] == PlaybackResourceRole.media &&
        range.length >= 64 * 1024 &&
        range.start < rep.total - 64 * 1024;
  }

  Future<bool> _tryReadAhead(
    HttpRequest incoming,
    String key,
    Uri url,
    _ProxyRead read, {
    bool validated = false,
    _ReadAheadSeed? seed,
  }) async {
    final rep = _representations[key];
    if (rep == null ||
        !_canReadAhead(
          incoming,
          key,
          rep,
          allowSmallMediaRange: seed == null,
        )) {
      return false;
    }
    if (_readAhead?.resource == key && _readAhead!.failed) return false;
    // A VOD representation already tied to this private playback session has
    // a strong validator. Its cached blocks need no extra HEAD/GET probe on
    // each seek; each newly fetched gap still checks that validator.
    if (!validated &&
        !(sessionBuffering &&
            !dynamicSource &&
            rep.policy.strongEtag != null) &&
        !await _validate(incoming, key, url, rep, read)) {
      return false;
    }
    read.check();
    if (!_reserveCacheWorkspace(512 * 1024)) return false;
    _charge(512 * 1024);
    try {
      var ahead = _readAhead;
      if (ahead == null ||
          ahead.resource != key ||
          ahead.generation != rep.generation) {
        await ahead?.close();
        if (readAheadConcurrency == 1) _client.maxConnectionsPerHost = 1;
        _timelineIdentity = null;
        _timelineIndex = null;
        _mp4TimelineIndex = null;
        _cachedTimeline = const [];
        _timelineSequence++;
        ahead = SessionReadAhead(
          cache: cache!,
          resource: key,
          generation: rep.generation,
          total: rep.total,
          aheadBytes: readAheadBytes,
          continuousTransfers: continuousTransfers,
          maxConcurrentTransfers: _serialUpstream ? 1 : readAheadConcurrency,
          reserveWorkspace: () {
            final bytes = ahead!.workspaceBytes;
            if (!_reserveCacheWorkspace(bytes)) {
              return false;
            }
            _charge(bytes);
            return true;
          },
          releaseWorkspace: () {
            final bytes = ahead!.workspaceBytes;
            _charge(-bytes);
            _releaseCacheWorkspace(bytes);
          },
          fetch: (start, end) async {
            final producer = _ProxyRead()
              ..resourceKey = key
              ..readAheadProducer = true;
            Stream<List<int>> source() async* {
              var cursor = start;
              var started = DateTime.now();
              try {
                for (var attempt = 0; cursor <= end && attempt < 6; attempt++) {
                  producer.check();
                  try {
                    // The first response already paid for connection setup,
                    // redirects and sniffing. Transfer its ownership to this
                    // bounded producer instead of requesting byte zero again.
                    final adopted = seed?.take(start, end, producer);
                    final (response, effective) = adopted != null
                        ? (adopted.response, adopted.effective)
                        : await _fetchOnce(
                            incoming,
                            url,
                            allowRange: true,
                            read: producer,
                            method: 'GET',
                            reportAuthentication: false,
                            overrides: {
                              'range': 'bytes=$cursor-$end',
                              'if-range': rep.policy.strongEtag,
                              'if-none-match': null,
                              'if-modified-since': null,
                            },
                          );
                    if (ahead?.hasParallelTransfers == true &&
                        const [
                          200,
                          403,
                          409,
                          429,
                          503,
                        ].contains(response.statusCode)) {
                      await _retireRejectedResponse(response, producer);
                      for (final request in producer.requests.toList()) {
                        request.abort();
                      }
                      producer.requests.clear();
                      final retryAfter = _retryAfter(
                        response.headers.value('retry-after'),
                      );
                      if (retryAfter != null) {
                        await _backoff(
                          0,
                          DateTime.now(),
                          producer,
                          retryAfter: retryAfter,
                        );
                      }
                      _recoveryAttempts++;
                      _useSerialUpstream();
                      throw ReadAheadConcurrencyRejected(
                        'http-${response.statusCode}',
                      );
                    }
                    if (response.statusCode == HttpStatus.unauthorized ||
                        response.statusCode == HttpStatus.forbidden) {
                      _prefetchAuthenticationStatus = response.statusCode;
                      // A future range can be temporarily rate-limited even
                      // while current media is valid. Retry optional prefetch
                      // with bounded backoff; actual foreground demand still
                      // receives the authentication failure immediately.
                      if (response.statusCode == HttpStatus.forbidden &&
                          ahead?.diagnostics['readAheadReaderWaiting'] !=
                              true &&
                          attempt < 5) {
                        for (final request in producer.requests.toList()) {
                          request.abort();
                        }
                        producer.requests.clear();
                        await _backoff(
                          attempt,
                          started,
                          producer,
                          retryAfter: _retryAfter(
                            response.headers.value('retry-after'),
                          ),
                        );
                        _recoveryAttempts++;
                        continue;
                      }
                      // An optional future range may be rejected while the
                      // player is still consuming valid cached bytes. Preserve
                      // those bytes and surface authentication only on demand.
                      throw _ReadAheadAuthenticationFailure(
                        response.statusCode,
                      );
                    }
                    final range = MediaContentRange.parse(
                      response.headers.value('content-range'),
                    );
                    final policy = MediaCachePolicy(
                      response.headers,
                      allowSessionBuffering: sessionBuffering,
                    );
                    if (_retryableStatus(response.statusCode)) {
                      if (attempt == 5) {
                        _recoveryFailures++;
                        throw const _MediaRecoveryExhausted();
                      }
                      await _retireRejectedResponse(response, producer);
                      for (final request in producer.requests.toList()) {
                        request.abort();
                      }
                      producer.requests.clear();
                      await _backoff(
                        attempt,
                        started,
                        producer,
                        retryAfter: _retryAfter(
                          response.headers.value('retry-after'),
                        ),
                        fastFailover:
                            response.statusCode == 502 ||
                            response.statusCode == 504,
                      );
                      _recoveryAttempts++;
                      continue;
                    }
                    if (_representations[key]?.generation != rep.generation ||
                        response.statusCode != 206 ||
                        range == null ||
                        range.start != cursor ||
                        (adopted == null
                            ? range.end != end
                            : range.end < end) ||
                        range.total != rep.total ||
                        (!sessionBuffering && effective != rep.effective) ||
                        !policy.storable ||
                        policy.strongEtag != rep.policy.strongEtag ||
                        response.contentLength != range.end - cursor + 1 ||
                        response.compressionState ==
                            HttpClientResponseCompressionState.decompressed) {
                      if (policy.strongEtag != null &&
                              policy.strongEtag != rep.policy.strongEtag ||
                          range != null && range.total != rep.total) {
                        _invalidate(key, rep);
                      }
                      throw const FormatException(
                        'Read-ahead representation changed',
                      );
                    }
                    rep.policy = policy;
                    _prefetchAuthenticationStatus = null;
                    final iterator =
                        adopted?.chunks ?? StreamIterator<List<int>>(response);
                    producer.iterators.add(iterator);
                    try {
                      List<int>? prefix = adopted?.prefix;
                      while (cursor <= end &&
                          (prefix != null ||
                              await _advance(iterator, producer))) {
                        final fromPrefix = prefix != null;
                        final chunk = prefix ?? iterator.current;
                        prefix = null;
                        // The original open-ended response may exceed the
                        // scheduler's 32 MiB window. Never grow that window.
                        final bytes =
                            adopted != null && chunk.length > end + 1 - cursor
                            ? chunk.sublist(0, end + 1 - cursor)
                            : chunk;
                        producer.check();
                        if (_representations[key]?.generation !=
                                rep.generation ||
                            cursor + bytes.length > end + 1) {
                          throw const FormatException(
                            'Read-ahead representation changed',
                          );
                        }
                        if (!fromPrefix) _received(chunk.length);
                        cursor += bytes.length;
                        if (bytes.isNotEmpty) {
                          // Bound consecutive failures, not a healthy transfer's
                          // age or lifetime reconnect count. Slow, lossy links
                          // can need many validated suffixes for a 32 MiB range.
                          if (attempt > 0) _recoveries++;
                          attempt = 0;
                          started = DateTime.now();
                        }
                        yield bytes;
                      }
                    } finally {
                      producer.iterators.remove(iterator);
                      await iterator.cancel();
                    }
                    if (cursor <= end) {
                      throw const HttpException('Truncated prefetch range');
                    }
                  } on FormatException {
                    rethrow;
                  } on SocketException {
                    if (cursor == start &&
                        attempt > 0 &&
                        ahead?.hasParallelTransfers == true) {
                      _useSerialUpstream();
                      throw const ReadAheadConcurrencyRejected(
                        'connection-refused',
                      );
                    }
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    producer.requests.clear();
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  } on TimeoutException {
                    if (cursor == start &&
                        attempt > 0 &&
                        ahead?.hasParallelTransfers == true) {
                      _useSerialUpstream();
                      throw const ReadAheadConcurrencyRejected(
                        'connection-stalled',
                      );
                    }
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    producer.requests.clear();
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  } on HttpException {
                    if (cursor == start &&
                        attempt > 0 &&
                        ahead?.hasParallelTransfers == true) {
                      _useSerialUpstream();
                      throw const ReadAheadConcurrencyRejected(
                        'connection-interrupted',
                      );
                    }
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    producer.requests.clear();
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  }
                }
                if (cursor <= end) {
                  throw const HttpException('Read-ahead recovery exhausted');
                }
              } catch (error) {
                if (!producer.cancelled &&
                    (error is _MediaRecoveryExhausted ||
                        error is SocketException ||
                        error is TimeoutException ||
                        error is HttpException)) {
                  throw const ReadAheadRetryLater();
                }
                if (!producer.cancelled &&
                    error is! ReadAheadConcurrencyRejected) {
                  _readAheadBypassReason = 'producer:${error.runtimeType}';
                  _readAheadBypass.add(key);
                }
                rethrow;
              } finally {
                producer.cancel();
              }
            }

            return ReadAheadTransfer(source(), producer.cancel);
          },
        );
        ahead.setPrefetchAllowed(_playbackActive);
        _readAhead = ahead;
      } else {
        // An existing scheduler's fetch closure cannot adopt this response.
        // Release it before that scheduler needs the single connection pool.
        seed?.cancelUnused();
      }
      final range = MediaByteRange.resolve(
        incoming.headers.value('range'),
        rep.total,
      )!;
      final output = incoming.response;
      output.statusCode = incoming.headers.value('range') == null ? 200 : 206;
      for (final entry in rep.headers.entries) {
        output.headers.set(entry.key, entry.value);
      }
      output.headers.set('accept-ranges', 'bytes');
      if (output.statusCode == 206) {
        output.headers.set(
          'content-range',
          'bytes ${range.start}-${range.end}/${rep.total}',
        );
      }
      output.contentLength = range.length;
      Stream<List<int>> body() async* {
        try {
          await for (final bytes in ahead!.read(
            range.start,
            range.end,
            cancelled: read.cancelledFuture,
          )) {
            read.check();
            read.outputStarted = true;
            yield bytes;
          }
        } on _ReadAheadAuthenticationFailure catch (failure) {
          _authenticationStatus = failure.status;
          rethrow;
        }
      }

      try {
        return await _sendBody(output, body());
      } on ReadAheadSuperseded {
        // A demuxer has moved to another track/range. Retire its old request,
        // without disabling prefetch for every subsequent read of this movie.
        read.cancel();
        rethrow;
      } catch (error) {
        if (!read.outputStarted && !read.cancelled) {
          if (error is TimeoutException && !ahead.failed) {
            // A foreground deadline is not evidence that this representation
            // is incompatible with read-ahead. Keep recovery available on seek.
            return false;
          }
          _readAheadBypassReason = 'consumer:${error.runtimeType}';
          _readAheadBypass.add(key);
          return false;
        }
        rethrow;
      }
    } finally {
      _charge(-512 * 1024);
      _releaseCacheWorkspace(512 * 1024);
    }
  }

  void _discardBufferedResponse() {
    final previous = _bufferedResponse;
    _bufferedResponse = null;
    _responseByteRanges = const [];
    _responseByteIdentity = null;
    if (previous != null) {
      _responseReadAheads.remove(previous.buffer);
      unawaited(previous.buffer.close());
    }
  }

  Future<bool> _tryBufferedResponse(
    HttpRequest incoming,
    String key,
    _ProxyRead read,
  ) async {
    final buffered = _bufferedResponse;
    if (buffered == null ||
        buffered.key != key ||
        !_cacheableRequest(incoming, key) ||
        dynamicSource ||
        _cacheReadsUncertain) {
      return false;
    }
    final representation = buffered.representation;
    final header = incoming.headers.value('range');
    final requested = MediaByteRange.resolve(header, representation.total);
    if (requested == null ||
        requested.start < representation.responseStart ||
        requested.start > representation.responseEnd) {
      return false;
    }
    final start = requested.start - representation.responseStart;
    final end =
        min(requested.end, representation.responseEnd) -
        representation.responseStart;
    final missing = cache!.firstMissingOffset(
      resource: buffered.buffer.resource,
      generation: 0,
      offset: start,
      length: end - start + 1,
    );
    final cachedEnd = (missing ?? end + 1) - 1;
    if (cachedEnd < start) return false;
    if (buffered.buffer.canContinue &&
        (header != null ||
            representation.responseStart == 0 &&
                representation.responseEnd == representation.total - 1)) {
      // Keep downloading on the original response after a cached seek. The
      // scheduler follows the new consumer and its bounded forward window.
      // No additional upstream request or unvalidated range splice is needed.
      Stream<List<int>> body() async* {
        await for (final bytes in buffered.buffer.readRange(start, end)) {
          read.check();
          if (!read.outputStarted) {
            final output = incoming.response;
            output.statusCode = header == null ? 200 : 206;
            for (final entry in representation.headers.entries) {
              output.headers.set(entry.key, entry.value);
            }
            output.headers.set('accept-ranges', 'bytes');
            if (header != null) {
              output.headers.set(
                'content-range',
                'bytes ${requested.start}-${end + representation.responseStart}/${representation.total}',
              );
            }
            output.contentLength = end - start + 1;
          }
          read.outputStarted = true;
          yield bytes;
        }
      }

      return await _sendBody(incoming.response, body());
    }
    // Never append a different unvalidated origin response. Return just this
    // immutable extent as a bounded 206; the demuxer's next range may fetch the
    // missing suffix. A request without Range still requires the entire file.
    if (header == null &&
        (requested.start != 0 ||
            cachedEnd + representation.responseStart !=
                representation.total - 1)) {
      return false;
    }
    if (!_reserveCacheWorkspace(_cachedResponseWorkspace)) return false;
    CacheRangeLease? lease;
    try {
      lease = await cache!.protectRange(
        resource: buffered.buffer.resource,
        generation: 0,
        offset: start,
        length: cachedEnd - start + 1,
      );
      read.check();
      if (lease == null) return false;
      final snapshot = lease;
      Stream<List<int>> body() async* {
        var position = start;
        while (position <= cachedEnd) {
          final hit = await snapshot.read(
            position,
            maxLength: min(64 * 1024, cachedEnd - position + 1),
          );
          read.check();
          if (hit == null || hit.bytes.isEmpty) {
            if (!read.outputStarted) return;
            throw const HttpException('Buffered media data unavailable');
          }
          if (!read.outputStarted) {
            final output = incoming.response;
            output.statusCode = header == null ? 200 : 206;
            for (final entry in representation.headers.entries) {
              output.headers.set(entry.key, entry.value);
            }
            output.headers.set('accept-ranges', 'bytes');
            if (header != null) {
              output.headers.set(
                'content-range',
                'bytes ${requested.start}-${cachedEnd + representation.responseStart}/${representation.total}',
              );
            }
            output.contentLength = cachedEnd - start + 1;
          }
          read.outputStarted = true;
          yield hit.bytes;
          position += hit.bytes.length;
        }
      }

      return await _sendBody(incoming.response, body());
    } finally {
      await lease?.close();
      _releaseCacheWorkspace(_cachedResponseWorkspace);
    }
  }

  Future<bool> _tryCached(
    HttpRequest incoming,
    String key,
    Uri url,
    _ProxyRead read,
  ) async {
    if (!_cacheableRequest(incoming, key)) return false;
    final representation = _representations[key];
    if (representation == null || !representation.complete) return false;
    if (!(sessionBuffering &&
            !dynamicSource &&
            representation.policy.strongEtag != null) &&
        !await _validate(incoming, key, url, representation, read)) {
      return false;
    }
    final rangeValue = incoming.headers.value('range');
    final resolvedRange = MediaByteRange.resolve(
      rangeValue,
      representation.total,
    );
    if (resolvedRange == null) {
      if (!MediaByteRange.beyondEnd(rangeValue, representation.total)) {
        return false;
      }
      incoming.response.statusCode = 416;
      incoming.response.headers.set(
        'content-range',
        'bytes */${representation.total}',
      );
      incoming.response.contentLength = 0;
      return true;
    }
    MediaByteRange range = resolvedRange;
    // Opening the decoder temporarily disables optional read-ahead. Do not
    // bind a movie-sized response to the small-gap startup path: that response
    // can outlive open() and keep issuing 1 MiB HTTP requests for the whole film.
    // A bounded 206 lets the decoder continue through the read-ahead scheduler
    // on its next request once playback becomes active.
    if (sessionBuffering &&
        !dynamicSource &&
        !_playbackActive &&
        rangeValue != null &&
        range.length > _cachedResponseWorkspace) {
      range = MediaByteRange(
        range.start,
        range.start + _cachedResponseWorkspace - 1,
      );
    }
    if (representation.policy.strongEtag == null &&
        (range.start < representation.responseStart ||
            range.end > representation.responseEnd)) {
      return false;
    }
    if (representation.policy.strongEtag == null) {
      // Acquire a complete snapshot before sending any bytes. Existing blocks
      // stay within their budgets and cannot be evicted during this response.
      final lease = await cache!.protectRange(
        resource: key,
        generation: representation.generation,
        offset: range.start,
        length: range.length,
      );
      if (lease == null) return false;
      _charge(64 * 1024);
      try {
        Stream<List<int>> body() async* {
          var position = range.start;
          while (position <= range.end) {
            final hit = await lease.read(
              position,
              maxLength: min(64 * 1024, range.end - position + 1),
            );
            read.check();
            if (hit == null) {
              if (!read.outputStarted) return;
              throw const HttpException('Protected media data unavailable');
            }
            if (hit.bytes.isEmpty) {
              throw const HttpException(
                'Protected media read made no progress',
              );
            }
            if (!read.outputStarted) {
              incoming.response.statusCode = rangeValue == null ? 200 : 206;
              for (final header in representation.headers.entries) {
                incoming.response.headers.set(header.key, header.value);
              }
              incoming.response.headers.set('accept-ranges', 'bytes');
              if (rangeValue != null) {
                incoming.response.headers.set(
                  'content-range',
                  'bytes ${range.start}-${range.end}/${representation.total}',
                );
              }
              incoming.response.contentLength = range.length;
            }
            read.outputStarted = true;
            yield hit.bytes;
            position += hit.bytes.length;
          }
        }

        return await _sendBody(incoming.response, body());
      } finally {
        _charge(-64 * 1024);
        await lease.close();
      }
    }
    // A large decoder range may start in a fully validated cached extent.
    // Return that extent as a bounded 206 instead of fetching a distant gap
    // before delivering its first byte. FFmpeg continues at Content-Range's
    // end when it actually needs more. Separate responses retain validators.
    if (sessionBuffering &&
        !dynamicSource &&
        rangeValue != null &&
        range.length >= 256 * 1024) {
      final firstMissing = cache!.firstMissingOffset(
        resource: key,
        generation: representation.generation,
        offset: range.start,
        length: range.length,
      );
      if (firstMissing != null && firstMissing - range.start >= 64 * 1024) {
        range = MediaByteRange(range.start, firstMissing - 1);
      }
    }
    var position = range.start;
    var sent = false;
    final missing = cache!.firstMissingOffset(
      resource: key,
      generation: representation.generation,
      offset: range.start,
      length: range.length,
    );
    Future<bool> hasAny() => cache!.hasAny(
      resource: key,
      generation: representation.generation,
      offset: range.start,
      length: range.length,
    );
    if (range.length > 256 * 1024 &&
        missing == range.start &&
        !await hasAny()) {
      return false;
    }
    Uint8List? prefetched;
    if (missing != null) {
      if (representation.policy.strongEtag == null) return false;
      final next = cache!.nextOffset(
        resource: key,
        generation: representation.generation,
        after: missing,
      );
      final end = min(
        missing + 256 * 1024 - 1,
        min(range.end, (next ?? range.end + 1) - 1),
      );
      // MKV often places Tags and Cues in adjacent tiny ranges at EOF.
      // Read that bounded suffix once instead of paying a round trip per
      // element. Only validated, session-owned media can reuse these bytes.
      final tailProbe =
          sessionBuffering &&
          !dynamicSource &&
          readAheadBytes > 0 &&
          _roles[key] == PlaybackResourceRole.media &&
          representation.total > 1024 * 1024 &&
          range.length <= 16 * 1024 &&
          range.start >= representation.total - 64 * 1024;
      final fetchStart = tailProbe ? representation.total - 64 * 1024 : missing;
      final fetchEnd = tailProbe ? representation.total - 1 : end;
      // Check the first known gap's validator before committing cached prefixes.
      // A later representation change aborts the incomplete HTTP response.
      prefetched = await _loadGap(
        incoming,
        key,
        url,
        representation,
        fetchStart,
        fetchEnd,
        read,
      );
      if (prefetched == null) return false;
      if (tailProbe) {
        prefetched = Uint8List.fromList(
          Uint8List.sublistView(
            prefetched,
            missing - fetchStart,
            end - fetchStart + 1,
          ),
        );
      }
    }
    final prefetchedLength = prefetched?.length ?? 0;
    _charge(prefetchedLength);
    try {
      Stream<List<int>> body() async* {
        var firstGapLoaded = prefetched != null;
        while (position <= range.end) {
          read.check();
          // The first missing piece stays small for a quick seek response.
          // Once that piece is available, coalesce subsequent gaps to the
          // reserved 1 MiB workspace instead of issuing 256 KiB HTTP ranges.
          final length = min(
            firstGapLoaded ? _cachedResponseWorkspace : 256 * 1024,
            range.end - position + 1,
          );
          _charge(length);
          try {
            final hit = position == missing
                ? null
                : await cache!.read(
                    resource: key,
                    generation: representation.generation,
                    offset: position,
                    maxLength: length,
                  );
            read.check();
            var bytes = position == missing ? prefetched : hit?.bytes;
            if (bytes == null) {
              if (range.length > 256 * 1024 &&
                  !sent &&
                  prefetched == null &&
                  !await hasAny()) {
                return;
              }
              if (representation.policy.strongEtag == null) {
                if (!sent) return;
                throw const HttpException('Cached range was evicted');
              }
              final next = cache!.nextOffset(
                resource: key,
                generation: representation.generation,
                after: position,
              );
              final end = min(
                position + length - 1,
                next == null ? range.end : next - 1,
              );
              bytes = await _loadGap(
                incoming,
                key,
                url,
                representation,
                position,
                end,
                read,
              );
              if (bytes == null) {
                if (!sent) return;
                throw const HttpException('Media representation changed');
              }
              firstGapLoaded = true;
            }
            if (bytes.isEmpty) {
              throw const HttpException('Cached media read made no progress');
            }
            if (!sent) {
              incoming.response.statusCode = rangeValue == null ? 200 : 206;
              for (final entry in representation.headers.entries) {
                incoming.response.headers.set(entry.key, entry.value);
              }
              incoming.response.headers.set('accept-ranges', 'bytes');
              if (rangeValue != null) {
                incoming.response.headers.set(
                  'content-range',
                  'bytes ${range.start}-${range.end}/${representation.total}',
                );
              }
              incoming.response.contentLength = range.length;
            }
            read.outputStarted = true;
            yield bytes;
            sent = true;
            position += bytes.length;
          } finally {
            _charge(-length);
          }
        }
      }

      return await _sendBody(incoming.response, body());
    } finally {
      _charge(-prefetchedLength);
    }
  }

  // Own the producer iterator until downstream cancellation has completed.
  // HttpResponse.addStream can otherwise leave an async* producer's late body
  // failure unobserved when a demuxer closes its probe or seeks to another range.
  Future<bool> _sendBody(HttpResponse output, Stream<List<int>> body) async {
    final chunks = StreamIterator(body);
    try {
      if (!await chunks.moveNext()) return false;
      // Media readers need the first packet even when the origin pauses before
      // its next one. HttpResponse's small-write buffer otherwise holds it.
      // addStream still provides socket backpressure; cache blocks remain large.
      output.bufferOutput = false;
      Stream<List<int>> remaining() async* {
        do {
          yield chunks.current;
        } while (await chunks.moveNext());
      }

      await output.addStream(remaining());
      return true;
    } finally {
      await chunks.cancel();
    }
  }

  void _retireSupersededNativeRead(HttpRequest incoming, _ProxyRead read) {
    if (incoming.method != 'GET') return;
    final inputId = incoming.headers.value('x-rillight-input-id');
    if (inputId == null || !RegExp(r'^\d{1,20}$').hasMatch(inputId)) return;
    final prefix = '/$_secret/';
    if (!incoming.uri.path.startsWith(prefix)) return;
    final token = incoming.uri.path.substring(prefix.length).split('/').first;
    final route = _closed ? null : _routes.open(token);
    if (route == null || route.role != PlaybackResourceRole.media.index) return;
    read.resourceKey = route.identity;
    read.localInputId = inputId;
    // A native ownership slot closes its old response before replacement;
    // Android uses separate slots for retained interleaved track responses. A
    // stalled downstream body may not observe that TCP close until more bytes
    // arrive. Retire it before checking capacity, including bounded ranges.
    for (final previous in _reads) {
      if (!identical(previous, read) &&
          previous.resourceKey == route.identity &&
          previous.localInputId == inputId) {
        previous.cancel();
      }
    }
  }

  Future<void> _serve(HttpRequest incoming) async {
    final read = _ProxyRead(seekGeneration: _seekGeneration);
    _reads.add(read);
    unawaited(
      incoming.response.done.then(
        (_) => read.cancel(),
        onError: (Object _) {
          read.cancel();
        },
      ),
    );
    var acquired = false;
    var served = false;
    try {
      _retireSupersededNativeRead(incoming, read);
      final prefetch = incoming.headers.value('x-rillight-prefetch') == '1';
      if (!prefetch) {
        _SegmentPrefetchJob? matching;
        for (final job in _segmentPrefetchJobs.values) {
          if (!job.cancelled &&
              (incoming.uri.path == job.next.url.path ||
                  incoming.uri.path == job.next.initialization?.path)) {
            matching = job;
            break;
          }
        }
        if (matching != null) {
          _segmentPrefetchHandoffs++;
          // A healthy high-latency request must not be discarded after 100 ms
          // only to pay the same connection/header latency again. Allow a
          // bounded header grace, extending while bytes actually arrive.
          final handoff = Stopwatch()..start();
          do {
            await Future.any<void>([
              matching.task,
              read.cancelledFuture,
              Future<void>.delayed(const Duration(milliseconds: 100)),
            ]);
            read.check();
          } while (!matching.completed &&
              handoff.elapsedMilliseconds < 2000 &&
              (handoff.elapsedMilliseconds < 500 ||
                  (matching.bufferedBytes > 0 &&
                      matching.progress.elapsedMilliseconds < 250)));
          read.check();
          if (!matching.completed) {
            _segmentPrefetchPreemptions++;
            _cancelSegmentPrefetch(owner: matching.next.owner, requeue: false);
          }
        } else if (_active >= _maxRequests - 2) {
          _SegmentPrefetchJob? victim;
          for (final job in _segmentPrefetchJobs.values) {
            if (!job.cancelled) {
              victim = job;
              break;
            }
          }
          if (victim != null) {
            _segmentPrefetchPreemptions++;
            _cancelSegmentPrefetch(owner: victim.next.owner, requeue: true);
          }
        }
        if (_active >= _maxRequests &&
            (_activeSegmentPrefetchRequests > 0 ||
                _segmentPrefetchJobs.values.any((job) => job.cancelled))) {
          final deadline = DateTime.now().add(
            const Duration(milliseconds: 100),
          );
          while (_active >= _maxRequests && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            read.check();
          }
        }
      }
      final requestLimit = prefetch ? _maxRequests - 2 : _maxRequests;
      if (!prefetch && _active >= requestLimit && _reads.length <= 32) {
        // Cached MP4 track seeks can arrive faster than TCP close callbacks
        // retire the previous responses. Yield boundedly for a released slot
        // instead of turning that normal burst into a fatal local HTTP 503.
        _admissionWaits++;
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (_active >= requestLimit) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) break;
          try {
            await Future.any([
              _requestReleased.future,
              read.cancelledFuture,
            ]).timeout(remaining);
          } on TimeoutException {
            break;
          }
          read.check();
        }
      }
      if (_active >= requestLimit) {
        _admissionRejected++;
        incoming.response.statusCode = HttpStatus.serviceUnavailable;
        await incoming.response.close();
        return;
      }
      _active++;
      if (prefetch) _activeSegmentPrefetchRequests++;
      acquired = true;
      await _serveResponse(incoming, read);
      served = true;
    } catch (_) {
      try {
        await incoming.response.close();
      } catch (_) {}
    } finally {
      final key = read.resourceKey;
      _reads.remove(read);
      read.cancel();
      if (acquired) {
        _active--;
        final released = _requestReleased;
        _requestReleased = Completer<void>();
        released.complete();
        if (incoming.headers.value('x-rillight-prefetch') == '1') {
          _activeSegmentPrefetchRequests--;
        }
      }
      if (served &&
          key != null &&
          incoming.method == 'GET' &&
          read.outputStarted &&
          incoming.headers.value('x-rillight-prefetch') != '1' &&
          read.seekGeneration == _seekGeneration &&
          _roles[key] == PlaybackResourceRole.segment &&
          incoming.response.statusCode >= 200 &&
          incoming.response.statusCode < 300) {
        final owner = _hlsSegmentOwners[key];
        if (owner != null) _hlsActiveOwners.add(owner);
        if (!read.segmentPrefetchScheduled) _scheduleSegmentPrefetch(key);
      }
      _pumpSegmentPrefetch();
    }
  }

  Future<void> _servePrivateSubtitle(
    HttpRequest incoming,
    _ProxyRead read,
    String registeredPath,
  ) async {
    final output = incoming.response;
    if (_closed || !['GET', 'HEAD'].contains(incoming.method)) {
      output.statusCode = HttpStatus.notFound;
      return;
    }
    // Recheck after registration so replacing a temporary file with a link
    // cannot turn a sealed subtitle route into an arbitrary file read.
    final resolved = _validatedPrivateSubtitle(File(registeredPath).uri);
    if (Platform.isWindows
        ? resolved.toLowerCase() != registeredPath.toLowerCase()
        : resolved != registeredPath) {
      output.statusCode = HttpStatus.notFound;
      return;
    }
    final file = File(resolved);
    final length = await file.length();
    var start = 0;
    var end = length - 1;
    final header = incoming.headers.value(HttpHeaders.rangeHeader);
    if (header != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header);
      if (match == null) {
        output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        output.headers.set('content-range', 'bytes */$length');
        return;
      }
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = int.parse(match[2]!);
      if (start >= length || start > end) {
        output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        output.headers.set('content-range', 'bytes */$length');
        return;
      }
      end = min(end, length - 1);
      output.statusCode = HttpStatus.partialContent;
      output.headers.set('content-range', 'bytes $start-$end/$length');
    }
    output.headers.set('accept-ranges', 'bytes');
    output.headers.contentType = ContentType.text;
    output.contentLength = max(0, end - start + 1);
    if (incoming.method == 'HEAD' || length == 0) return;
    await for (final chunk in file.openRead(start, end + 1)) {
      read.check();
      output.add(chunk);
      read.outputStarted = true;
      await output.flush();
    }
  }

  Future<void> _serveResponse(
    HttpRequest incoming,
    _ProxyRead read, {
    bool allowRange = true,
  }) async {
    final output = incoming.response;
    var responseDetached = false;
    try {
      final prefix = '/$_secret/';
      final token = incoming.uri.path.startsWith(prefix)
          ? incoming.uri.path.substring(prefix.length).split('/').first
          : '';
      final privatePath = _privateSubtitles[token];
      if (privatePath != null) {
        read.resourceKey = token;
        await _servePrivateSubtitle(incoming, read, privatePath);
        return;
      }
      final route = _closed ? null : _routes.open(token);
      if (route == null ||
          route.role < 0 ||
          route.role >= PlaybackResourceRole.values.length ||
          !['GET', 'HEAD'].contains(incoming.method)) {
        output.statusCode = HttpStatus.notFound;
        return;
      }
      final key = route.identity;
      final url = _refreshedUrls[key] ?? route.url;
      read.resourceKey = key;
      if (!_roles.containsKey(key)) {
        while (_roles.length >= 256) {
          final oldest = _roles.keys.firstWhere(
            (candidate) => !_reads.any((r) => r.resourceKey == candidate),
          );
          _roles.remove(oldest);
          _readAheadBypass.remove(oldest);
          final previous = _representations[oldest];
          if (previous != null) {
            _invalidate(oldest, previous);
          }
        }
        _roles[key] = PlaybackResourceRole.values[route.role];
      }
      if (allowRange && await _tryBufferedResponse(incoming, key, read)) return;
      if (await _serveWarmPrefix(incoming, key, url, read)) return;
      if (allowRange && await _tryReadAhead(incoming, key, url, read)) return;
      if (allowRange &&
          cache != null &&
          _reserveCacheWorkspace(_cachedResponseWorkspace)) {
        try {
          if (await _tryCached(incoming, key, url, read)) return;
        } finally {
          _releaseCacheWorkspace(_cachedResponseWorkspace);
        }
      }
      final startupRange =
          sessionBuffering &&
              !dynamicSource &&
              !_playbackActive &&
              incoming.method == 'GET' &&
              _roles[key] == PlaybackResourceRole.media
          ? RegExp(
              r'^bytes=(\d+)-(\d*)$',
            ).firstMatch(incoming.headers.value('range') ?? '')
          : null;
      final startupStart = int.tryParse(startupRange?[1] ?? '');
      final startupEnd = int.tryParse(startupRange?[2] ?? '');
      // The very first uncached response also starts while open() has paused
      // prefetch. Bound it at the origin, so its socket cannot stay coupled to
      // decoder backpressure for the entire movie after play() is called.
      final startupOverrides = <String, String?>{};
      if (startupStart != null &&
          (startupEnd == null ||
              startupEnd - startupStart + 1 > _cachedResponseWorkspace)) {
        startupOverrides['range'] =
            'bytes=$startupStart-${startupStart + _cachedResponseWorkspace - 1}';
      }
      var (response, effective) = await _fetch(
        incoming,
        url,
        allowRange: allowRange,
        read: read,
        overrides: startupOverrides,
      );
      // Start HTTP/TLS while the disk coordinator inventories old sessions.
      // Storage must be ready before we admit/publish media, but it need not
      // delay sending the first request to a high-latency origin.
      if (_cacheReady != null) {
        await Future.any([_cacheReady!, read.cancelledFuture]);
        read.check();
      }
      void copyResponseHeaders(HttpClientResponse source) {
        output.statusCode = source.statusCode;
        for (final name in [
          'content-type',
          'content-range',
          'accept-ranges',
          'etag',
          'last-modified',
        ]) {
          output.headers.removeAll(name);
          final value = source.headers.value(name);
          if (value != null) output.headers.set(name, value);
        }
      }

      copyResponseHeaders(response);
      if (incoming.method == 'HEAD') {
        output.contentLength = response.contentLength;
        await _discard(response, read);
        return;
      }
      var chunks = StreamIterator<List<int>>(response);
      read.iterators.add(chunks);
      try {
        final prefixBytes = <int>[];
        var prefixInterrupted = false;
        var prefixRecoveryAttempts = 0;
        DateTime? prefixRecoveryStarted;
        Duration? prefixRetryAfter;
        var awaitingPrefixRecoveryByte = false;
        while (prefixBytes.length < 8) {
          bool advanced;
          try {
            advanced = await _advance(chunks, read);
          } catch (_) {
            read.check();
            advanced = false;
            prefixInterrupted = true;
          }
          if (advanced) {
            read.check();
            if (awaitingPrefixRecoveryByte && chunks.current.isNotEmpty) {
              awaitingPrefixRecoveryByte = false;
              prefixRecoveryAttempts = 0;
              prefixRecoveryStarted = null;
              _recoveries++;
            }
            prefixBytes.addAll(chunks.current);
            continue;
          }
          if (prefixBytes.isNotEmpty) break;
          if (response.contentLength <= 0 && !prefixInterrupted) break;
          final initialRange = response.statusCode == HttpStatus.partialContent
              ? MediaContentRange.parse(response.headers.value('content-range'))
              : null;
          final length = response.contentLength;
          final etag = MediaCachePolicy(response.headers).strongEtag;
          final restartable =
              incoming.method == 'GET' &&
              [
                PlaybackResourceRole.media,
                PlaybackResourceRole.segment,
                PlaybackResourceRole.initialization,
              ].contains(_roles[key]) &&
              (response.statusCode == HttpStatus.ok ||
                  response.statusCode == HttpStatus.partialContent);
          final validatedRange =
              restartable &&
              length > 0 &&
              etag != null &&
              response.compressionState !=
                  HttpClientResponseCompressionState.decompressed &&
              (response.statusCode == HttpStatus.ok ||
                  response.statusCode == HttpStatus.partialContent &&
                      initialRange != null &&
                      initialRange.end - initialRange.start + 1 == length);
          if (!restartable) {
            _lastValidationFailure = 'foreground-resume-unavailable';
            _recoveryFailures++;
            throw const HttpException('Media body cannot safely resume');
          }
          read.iterators.remove(chunks);
          await chunks.cancel();
          final started = prefixRecoveryStarted ??= DateTime.now();
          HttpClientResponse? resumed;
          while (resumed == null) {
            if (prefixRecoveryAttempts >= 6) {
              _lastValidationFailure = 'foreground-resume-exhausted';
              _recoveryFailures++;
              throw const HttpException('Media body recovery exhausted');
            }
            final attempt = prefixRecoveryAttempts++;
            _recoveryAttempts++;
            try {
              await _backoff(
                attempt,
                started,
                read,
                retryAfter: prefixRetryAfter,
              );
              prefixRetryAfter = null;
              final remaining =
                  const Duration(seconds: 120) -
                  DateTime.now().difference(started);
              if (remaining <= Duration.zero) {
                throw StateError('Media recovery budget exhausted');
              }
              final (
                candidate,
                resumedEffective,
              ) = await _fetchOnce(
                incoming,
                url,
                allowRange: allowRange,
                read: read,
                overrides: validatedRange
                    ? <String, String?>{
                        'range':
                            'bytes=${initialRange?.start ?? 0}-${initialRange?.end ?? length - 1}',
                        'if-range': etag,
                        'if-none-match': null,
                        'if-modified-since': null,
                      }
                    : const <String, String?>{},
              ).timeout(
                remaining,
                onTimeout: () {
                  for (final request in read.requests.toList()) {
                    request.abort();
                  }
                  throw StateError('Media recovery budget exhausted');
                },
              );
              if (_retryableStatus(candidate.statusCode)) {
                prefixRetryAfter = candidate.statusCode == 429
                    ? _retryAfter(candidate.headers.value('retry-after'))
                    : null;
                for (final request in read.requests.toList()) {
                  request.abort();
                }
                continue;
              }
              if (!validatedRange) {
                // No bytes have been forwarded. A fresh full response can be
                // adopted without joining content from two representations.
                response = candidate;
                effective = resumedEffective;
                copyResponseHeaders(candidate);
                resumed = candidate;
                continue;
              }
              final range = MediaContentRange.parse(
                candidate.headers.value('content-range'),
              );
              if (candidate.statusCode != HttpStatus.partialContent ||
                  range == null ||
                  range.start != (initialRange?.start ?? 0) ||
                  range.end != (initialRange?.end ?? length - 1) ||
                  range.total != (initialRange?.total ?? length) ||
                  candidate.contentLength != length ||
                  candidate.compressionState ==
                      HttpClientResponseCompressionState.decompressed ||
                  MediaCachePolicy(candidate.headers).strongEtag != etag ||
                  resumedEffective != effective) {
                _lastValidationFailure = 'foreground-resume-mismatch';
                _recoveryFailures++;
                for (final request in read.requests.toList()) {
                  request.abort();
                }
                throw const _UnsafeForegroundResume();
              }
              resumed = candidate;
            } on _UnsafeForegroundResume {
              rethrow;
            } on SocketException {
              read.check();
            } on TimeoutException {
              read.check();
            } on HttpException {
              read.check();
            } on StateError {
              _lastValidationFailure = 'foreground-resume-exhausted';
              _recoveryFailures++;
              rethrow;
            }
          }
          chunks = StreamIterator<List<int>>(resumed);
          read.iterators.add(chunks);
          prefixInterrupted = false;
          awaitingPrefixRecoveryByte = true;
        }
        final contentType = response.headers.contentType?.mimeType ?? '';
        final playlist =
            effective.path.toLowerCase().endsWith('.m3u8') ||
            contentType.contains('mpegurl') ||
            ascii.decode(prefixBytes.take(7).toList(), allowInvalid: true) ==
                '#EXTM3U' ||
            prefixInterrupted &&
                ascii
                    .decode(prefixBytes, allowInvalid: true)
                    .startsWith('#EXT');
        final mediaRole =
            [
              PlaybackResourceRole.media,
              PlaybackResourceRole.segment,
              PlaybackResourceRole.initialization,
            ].contains(_roles[key]) &&
            (response.statusCode == HttpStatus.ok ||
                response.statusCode == HttpStatus.partialContent);
        _received(prefixBytes.length, media: !playlist && mediaRole);
        if (playlist &&
            [
              HttpStatus.ok,
              HttpStatus.partialContent,
            ].contains(response.statusCode)) {
          int? rangeTotal;
          if (response.statusCode == HttpStatus.partialContent) {
            final range = RegExp(
              r'^bytes 0-(\d+)/(\d+)$',
            ).firstMatch(response.headers.value('content-range') ?? '');
            final completeRange =
                range != null &&
                int.parse(range[1]!) + 1 == int.parse(range[2]!);
            if (!completeRange) {
              if (!allowRange) {
                throw StateError('Server returned a partial HLS manifest');
              }
              await chunks.cancel();
              // A partial playlist cannot safely be rewritten: refetch the
              // complete representation, never pass original child URLs out.
              await _serveResponse(incoming, read, allowRange: false);
              return;
            }
            rangeTotal = int.parse(range[2]!);
          }
          _roles[key] = PlaybackResourceRole.playlist;
          output.statusCode = HttpStatus.ok;
          output.headers.removeAll('content-range');
          output.headers.set('accept-ranges', 'none');
          output.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          output.contentLength = -1;
          Stream<List<int>> source() async* {
            var count = 0;
            var lineBytes = 0;
            var bytes = prefixBytes;
            while (true) {
              read.check();
              count += bytes.length;
              if (count > 4 * 1024 * 1024) {
                throw StateError('Media playlist is too large');
              }
              for (final byte in bytes) {
                lineBytes = byte == 10 ? 0 : lineBytes + 1;
                if (lineBytes > 64 * 1024) {
                  throw StateError('Media playlist line is too large');
                }
              }
              yield bytes;
              if (!await _advance(chunks, read)) break;
              bytes = chunks.current;
              _received(bytes.length, media: false);
            }
            if (rangeTotal != null && count != rangeTotal) {
              throw StateError('Truncated HLS manifest');
            }
          }

          await _playlist(source(), effective, key, output, read);
        } else {
          if (_roles[key] == PlaybackResourceRole.media &&
              response.statusCode >= 200 &&
              response.statusCode < 300) {
            final finite =
                response.contentLength > 0 &&
                (response.statusCode != 206 ||
                    MediaContentRange.parse(
                          response.headers.value('content-range'),
                        ) !=
                        null);
            await _classify(
              finite
                  ? PlaybackCacheStream.stable
                  : PlaybackCacheStream.conservative,
            );
          }
          final representation = _beginRepresentation(
            incoming,
            key,
            response,
            effective,
            requestedRange: startupOverrides['range'],
          );
          if (incoming.method == 'GET' &&
              incoming.headers.value('x-rillight-prefetch') != '1' &&
              read.seekGeneration == _seekGeneration &&
              _roles[key] == PlaybackResourceRole.segment &&
              response.statusCode >= 200 &&
              response.statusCode < 300) {
            // The manifest has already selected this segment/variant. Start
            // the next segment after receiving its predecessor's first bytes,
            // instead of serializing connection setup behind the entire body.
            read.segmentPrefetchScheduled = true;
            _scheduleSegmentPrefetch(key);
          }
          if (response.statusCode == HttpStatus.partialContent &&
              _canReadAhead(incoming, key, representation)) {
            final seed = _ReadAheadSeed(
              response,
              effective,
              chunks,
              prefixBytes,
              read,
            );
            // A scheduler owns its response independently of the downstream
            // demuxer socket. Its cancellation/recovery rules still apply.
            responseDetached = true;
            try {
              if (await _tryReadAhead(
                incoming,
                key,
                url,
                read,
                validated: true,
                seed: seed,
              )) {
                return;
              }
            } finally {
              seed.cancelUnused();
            }
            _readAheadBypassReason ??= 'admission';
            _readAheadBypass.add(key);
            await _serveResponse(incoming, read);
            return;
          }
          final initialRange = response.statusCode == HttpStatus.partialContent
              ? MediaContentRange.parse(response.headers.value('content-range'))
              : null;
          final bodyLength =
              response.compressionState ==
                  HttpClientResponseCompressionState.decompressed
              ? -1
              : response.contentLength;
          final bodyStart = initialRange?.start ?? 0;
          final bodyEnd = initialRange?.end ?? bodyLength - 1;
          final bodyTotal = initialRange?.total ?? bodyLength;
          final bodyEtag = MediaCachePolicy(response.headers).strongEtag;
          final canResumeBody =
              mediaRole &&
              bodyLength > 0 &&
              bodyEtag != null &&
              (response.statusCode == HttpStatus.ok ||
                  response.statusCode == HttpStatus.partialContent &&
                      initialRange != null &&
                      initialRange.end - initialRange.start + 1 == bodyLength);
          var position = representation?.responseStart ?? 0;
          var received = 0;
          // Coalesce socket fragments into bounded immutable blocks. Otherwise
          // a fast 64 KiB socket exhausts file/index slots far below a GiB quota.
          final blockSize = min(
            min(
              _stream == PlaybackCacheStream.stable
                  ? SessionByteCache.maxBlockBytes
                  : 1024 * 1024,
              max(
                64 * 1024,
                min(
                  cache?.memoryLimitBytes ?? 0,
                  (cache?.pendingLimitBytes ?? 0) ~/ 6,
                ),
              ),
            ),
            representation == null
                ? 1
                : representation.responseEnd - representation.responseStart + 1,
          );
          // Untagged media cannot splice separately fetched ranges. It can
          // still download ahead from this one response into a private spool,
          // independently of the decoder's socket backpressure.
          final bufferResponse =
              sessionBuffering &&
              !dynamicSource &&
              readAheadBytes > 0 &&
              _roles[key] == PlaybackResourceRole.media &&
              representation != null &&
              bodyEtag == null &&
              bodyLength > 1024 * 1024 &&
              cache!.diagnostics['diskLimitBytes'] is int &&
              cache!.diagnostics['degradation'] == null &&
              _responseReadAheads.length < 2 &&
              _reserveCacheWorkspace(SessionReadAhead.blockBytes);
          if (bufferResponse) _charge(SessionReadAhead.blockBytes);
          final assemblyReserved =
              !bufferResponse &&
              representation != null &&
              _reserveCacheWorkspace(blockSize);
          Uint8List? assembly = assemblyReserved ? Uint8List(blockSize) : null;
          var assembled = 0;
          var blockStart = position;
          if (assembly != null) _charge(blockSize);
          void retain(Uint8List part) {
            var cursor = 0;
            while (cursor < part.length) {
              final length = min(blockSize - assembled, part.length - cursor);
              assembly!.setRange(assembled, assembled + length, part, cursor);
              assembled += length;
              cursor += length;
              if (assembled == blockSize) {
                _store(key, representation!, blockStart, assembly!);
                blockStart += assembled;
                assembled = 0;
                assembly = Uint8List(blockSize);
              }
            }
          }

          var bodyRead = read;
          Stream<List<int>> forward(List<int> bytes) async* {
            // A socket chunk is never accumulated into a whole media response.
            for (var start = 0; start < bytes.length; start += 64 * 1024) {
              bodyRead.check();
              final end = min(bytes.length, start + 64 * 1024);
              final part = Uint8List.fromList(bytes.sublist(start, end));
              _charge(part.length * 2);
              try {
                if (representation != null &&
                    received + part.length >
                        representation.responseEnd -
                            representation.responseStart +
                            1) {
                  throw const HttpException('Invalid media body length');
                }
                if (representation != null &&
                    _representations[key]?.generation ==
                        representation.generation) {
                  if (sessionBuffering &&
                      position == 0 &&
                      representation.policy.strongEtag != null &&
                      _roles[key] == PlaybackResourceRole.media) {
                    // Publish initialization before the demuxer can close its
                    // probe. TCP cancellation may be observed only after this
                    // producer's cleanup, too late to retain a partial block.
                    if (cache!.firstMissingOffset(
                          resource: key,
                          generation: representation.generation,
                          offset: 0,
                          length: part.length,
                        ) !=
                        null) {
                      _store(key, representation, 0, part);
                    }
                    blockStart = part.length;
                  } else if (assembly != null) {
                    retain(part);
                  }
                }
                read.outputStarted = true;
                yield part;
                position += part.length;
                received += part.length;
              } finally {
                _charge(-part.length * 2);
              }
            }
          }

          output.contentLength =
              response.compressionState ==
                  HttpClientResponseCompressionState.decompressed
              ? -1
              : response.contentLength;
          var complete = false;
          try {
            Stream<List<int>> body() async* {
              var iterator = chunks;
              var resumeAttempts = 0;
              DateTime? recoveryStarted;
              var awaitingRecoveredByte = false;
              try {
                yield* forward(prefixBytes);
                while (true) {
                  bool advanced;
                  var interrupted = false;
                  if (prefixInterrupted) {
                    prefixInterrupted = false;
                    advanced = false;
                    interrupted = true;
                  } else {
                    try {
                      advanced = await _advance(iterator, bodyRead);
                    } catch (_) {
                      bodyRead.check();
                      // The original length and strong validator let us request
                      // only the undelivered suffix after a broken body stream.
                      advanced = false;
                      interrupted = true;
                    }
                  }
                  if (advanced) {
                    bodyRead.check();
                    if (awaitingRecoveredByte && iterator.current.isNotEmpty) {
                      awaitingRecoveredByte = false;
                      recoveryStarted = null;
                      resumeAttempts = 0;
                      _recoveries++;
                    }
                    _received(iterator.current.length, media: mediaRole);
                    yield* forward(iterator.current);
                    continue;
                  }
                  if ((bodyLength < 0 && !interrupted) ||
                      received == bodyLength) {
                    break;
                  }
                  if (!canResumeBody || received > bodyLength) {
                    _lastValidationFailure = 'foreground-resume-unavailable';
                    _recoveryFailures++;
                    throw const HttpException(
                      'Media body cannot safely resume',
                    );
                  }
                  bodyRead.iterators.remove(iterator);
                  await iterator.cancel();
                  final started = recoveryStarted ??= DateTime.now();
                  HttpClientResponse? resumed;
                  Duration? retryAfter;
                  while (resumed == null) {
                    if (resumeAttempts >= 6) {
                      _lastValidationFailure = 'foreground-resume-exhausted';
                      _recoveryFailures++;
                      throw const HttpException(
                        'Media body recovery exhausted',
                      );
                    }
                    final attempt = resumeAttempts++;
                    _recoveryAttempts++;
                    try {
                      await _backoff(
                        attempt,
                        started,
                        bodyRead,
                        retryAfter: retryAfter,
                      );
                      retryAfter = null;
                      final remaining =
                          const Duration(seconds: 120) -
                          DateTime.now().difference(started);
                      if (remaining <= Duration.zero) {
                        throw StateError('Media recovery budget exhausted');
                      }
                      final (
                        candidate,
                        resumedEffective,
                      ) = await _fetchOnce(
                        incoming,
                        url,
                        allowRange: true,
                        read: bodyRead,
                        overrides: {
                          'range': 'bytes=${bodyStart + received}-$bodyEnd',
                          'if-range': bodyEtag,
                          'if-none-match': null,
                          'if-modified-since': null,
                        },
                      ).timeout(
                        remaining,
                        onTimeout: () {
                          for (final request in bodyRead.requests.toList()) {
                            request.abort();
                          }
                          throw StateError('Media recovery budget exhausted');
                        },
                      );
                      if (_retryableStatus(candidate.statusCode)) {
                        retryAfter = candidate.statusCode == 429
                            ? _retryAfter(
                                candidate.headers.value('retry-after'),
                              )
                            : null;
                        for (final request in bodyRead.requests.toList()) {
                          request.abort();
                        }
                        continue;
                      }
                      final range = MediaContentRange.parse(
                        candidate.headers.value('content-range'),
                      );
                      final candidateEtag = MediaCachePolicy(
                        candidate.headers,
                      ).strongEtag;
                      if (candidate.statusCode != HttpStatus.partialContent ||
                          range == null ||
                          range.start != bodyStart + received ||
                          range.end != bodyEnd ||
                          range.total != bodyTotal ||
                          candidate.contentLength != bodyLength - received ||
                          candidate.compressionState ==
                              HttpClientResponseCompressionState.decompressed ||
                          candidateEtag != bodyEtag ||
                          resumedEffective != effective) {
                        _lastValidationFailure = 'foreground-resume-mismatch';
                        _recoveryFailures++;
                        if (representation != null) {
                          _invalidate(key, representation);
                        }
                        for (final request in bodyRead.requests.toList()) {
                          request.abort();
                        }
                        throw const _UnsafeForegroundResume();
                      }
                      resumed = candidate;
                    } on _UnsafeForegroundResume {
                      rethrow;
                    } on SocketException {
                      bodyRead.check();
                    } on TimeoutException {
                      bodyRead.check();
                    } on HttpException {
                      bodyRead.check();
                    } on StateError {
                      _lastValidationFailure = 'foreground-resume-exhausted';
                      _recoveryFailures++;
                      rethrow;
                    }
                  }
                  iterator = StreamIterator<List<int>>(resumed);
                  bodyRead.iterators.add(iterator);
                  awaitingRecoveredByte = true;
                }
              } on HttpException {
                // A demuxer can close its initial 200 probe while this async*
                // generator is awaiting recovery, then open a tail range.
                // HttpResponse may cancel its subscription without observing
                // the cancellation future. Complete that cancellation inside
                // the generator so it cannot terminate the transport isolate.
                // A live read's HTTP failures still abort its response.
                if (!bodyRead.cancelled) rethrow;
              } finally {
                if (responseDetached || !identical(iterator, chunks)) {
                  bodyRead.iterators.remove(iterator);
                  await iterator.cancel();
                }
              }
            }

            // Stream cancellation releases the consumer promptly. A private
            // session buffer owns its producer separately so cached seeks can
            // continue its bounded download without opening a second response.
            if (bufferResponse) {
              // The session owns this single upstream response. A native seek
              // closes a downstream socket, not the still useful producer.
              bodyRead = _ProxyRead()..resourceKey = key;
              bodyRead.requests.addAll(read.requests);
              read.requests.clear();
              bodyRead.iterators.add(chunks);
              read.iterators.remove(chunks);
              bodyRead.response = read.response;
              read.response = null;
              responseDetached = true;
              final buffered = ResponseReadAhead(
                cache: cache!,
                resource: 'response-${++_responseReadAheadSequence}',
                length: bodyLength,
                // The same disk-budget window applies to untagged responses.
                // SessionReadAhead reserves workspace within that budget.
                aheadBytes: min(readAheadBytes, cache!.diskSessionLimitBytes),
                source: body(),
                cancelSource: bodyRead.cancel,
                releaseWorkspace: () {
                  _charge(-SessionReadAhead.blockBytes);
                  _releaseCacheWorkspace(SessionReadAhead.blockBytes);
                },
              );
              buffered.setPlaybackActive(_playbackActive);
              final previous = _bufferedResponse;
              if (previous != null) {
                _responseReadAheads.remove(previous.buffer);
                await previous.buffer.close();
              }
              _bufferedResponse = _BufferedResponse(
                key,
                representation,
                buffered,
              );
              _responseByteRanges = const [];
              _responseByteIdentity = null;
              _cachedTimeline = const [];
              _clearByteCoverage();
              _responseReadAheads.add(buffered);
              Stream<List<int>> consume() async* {
                await for (final bytes in buffered.read()) {
                  read.check();
                  read.outputStarted = true;
                  yield bytes;
                }
              }

              await _sendBody(output, consume());
            } else {
              await _sendBody(output, body());
            }
            if (!bufferResponse && bodyLength > 0 && received != bodyLength) {
              throw const HttpException('Truncated media representation');
            }
            complete = true;
            if (representation != null) {
              if (assembled > 0 &&
                  _representations[key]?.generation ==
                      representation.generation) {
                _store(
                  key,
                  representation,
                  blockStart,
                  Uint8List.sublistView(assembly!, 0, assembled),
                );
              }
              representation.complete = true;
            }
          } finally {
            if (!complete &&
                assembled > 0 &&
                representation != null &&
                representation.policy.strongEtag != null &&
                _representations[key]?.generation ==
                    representation.generation) {
              // A demuxer often reads only a small metadata prefix, then seeks
              // to the tail. Keep its validated bytes even below the MiB write
              // size; otherwise that file's initialization can remain absent
              // from the cache for the entire session. Untagged interrupted
              // responses still cannot publish a reusable partial snapshot.
              _store(
                key,
                representation,
                blockStart,
                Uint8List.sublistView(assembly!, 0, assembled),
              );
            }
            if (assemblyReserved) {
              _charge(-blockSize);
              _releaseCacheWorkspace(blockSize);
            }
            if (bufferResponse && !responseDetached) {
              _charge(-SessionReadAhead.blockBytes);
              _releaseCacheWorkspace(SessionReadAhead.blockBytes);
            }
            if (!complete &&
                !responseDetached &&
                representation != null &&
                representation.policy.strongEtag == null) {
              _invalidate(key, representation);
            }
          }
        }
      } finally {
        if (!responseDetached) {
          read.iterators.remove(chunks);
          await chunks.cancel();
        }
      }
    } catch (_) {
      // Do not expose upstream URLs/credentials in player errors or logs.
      try {
        if (read.outputStarted) {
          final socket = await output.detachSocket(writeHeaders: false);
          socket.destroy();
        } else {
          output.contentLength = -1;
          output.headers.removeAll('content-range');
          output.statusCode = HttpStatus.badGateway;
        }
      } catch (_) {}
    } finally {
      try {
        await output.close();
      } catch (_) {}
    }
  }

  _Representation? _beginRepresentation(
    HttpRequest incoming,
    String key,
    HttpClientResponse response,
    Uri effective, {
    String? requestedRange,
  }) {
    if (!_cacheableRequest(incoming, key)) return null;
    final policy = MediaCachePolicy(
      response.headers,
      allowSessionBuffering: sessionBuffering,
    );
    final contentRange = MediaContentRange.parse(
      response.headers.value('content-range'),
    );
    if (!policy.storable ||
        response.compressionState ==
            HttpClientResponseCompressionState.decompressed ||
        response.contentLength <= 0 ||
        !(response.statusCode == 200 ||
            response.statusCode == 206 &&
                contentRange != null &&
                contentRange.end - contentRange.start + 1 ==
                    response.contentLength)) {
      // A 403, a temporary 502, or a rejected/ignored Range says nothing
      // about the identity of bytes already verified for this session.
      // Keep them available for a later seek or source retry.
      final previous = _representations[key];
      if (previous != null &&
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          policy.strongEtag != null &&
          policy.strongEtag != previous.policy.strongEtag) {
        _invalidate(key, previous);
      }
      return null;
    }
    final total = contentRange?.total ?? response.contentLength;
    final requested = MediaByteRange.resolve(
      requestedRange ?? incoming.headers.value('range'),
      total,
    );
    if (contentRange != null &&
        (requested == null ||
            requested.start != contentRange.start ||
            requested.end != contentRange.end)) {
      return null;
    }
    final previous = _representations[key];
    final same =
        previous != null &&
        previous.policy.strongEtag != null &&
        previous.policy.strongEtag == policy.strongEtag &&
        (previous.effective == effective || sessionBuffering) &&
        previous.total == total;
    if (previous != null && !same) {
      _invalidate(key, previous);
    }
    final safeHeaders = <String, String>{};
    for (final name in ['content-type', 'etag', 'last-modified']) {
      final value = response.headers.value(name);
      if (value != null && value.length <= 1024) safeHeaders[name] = value;
    }
    final metadataCost =
        512 +
        2 *
            (effective.toString().length +
                safeHeaders.values.fold<int>(
                  0,
                  (sum, value) => sum + value.length,
                ) +
                (policy.etag?.length ?? 0) +
                (policy.lastModified?.length ?? 0));
    // Sealed routing remains available even when a resource's cache metadata
    // would exceed its reserved share of the management budget.
    if (metadataCost > 4096) {
      return null;
    }
    final representation = _Representation(
      generation: same ? previous.generation : _nextRepresentation++,
      policy: policy,
      total: total,
      effective: effective,
      headers: safeHeaders,
      responseStart: contentRange?.start ?? 0,
      responseEnd: contentRange?.end ?? total - 1,
      rangeSupported: contentRange != null,
    );
    // Strongly validated complete chunks may survive cancellation; weak/no-tag
    // responses become reusable only when their entire promised body completes.
    representation.complete = policy.strongEtag != null;
    while (_representations.length >= 256 &&
        !_representations.containsKey(key)) {
      final oldest = _representations.keys.first;
      _invalidate(oldest, _representations[oldest]!);
    }
    if (_bufferedResponse?.key == key) _discardBufferedResponse();
    _representations[key] = representation;
    if (_roles[key] == PlaybackResourceRole.media && _timelineResource != key) {
      _clearByteCoverage();
      _timelineResource = key;
      _timelineIdentity = null;
      _timelineIndex = null;
      _mp4TimelineIndex = null;
      _mappingUnknownReason = null;
      _cachedTimeline = const [];
      _timelineSequence++;
    }
    return representation;
  }

  Future<void> _playlist(
    Stream<List<int>> source,
    Uri base,
    String parent,
    HttpResponse output,
    _ProxyRead read,
  ) async {
    var stable = false;
    var master = false;
    await _classify(PlaybackCacheStream.conservative);
    var sequence = 0;
    var discontinuity = 0;
    var keyContext = '';
    String? previousSegment;
    Uri? initialization;
    var byteRangeNext = false;
    var mapHasByteRange = false;
    final nextSegments = <String, _HlsNext>{};
    var nextSegmentBytes = 0;
    var playlistNext = false;
    StringBuffer? timelineText = StringBuffer();
    var timelineTextBytes = 0;
    String child(Uri url, PlaybackResourceRole role, String context) {
      final result = register(url, role: role, context: context);
      if (role == PlaybackResourceRole.initialization) {
        initialization = mapHasByteRange ? null : result;
      } else if (role == PlaybackResourceRole.segment) {
        final segments = result.pathSegments;
        final identity = segments.length < 2
            ? null
            : _routes.open(segments[1])?.identity;
        if (identity != null && !byteRangeNext) {
          if (previousSegment != null) {
            final edge = _HlsNext(result, initialization, parent);
            final cost = previousSegment!.length + edge.cost;
            if (nextSegmentBytes + cost <= 2 * 1024 * 1024) {
              nextSegments[previousSegment!] = edge;
              nextSegmentBytes += cost;
            }
          }
          previousSegment = identity;
        } else {
          previousSegment = null;
        }
        byteRangeNext = false;
      }
      return result.toString();
    }

    String rewrite(String line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return line;
      if (trimmed == '#EXT-X-ENDLIST') stable = true;
      if (trimmed.startsWith('#EXT-X-STREAM-INF:')) master = true;
      if (trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.tryParse(trimmed.split(':').last) ?? 0;
      }
      if (trimmed.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        discontinuity = int.tryParse(trimmed.split(':').last) ?? 0;
      }
      if (trimmed == '#EXT-X-DISCONTINUITY') {
        discontinuity++;
        previousSegment = null;
      }
      if (trimmed.startsWith('#EXT-X-BYTERANGE:')) {
        byteRangeNext = true;
        previousSegment = null;
      }
      if (trimmed.startsWith('#EXT-X-MAP:')) {
        mapHasByteRange = trimmed.toUpperCase().contains('BYTERANGE=');
      }
      if (trimmed.startsWith('#EXT-X-KEY:')) {
        keyContext = trimmed;
        previousSegment = null;
      }
      if (trimmed.startsWith('#EXT-X-STREAM-INF:')) playlistNext = true;
      final context = '$parent:$sequence:$discontinuity:$keyContext';
      if (!trimmed.startsWith('#')) {
        final role = playlistNext
            ? PlaybackResourceRole.playlist
            : PlaybackResourceRole.segment;
        playlistNext = false;
        sequence++;
        return child(base.resolve(trimmed), role, context);
      }
      return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (match) {
        final role =
            trimmed.startsWith('#EXT-X-KEY:') ||
                trimmed.startsWith('#EXT-X-SESSION-KEY:')
            ? PlaybackResourceRole.key
            : trimmed.startsWith('#EXT-X-MAP:')
            ? PlaybackResourceRole.initialization
            : PlaybackResourceRole.playlist;
        return 'URI="${child(base.resolve(match[1]!), role, context)}"';
      });
    }

    // Only one bounded input line and its sealed output are retained. A long
    // manifest does not accumulate a route registry or rewritten document.
    if (!_reserveCacheWorkspace(512 * 1024)) {
      throw const HttpException('Playlist workspace exhausted');
    }
    _charge(512 * 1024);
    try {
      final body = BytesBuilder(copy: false);
      var streaming = false;
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        read.check();
        final rewritten = rewrite(line);
        final encoded = utf8.encode('$rewritten\n');
        if (!streaming && body.length + encoded.length > 512 * 1024) {
          streaming = true;
          read.outputStarted = true;
          output.add(body.takeBytes());
          await output.flush();
        }
        if (streaming) {
          read.outputStarted = true;
          output.add(encoded);
          await output.flush();
        } else {
          body.add(encoded);
        }
        if (timelineText != null) {
          timelineTextBytes += encoded.length;
          if (timelineTextBytes <= 128 * 1024) {
            timelineText.write('$rewritten\n');
          } else {
            timelineText = null;
          }
        }
      }
      await _classify(
        stable && !master
            ? PlaybackCacheStream.stable
            : PlaybackCacheStream.conservative,
      );
      if (!master) {
        if (stable) _replaceHlsIndex(parent, nextSegments);
        _setHlsPlaylist(parent, base, timelineText?.toString());
      }
      if (!streaming) {
        read.check();
        output.contentLength = body.length;
        read.outputStarted = true;
        output.add(body.takeBytes());
        await output.flush();
      }
    } finally {
      _charge(-512 * 1024);
      _releaseCacheWorkspace(512 * 1024);
    }
  }

  void _replaceHlsIndex(String parent, Map<String, _HlsNext> next) {
    _pendingSegmentPrefetch.remove(parent);
    _hlsPrefetchWindows.remove(parent);
    for (final key in _hlsOwners.remove(parent) ?? const <String>{}) {
      final removed = _hlsNext.remove(key);
      if (removed != null) _hlsIndexBytes -= removed.cost + key.length;
    }
    final owned = <String>{};
    for (final entry in next.entries) {
      final cost = entry.key.length + entry.value.cost;
      if (_hlsIndexBytes + cost > 2 * 1024 * 1024) break;
      _hlsNext[entry.key] = entry.value;
      _hlsIndexBytes += cost;
      owned.add(entry.key);
    }
    if (owned.isNotEmpty) _hlsOwners[parent] = owned;
  }

  void _setHlsPlaylist(String parent, Uri base, String? text) {
    final previous = _hlsPlaylists.remove(parent);
    if (previous != null) {
      for (final key in previous.segmentKeys) {
        if (_hlsSegmentOwners[key] == parent) _hlsSegmentOwners.remove(key);
      }
    }
    final index = text == null
        ? null
        : HlsCacheIndex.parseMediaPlaylist(
            text: text,
            playlistUri: base,
            verifiedTimes: const {},
          );
    final keys = <String>{};
    if (index != null) {
      for (final segment in index.segments) {
        final key = _hlsRouteIdentity(segment.uri);
        if (key == null) continue;
        _hlsSegmentOwners[key] = parent;
        keys.add(key);
      }
    }
    if (_hlsPlaylists.length >= 4) {
      final oldest = _hlsPlaylists.keys.first;
      _hlsActiveOwners.remove(oldest);
      final discarded = _hlsPlaylists.remove(oldest);
      for (final key in discarded?.segmentKeys ?? const <String>{}) {
        if (_hlsSegmentOwners[key] == oldest) _hlsSegmentOwners.remove(key);
      }
    }
    _hlsPlaylists[parent] = _HlsPlaylistState(base, text ?? '', index, keys);
    _hlsDependencyKeys.clear();
    for (final playlist in _hlsPlaylists.values) {
      for (final segment
          in playlist.index?.segments ?? const <HlsIndexedSegment>[]) {
        final segmentKey = _hlsRouteIdentity(segment.uri);
        final mapKey = segment.mapUri == null
            ? null
            : _hlsRouteIdentity(segment.mapUri!);
        if (segmentKey != null) _hlsDependencyKeys.add(segmentKey);
        if (mapKey != null) _hlsDependencyKeys.add(mapKey);
      }
    }
    _cachedTimeline = const [];
    _hlsUnknownReason = text == null
        ? 'hlsManifestTooLarge'
        : 'hlsTimingUnavailable';
    _timelineSequence++;
  }

  String? _hlsRouteIdentity(Uri uri) {
    if (uri.host != '127.0.0.1' ||
        uri.port != _server.port ||
        uri.pathSegments.length < 3 ||
        uri.pathSegments.first != _secret) {
      return null;
    }
    return _routes.open(uri.pathSegments[1])?.identity;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancelPendingReads();
    await Future.wait(
      _segmentPrefetchJobs.values.map((job) => job.task).toList(),
    );
    await _readAhead?.close();
    await Future.wait(
      _responseReadAheads.map((response) => response.close()).toList(),
    );
    for (final load in _loads.values) {
      load.producer.cancel();
    }
    _client.close(force: true);
    await _server.close(force: true);
    try {
      await _cacheReady;
    } catch (_) {
      // A failed cache initialization owns no disk session to close.
    }
    await cache?.close();
    await Future.wait(_writes.toList());
    _routes.close();
    _privateSubtitles.clear();
    _hlsNext.clear();
    _hlsOwners.clear();
    _hlsPlaylists.clear();
    _hlsSegmentOwners.clear();
    _hlsDependencyKeys.clear();
    _hlsActiveOwners.clear();
    _hlsProbeCache.clear();
    _representations.clear();
    _roles.clear();
  }
}

class _BufferedResponse {
  const _BufferedResponse(this.key, this.representation, this.buffer);
  final String key;
  final _Representation representation;
  final ResponseReadAhead buffer;
}

class _MediaRecoveryExhausted implements Exception {
  const _MediaRecoveryExhausted();
}

class _ReadAheadAuthenticationFailure implements Exception {
  const _ReadAheadAuthenticationFailure(this.status);
  final int status;
}

class _Representation {
  _Representation({
    required this.generation,
    required this.policy,
    required this.total,
    required this.effective,
    required this.headers,
    required this.responseStart,
    required this.responseEnd,
    required this.rangeSupported,
  });
  final int generation;
  MediaCachePolicy policy;
  final int total;
  Uri effective;
  final Map<String, String> headers;
  final int responseStart;
  final int responseEnd;
  final bool rangeSupported;
  bool complete = false;
  bool headUnsupported = false;
}

class _ReadAheadSeed {
  _ReadAheadSeed(
    this.response,
    this.effective,
    this.chunks,
    this.prefix,
    _ProxyRead read,
  ) : owner = _ProxyRead() {
    owner.requests.addAll(read.requests);
    read.requests.clear();
    owner.iterators.add(chunks);
    read.iterators.remove(chunks);
    owner.response = read.response;
    read.response = null;
  }

  final HttpClientResponse response;
  final Uri effective;
  final StreamIterator<List<int>> chunks;
  final List<int> prefix;
  final _ProxyRead owner;
  bool used = false;

  _ReadAheadSeed? take(int start, int end, _ProxyRead producer) {
    if (used) return null;
    final range = MediaContentRange.parse(
      response.headers.value('content-range'),
    );
    if (range == null || range.start != start || range.end < end) {
      cancelUnused();
      return null;
    }
    used = true;
    producer.requests.addAll(owner.requests);
    owner.requests.clear();
    producer.iterators.addAll(owner.iterators);
    owner.iterators.clear();
    producer.response = owner.response;
    owner.response = null;
    return this;
  }

  void cancelUnused() {
    if (!used) {
      used = true;
      owner.cancel();
    }
  }
}

class _ProxyRead {
  _ProxyRead({this.seekGeneration = 0, this.refusalParent});
  final int seekGeneration;
  final _ProxyRead? refusalParent;
  bool _refusalRetried = false;
  bool claimRefusalRetry() {
    if (refusalParent != null) return refusalParent!.claimRefusalRetry();
    if (_refusalRetried) return false;
    _refusalRetried = true;
    return true;
  }

  String? resourceKey;
  String? localInputId;
  bool readAheadProducer = false;
  HttpClientResponse? response;
  bool cancelled = false;
  bool outputStarted = false;
  bool segmentPrefetchScheduled = false;
  final requests = <HttpClientRequest>{};
  final iterators = <StreamIterator<List<int>>>{};
  final _cancelled = Completer<void>();
  Future<void> get cancelledFuture => _cancelled.future;
  void check() {
    if (cancelled) throw const HttpException('Media read cancelled');
  }

  void releaseUnconsumedResponse() {
    final pending = response;
    response = null;
    if (pending == null) return;
    try {
      // abort() only closes requests before their response headers arrive.
      // Cancelling the body subscription releases a rejected response's socket,
      // including servers sending an HTML error body with keep-alive enabled.
      unawaited(pending.listen(null, onError: (Object _) {}).cancel());
    } on StateError {
      // A body already owned by a registered iterator is cancelled below.
    }
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
    releaseUnconsumedResponse();
    for (final request in requests) {
      request.abort();
    }
    for (final iterator in iterators.toList()) {
      unawaited(iterator.cancel());
    }
  }
}

class _SegmentPrefetchJob {
  _SegmentPrefetchJob(this.next);

  final _HlsNext next;
  late Future<void> task;
  HttpClient? client;
  HttpClientRequest? request;
  StreamIterator<List<int>>? iterator;
  bool cancelled = false;
  bool completed = false;
  bool succeeded = false;
  int bufferedBytes = 0;
  final progress = Stopwatch()..start();

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    request?.abort();
    final current = iterator;
    if (current != null) unawaited(current.cancel());
    client?.close(force: true);
  }
}

class _HlsPrefetchWindow {
  _HlsPrefetchWindow(this.anchor, this.remainingBytes);
  final String anchor;
  int remainingBytes;
  int remainingSegments = 4;
}

class _SharedLoad {
  _SharedLoad(this.producer);
  final _ProxyRead producer;
  late final Future<Uint8List?> future;
  int consumers = 0;
}

class _HlsNext {
  const _HlsNext(this.url, this.initialization, this.owner);
  final Uri url;
  final Uri? initialization;
  final String owner;
  int get cost =>
      url.toString().length + (initialization?.toString().length ?? 0) + 64;
}

class _HlsPlaylistState {
  _HlsPlaylistState(this.base, this.text, this.index, this.segmentKeys);

  final Uri base;
  final String text;
  final HlsCacheIndex? index;
  final Set<String> segmentKeys;
  final verified = <int, _HlsVerifiedProbe>{};
}

class _HlsVerifiedProbe {
  const _HlsVerifiedProbe(this.identity, this.result);
  final String identity;
  final HlsFmp4ProbeResult result;
}

class _HlsMappedPlaylist {
  const _HlsMappedPlaylist(
    this.index,
    this.hasVideo,
    this.hasAudio,
    this.rawStart,
  );
  final HlsCacheIndex index;
  final bool hasVideo;
  final bool hasAudio;
  final Duration rawStart;
}

class _HlsResource {
  const _HlsResource(this.key, this.representation, this.availability);
  final String key;
  final _Representation representation;
  final HlsCachedResource availability;
}

class _UnsafeForegroundResume implements Exception {
  const _UnsafeForegroundResume();
}
