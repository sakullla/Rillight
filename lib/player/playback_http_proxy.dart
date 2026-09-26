import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cache/http_cache_policy.dart';
import 'cache/hls_cache_index.dart';
import 'cache/hls_fmp4_probe.dart';
import 'cache/matroska_cache_index.dart';
import 'cache/mp4_cache_index.dart';
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
    this.cache,
    this.dynamicSource,
    this.sessionBuffering,
    this.readAheadBytes,
    this.onStreamChanged,
  ) : _secret = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join() {
    _client.autoUncompress = true;
    // HttpClient defaults to a smaller per-host pool than the proxy's request
    // budget. One extra connection keeps the single read-ahead producer from
    // occupying a foreground media, seek, or subtitle connection.
    _client.maxConnectionsPerHost = _maxRequests + 1;
    _client.connectionTimeout = const Duration(seconds: 15);
    _server.listen((request) => unawaited(_serve(request)));
  }

  final HttpServer _server;
  final HttpClient _client = HttpClient();
  final Uri? origin;
  final Map<String, String> headers;
  final String _secret;
  final SessionByteCache? cache;
  final bool dynamicSource;

  /// Explicit playback-only storage policy. The cache must be session-owned
  /// and deleted on close; never use this opt-in for a persistent HTTP cache.
  final bool sessionBuffering;
  final int readAheadBytes;
  SessionReadAhead? _readAhead;
  final _readAheadBypass = <String>{};
  MatroskaCacheIndex? _timelineIndex;
  Mp4CacheIndex? _mp4TimelineIndex;
  String? _timelineIdentity;
  List<CachedTimeRange> _cachedTimeline = const [];
  int _timelineSequence = 0;
  bool _refreshingTimeline = false;
  final FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged;
  final _routes = SealedMediaRoutes();
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
  int _seekGeneration = 0;
  int _hlsIndexBytes = 0;
  int _segmentPrefetchGeneration = 0;
  Future<void>? _segmentPrefetch;
  _HlsNext? _activeSegmentPrefetch;
  final _pendingSegmentPrefetch = <String, _HlsNext>{};
  HttpClientRequest? _segmentPrefetchRequest;
  StreamIterator<List<int>>? _segmentPrefetchIterator;
  _ProxyRead? _segmentPrefetchRead;
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
  int _repeatedDownloadBytes = 0;
  int _recoveryAttempts = 0;
  int _recoveries = 0;
  int _recoveryFailures = 0;
  int _cancelled = 0;
  String? _lastValidationFailure;
  int? _lastUpstreamStatus;
  int? _authenticationStatus;
  int _inFlight = 0;
  int _inFlightPeak = 0;
  final _samples = <(DateTime, int)>[];
  PlaybackCacheStream _stream = PlaybackCacheStream.conservative;
  bool _closed = false;

  int get upstreamBytes => _upstreamBytes;
  void resumeAfterDiskRecovery() => _readAhead?.resumeAfterDiskRecovery();
  Future<void> retryReadAhead() async {
    if (_closed) return;
    final previous = _readAhead;
    _readAhead = null;
    _timelineIndex = null;
    _mp4TimelineIndex = null;
    _timelineIdentity = null;
    _cachedTimeline = const [];
    _timelineSequence++;
    if (_hlsPlaylists.isNotEmpty) _hlsUnknownReason = 'hlsTimingUnavailable';
    _readAheadBypass.clear();
    await previous?.close();
  }

  PlaybackCacheStream get stream => _stream;
  List<CachedTimeRange> get _visibleCachedTimeline {
    final degradation = cache?.diagnostics['degradation'];
    return degradation == null || degradation == 'disk-timeout'
        ? _cachedTimeline
        : const [];
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
    if (_readAhead == null || _timelineIdentity == null) {
      return 'indexUnavailable';
    }
    if (_cachedTimeline.isEmpty &&
        _timelineIndex == null &&
        _mp4TimelineIndex == null) {
      return 'mediaMappingUnavailable';
    }
    return null;
  }

  double get upstreamBytesPerSecond {
    _pruneSamples();
    return _samples.fold<int>(0, (sum, sample) => sum + sample.$2).toDouble();
  }

  Map<String, Object?> get diagnostics => {
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
    'authenticationStatus': _authenticationStatus,
    'proxyInFlightBytes': _inFlight,
    'proxyInFlightPeakBytes': _inFlightPeak,
    'registeredResources': _roles.length,
    'registryBudgetBytes': _roles.length * 4096,
    'streamPolicy': _stream.name,
    'sessionBuffering': sessionBuffering,
    'activeRequests': _active,
    'upstreamBytesPerSecond': upstreamBytesPerSecond,
    'cacheWorkspaceBytes': _cacheWorkspace,
    'timelineIdentity': _timelineIdentity ?? '',
    'timelineSequence': _timelineSequence,
    'timelineUnknownReason': _timelineUnknownReason,
    'cachedTimeRanges': [
      for (final range in _visibleCachedTimeline)
        {
          'startMs': range.start.inMilliseconds,
          'endMs': range.end.inMilliseconds,
        },
    ],
    'timelineCuePoints': _timelineIndex?.points.length ?? 0,
    'readAheadBypassedResources': _readAheadBypass.length,
    'hlsNextSegments': _hlsNext.length,
    'hlsIndexBytes': _hlsIndexBytes,
    'hlsPlaylists': _hlsPlaylists.length,
    'hlsActivePlaylists': _hlsActiveOwners.length,
    'segmentPrefetchActive': _segmentPrefetch != null,
    'segmentPrefetchPending': _pendingSegmentPrefetch.length,
    ...?_readAhead?.diagnostics,
  };

  static Future<PlaybackHttpProxy> create({
    Uri? origin,
    Map<String, String> headers = const {},
    SessionByteCache? cache,
    bool dynamicSource = false,
    bool sessionBuffering = false,
    int readAheadBytes = 0,
    FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged,
  }) async => PlaybackHttpProxy._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    origin,
    Map.unmodifiable(headers),
    cache,
    dynamicSource,
    sessionBuffering,
    readAheadBytes,
    onStreamChanged,
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

  Future<void> refreshTimeline(Duration duration) async {
    if (_hlsPlaylists.isNotEmpty) {
      await _refreshHlsTimeline(duration);
      return;
    }
    final ahead = _readAhead;
    if (_closed ||
        _refreshingTimeline ||
        ahead == null ||
        duration <= Duration.zero) {
      if (ahead == null && _cachedTimeline.isNotEmpty) {
        _cachedTimeline = const [];
        _timelineSequence++;
      }
      return;
    }
    if (!_reserveCacheWorkspace(1024 * 1024)) return;
    _refreshingTimeline = true;
    _charge(1024 * 1024);
    try {
      final identity = '${ahead.resource}:${ahead.generation}';
      if (_timelineIdentity != identity) {
        _timelineIdentity = identity;
        _timelineIndex = null;
        _mp4TimelineIndex = null;
        _cachedTimeline = const [];
        _timelineSequence++;
      }
      final bytes = await cache!.availableRanges(
        resource: ahead.resource,
        generation: ahead.generation,
      );
      if (_closed || !identical(ahead, _readAhead)) return;
      if (bytes == null) {
        // A busy cache snapshot can time out without invalidating verified
        // blocks. Explicit eviction/invalidation clears the timeline below.
        return;
      }
      if (bytes.length == 1 &&
          bytes.single.start == 0 &&
          bytes.single.end >= ahead.total) {
        _cachedTimeline = [CachedTimeRange(Duration.zero, duration)];
        _timelineSequence++;
        return;
      }
      Future<Uint8List?> read(int offset, int length) async {
        final output = BytesBuilder(copy: false);
        while (output.length < length) {
          final hit = await cache!.read(
            resource: ahead.resource,
            generation: ahead.generation,
            offset: offset + output.length,
            maxLength: length - output.length,
            countHit: false,
          );
          if (hit == null) return null;
          output.add(hit.bytes);
        }
        return output.takeBytes();
      }

      final index =
          _timelineIndex ??
          await MatroskaCacheIndex.load(total: ahead.total, read: read);
      if (_closed || !identical(ahead, _readAhead)) return;
      _timelineIndex = index;
      if (index != null) {
        _cachedTimeline = await index.ranges(bytes, duration, read: read);
      } else {
        final mp4 =
            _mp4TimelineIndex ??
            await Mp4CacheIndex.load(total: ahead.total, read: read);
        if (_closed || !identical(ahead, _readAhead)) return;
        _mp4TimelineIndex = mp4;
        _cachedTimeline = mp4?.ranges(bytes, duration) ?? const [];
      }
      _timelineSequence++;
    } catch (_) {
      _cachedTimeline = const [];
      _timelineSequence++;
    } finally {
      _charge(-1024 * 1024);
      _cacheWorkspace -= 1024 * 1024;
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
                _cacheWorkspace -= 1024 * 1024;
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
    final query = Map<String, List<String>>.from(url.queryParametersAll);
    query.removeWhere((_, values) => values.any(tokens.contains));
    return query.isEmpty
        ? url.replace(query: '')
        : url.replace(queryParameters: query);
  }

  Future<(HttpClientResponse, Uri)> _fetch(
    HttpRequest incoming,
    Uri url, {
    bool allowRange = true,
    required _ProxyRead read,
    String? method,
    Map<String, String?> overrides = const {},
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
        );
        final status = result.$1.statusCode;
        if ((method ?? incoming.method) == 'HEAD' ||
            !_retryableStatus(status) ||
            attempt == 5) {
          if (_retryableStatus(status) && attempt == 5) {
            _recoveryFailures++;
          } else if (attempt > 0 && status >= 200 && status < 400) {
            _recoveries++;
          }
          return result;
        }
        final retryAfter = status == 429
            ? _retryAfter(result.$1.headers.value('retry-after'))
            : null;
        for (final request in read.requests.toList()) {
          request.abort();
        }
        await _backoff(attempt, started, read, retryAfter: retryAfter);
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
  }) async {
    final elapsed = DateTime.now().difference(started);
    final remaining = const Duration(seconds: 120) - elapsed;
    final seconds = min(15, 1 << attempt);
    final jitter = Random().nextInt(201) - 100;
    final base = Duration(milliseconds: min(15000, seconds * 1000 + jitter));
    final delay = retryAfter != null && retryAfter > base ? retryAfter : base;
    if (remaining <= Duration.zero || delay > remaining) {
      throw StateError('Media recovery budget exhausted');
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
  }) async {
    for (var redirects = 0; redirects <= 10; redirects++) {
      read.check();
      url = _withoutForeignCredentials(url);
      final opening = _client.openUrl(method ?? incoming.method, url);
      final request = await opening.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          unawaited(
            opening.then<void>((late) => late.abort(), onError: (Object _) {}),
          );
          throw const HttpException('Media connection timeout');
        },
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
      final response = await request.close().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          request.abort();
          throw const HttpException('Media response timeout');
        },
      );
      read.check();
      _lastUpstreamStatus = response.statusCode;
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
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
      ]).timeout(const Duration(seconds: 15));
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
    // 1 MiB for eight transports; the rest of the 2/4 MiB proxy budget is shared
    // by assemblies, cached reads and playlist rewriting. Under pressure cache
    // work is bypassed, so an index probe can still reach its upstream source.
    final limit = (_stream == PlaybackCacheStream.stable ? 3 : 1) * 1024 * 1024;
    if (_cacheWorkspace + bytes > limit) return false;
    _cacheWorkspace += bytes;
    return true;
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
    if (_hlsPlaylists.isNotEmpty) {
      _hlsActiveOwners.clear();
      _cachedTimeline = const [];
      _hlsUnknownReason = 'hlsSelectionUnverified';
      _timelineSequence++;
    }
    _cancelSegmentPrefetch(clearPending: true);
    _readAhead?.stop();
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

  void _cancelSegmentPrefetch({bool clearPending = false}) {
    if (clearPending) {
      _pendingSegmentPrefetch.clear();
      _activeSegmentPrefetch = null;
    } else if (_activeSegmentPrefetch case final active?) {
      _queueSegmentPrefetch(active);
    }
    _segmentPrefetchGeneration++;
    _segmentPrefetchRead?.cancel();
    _segmentPrefetchRequest?.abort();
    final iterator = _segmentPrefetchIterator;
    if (iterator != null) unawaited(iterator.cancel());
  }

  void _scheduleSegmentPrefetch(String current) {
    final next = _hlsNext[current];
    if (_closed ||
        next == null ||
        cache == null ||
        cache!.diagnostics['degradation'] != null ||
        dynamicSource) {
      return;
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

  void _pumpSegmentPrefetch() {
    if (_closed ||
        _segmentPrefetch != null ||
        _active != 0 ||
        _pendingSegmentPrefetch.isEmpty) {
      return;
    }
    final owner = _pendingSegmentPrefetch.keys.first;
    final next = _pendingSegmentPrefetch.remove(owner)!;
    _activeSegmentPrefetch = next;
    final generation = _segmentPrefetchGeneration;
    late final Future<void> task;
    task =
        (() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (_closed || generation != _segmentPrefetchGeneration) {
            return;
          }
          if (_active != 0) {
            _queueSegmentPrefetch(next);
            return;
          }
          final disk = cache!.diagnostics['diskLimitBytes'] is int;
          final limit = min(
            SessionReadAhead.requestBytes,
            disk ? cache!.diskSessionLimitBytes ~/ 4 : cache!.memoryLimitBytes,
          );
          if (limit <= 0) return;
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 5)
            ..maxConnectionsPerHost = 1;
          try {
            for (final url in [
              if (next.initialization != null) next.initialization!,
              next.url,
            ]) {
              if (_closed || generation != _segmentPrefetchGeneration) return;
              final opening = client.getUrl(url);
              final request = await opening.timeout(const Duration(seconds: 5));
              _segmentPrefetchRequest = request;
              request.headers.set('x-rillight-prefetch', '1');
              request.headers.set('range', 'bytes=0-${limit - 1}');
              final deadline = Timer(
                const Duration(seconds: 20),
                request.abort,
              );
              try {
                final response = await request.close().timeout(
                  const Duration(seconds: 20),
                );
                if (response.statusCode != 200 && response.statusCode != 206) {
                  return;
                }
                final iterator = StreamIterator<List<int>>(response);
                _segmentPrefetchIterator = iterator;
                var bytes = 0;
                try {
                  while (bytes < limit &&
                      await iterator.moveNext().timeout(
                        const Duration(seconds: 15),
                      )) {
                    if (_closed || generation != _segmentPrefetchGeneration) {
                      return;
                    }
                    bytes += iterator.current.length;
                  }
                } finally {
                  _segmentPrefetchIterator = null;
                  await iterator.cancel();
                }
              } finally {
                deadline.cancel();
                _segmentPrefetchRequest = null;
              }
            }
          } catch (_) {
            // Prefetch is optional; the foreground request uses normal recovery.
          } finally {
            client.close(force: true);
          }
        })().whenComplete(() {
          if (identical(_segmentPrefetch, task)) {
            _segmentPrefetch = null;
            _activeSegmentPrefetch = null;
            _pumpSegmentPrefetch();
          }
        });
    _segmentPrefetch = task;
    unawaited(task);
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
    if (_hlsDependencyKeys.contains(key)) {
      _cachedTimeline = const [];
      _hlsUnknownReason = 'hlsResourceChanged';
      _timelineSequence++;
    }
    if (_readAhead?.resource == key) {
      _cachedTimeline = const [];
      _timelineIdentity = null;
      _timelineIndex = null;
      _mp4TimelineIndex = null;
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
    final (response, effective) = await _fetch(
      incoming,
      url,
      read: read,
      method: 'HEAD',
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
            response.statusCode == 405 ||
            (sessionBuffering && effective != representation.effective) ||
            (response.statusCode == 200 && newPolicy.strongEtag == null))) {
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
      valid =
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
        validatedPolicy = policy;
        representation.effective = effectiveProbe;
      } else {
        for (final request in read.requests.toList()) {
          request.abort();
        }
        read.requests.clear();
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
    if (response.headers.value('cache-control') != null ||
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
      final producer = _ProxyRead();
      final shared = _SharedLoad(producer);
      shared.future = (() async {
        final started = DateTime.now();
        for (var attempt = 0; attempt < 6; attempt++) {
          producer.check();
          Duration? retryAfter;
          var receivedThisAttempt = 0;
          try {
            final (response, effective) = await _fetchOnce(
              incoming,
              url,
              allowRange: true,
              read: producer,
              overrides: {
                'range': 'bytes=$start-$end',
                'if-range': representation.policy.strongEtag,
                'if-none-match': null,
                'if-modified-since': null,
              },
            );
            if (_retryableStatus(response.statusCode)) {
              if (response.statusCode == 429) {
                retryAfter = _retryAfter(response.headers.value('retry-after'));
              }
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
                range.start != start ||
                range.end != end ||
                range.total != representation.total ||
                (!sessionBuffering && effective != representation.effective) ||
                policy.strongEtag != representation.policy.strongEtag ||
                !policy.storable ||
                response.contentLength != end - start + 1 ||
                response.compressionState ==
                    HttpClientResponseCompressionState.decompressed) {
              _invalidate(key, representation);
              return null;
            }
            representation.policy = policy;
            final bytes = BytesBuilder(copy: false);
            final iterator = StreamIterator(response);
            producer.iterators.add(iterator);
            try {
              while (await _advance(iterator, producer)) {
                producer.check();
                _received(iterator.current.length);
                receivedThisAttempt += iterator.current.length;
                if (bytes.length + iterator.current.length > end - start + 1) {
                  throw const FormatException('Invalid range body');
                }
                bytes.add(iterator.current);
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
              if (attempt > 0) _recoveries++;
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
          await _backoff(attempt, started, producer, retryAfter: retryAfter);
          _recoveryAttempts++;
          _repeatedDownloadBytes += receivedThisAttempt;
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

  bool _canReadAhead(HttpRequest incoming, String key, _Representation? rep) {
    final storage = cache;
    if (readAheadBytes <= 0 ||
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
    return range != null && range.length >= 1024 * 1024;
  }

  Future<bool> _tryReadAhead(
    HttpRequest incoming,
    String key,
    Uri url,
    _ProxyRead read, {
    bool validated = false,
  }) async {
    final rep = _representations[key];
    if (rep == null || !_canReadAhead(incoming, key, rep)) return false;
    if (_readAhead?.resource == key && _readAhead!.failed) return false;
    if (!validated && !await _validate(incoming, key, url, rep, read)) {
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
          aheadBytes: min(readAheadBytes, cache!.diskSessionLimitBytes ~/ 2),
          reserveWorkspace: () {
            if (!_reserveCacheWorkspace(SessionReadAhead.blockBytes)) {
              return false;
            }
            _charge(SessionReadAhead.blockBytes);
            return true;
          },
          releaseWorkspace: () {
            _charge(-SessionReadAhead.blockBytes);
            _cacheWorkspace -= SessionReadAhead.blockBytes;
          },
          fetch: (start, end) async {
            final producer = _ProxyRead();
            Stream<List<int>> source() async* {
              var cursor = start;
              final started = DateTime.now();
              try {
                for (var attempt = 0; cursor <= end && attempt < 6; attempt++) {
                  producer.check();
                  try {
                    final (response, effective) = await _fetchOnce(
                      incoming,
                      url,
                      allowRange: true,
                      read: producer,
                      method: 'GET',
                      overrides: {
                        'range': 'bytes=$cursor-$end',
                        'if-range': rep.policy.strongEtag,
                        'if-none-match': null,
                        'if-modified-since': null,
                      },
                    );
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
                        throw StateError('Read-ahead recovery exhausted');
                      }
                      for (final request in producer.requests.toList()) {
                        request.abort();
                      }
                      await _backoff(
                        attempt,
                        started,
                        producer,
                        retryAfter: response.statusCode == 429
                            ? _retryAfter(response.headers.value('retry-after'))
                            : null,
                      );
                      _recoveryAttempts++;
                      continue;
                    }
                    if (_representations[key]?.generation != rep.generation ||
                        response.statusCode != 206 ||
                        range == null ||
                        range.start != cursor ||
                        range.end != end ||
                        range.total != rep.total ||
                        (!sessionBuffering && effective != rep.effective) ||
                        !policy.storable ||
                        policy.strongEtag != rep.policy.strongEtag ||
                        response.contentLength != end - cursor + 1 ||
                        response.compressionState ==
                            HttpClientResponseCompressionState.decompressed) {
                      _invalidate(key, rep);
                      throw const FormatException(
                        'Read-ahead representation changed',
                      );
                    }
                    rep.policy = policy;
                    await for (final bytes in response.timeout(
                      const Duration(seconds: 15),
                    )) {
                      producer.check();
                      if (_representations[key]?.generation != rep.generation ||
                          cursor + bytes.length > end + 1) {
                        _invalidate(key, rep);
                        throw const FormatException(
                          'Read-ahead representation changed',
                        );
                      }
                      _received(bytes.length);
                      cursor += bytes.length;
                      yield bytes;
                    }
                    if (cursor <= end) {
                      throw const HttpException('Truncated prefetch range');
                    }
                    if (attempt > 0) _recoveries++;
                  } on FormatException {
                    rethrow;
                  } on SocketException {
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  } on TimeoutException {
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  } on HttpException {
                    if (attempt == 5) {
                      _recoveryFailures++;
                      rethrow;
                    }
                    for (final request in producer.requests.toList()) {
                      request.abort();
                    }
                    await _backoff(attempt, started, producer);
                    _recoveryAttempts++;
                  }
                }
                if (cursor <= end) {
                  throw const HttpException('Read-ahead recovery exhausted');
                }
              } catch (_) {
                if (!producer.cancelled) _readAheadBypass.add(key);
                rethrow;
              } finally {
                producer.cancel();
              }
            }

            return ReadAheadTransfer(source(), producer.cancel);
          },
        );
        _readAhead = ahead;
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
        await for (final bytes in ahead!.read(range.start, range.end)) {
          read.check();
          read.outputStarted = true;
          yield bytes;
        }
      }

      try {
        return await _sendCachedBody(output, body());
      } catch (_) {
        if (!read.outputStarted && !read.cancelled) {
          _readAheadBypass.add(key);
          return false;
        }
        rethrow;
      }
    } finally {
      _charge(-512 * 1024);
      _cacheWorkspace -= 512 * 1024;
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
    if (!await _validate(incoming, key, url, representation, read)) {
      return false;
    }
    final rangeValue = incoming.headers.value('range');
    final range = MediaByteRange.resolve(rangeValue, representation.total);
    if (range == null) {
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

        return await _sendCachedBody(incoming.response, body());
      } finally {
        _charge(-64 * 1024);
        await lease.close();
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
      // Check the first known gap's validator before committing cached prefixes.
      // A later representation change aborts the incomplete HTTP response.
      prefetched = await _loadGap(
        incoming,
        key,
        url,
        representation,
        missing,
        end,
        read,
      );
      if (prefetched == null) return false;
    }
    final prefetchedLength = prefetched?.length ?? 0;
    _charge(prefetchedLength);
    try {
      Stream<List<int>> body() async* {
        while (position <= range.end) {
          read.check();
          final length = min(256 * 1024, range.end - position + 1);
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

      return await _sendCachedBody(incoming.response, body());
    } finally {
      _charge(-prefetchedLength);
    }
  }

  Future<bool> _sendCachedBody(
    HttpResponse output,
    Stream<List<int>> body,
  ) async {
    final chunks = StreamIterator(body);
    try {
      if (!await chunks.moveNext()) return false;
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
      final prefetch = incoming.headers.value('x-rillight-prefetch') == '1';
      if (!prefetch) {
        _cancelSegmentPrefetch();
      } else {
        _segmentPrefetchRead = read;
      }
      if (_active >= _maxRequests) {
        incoming.response.statusCode = HttpStatus.serviceUnavailable;
        await incoming.response.close();
        return;
      }
      _active++;
      acquired = true;
      await _serveResponse(incoming, read);
      served = true;
    } catch (_) {
      try {
        await incoming.response.close();
      } catch (_) {}
    } finally {
      final key = read.resourceKey;
      if (identical(_segmentPrefetchRead, read)) _segmentPrefetchRead = null;
      _reads.remove(read);
      read.cancel();
      if (acquired) _active--;
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
        _scheduleSegmentPrefetch(key);
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
      final url = route.url;
      read.resourceKey = key;
      if (!_roles.containsKey(key)) {
        while (_roles.length >= 256) {
          final oldest = _roles.keys.firstWhere(
            (candidate) => !_reads.any((r) => r.resourceKey == candidate),
          );
          _roles.remove(oldest);
          _readAheadBypass.remove(oldest);
          final previous = _representations[oldest];
          if (previous != null) _invalidate(oldest, previous);
        }
        _roles[key] = PlaybackResourceRole.values[route.role];
      }
      if (allowRange && await _tryReadAhead(incoming, key, url, read)) return;
      if (allowRange &&
          cache != null &&
          _reserveCacheWorkspace(_cachedResponseWorkspace)) {
        try {
          if (await _tryCached(incoming, key, url, read)) return;
        } finally {
          _cacheWorkspace -= _cachedResponseWorkspace;
        }
      }
      var (response, effective) = await _fetch(
        incoming,
        url,
        allowRange: allowRange,
        read: read,
      );
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
          );
          if (response.statusCode == HttpStatus.partialContent &&
              _canReadAhead(incoming, key, representation)) {
            // Metadata/sniffing is complete. Do not keep this unbounded probe
            // downloading beside the bounded range producer.
            for (final request in read.requests.toList()) {
              request.abort();
            }
            read.requests.clear();
            await chunks.cancel();
            if (await _tryReadAhead(
              incoming,
              key,
              url,
              read,
              validated: true,
            )) {
              return;
            }
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
              _stream == PlaybackCacheStream.stable ? 1024 * 1024 : 256 * 1024,
              max(64 * 1024, cache?.memoryLimitBytes ?? 0),
            ),
            representation == null
                ? 1
                : representation.responseEnd - representation.responseStart + 1,
          );
          final assemblyReserved =
              representation != null && _reserveCacheWorkspace(blockSize);
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

          Stream<List<int>> forward(List<int> bytes) async* {
            // A socket chunk is never accumulated into a whole media response.
            for (var start = 0; start < bytes.length; start += 64 * 1024) {
              read.check();
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
                if (assembly != null &&
                    representation != null &&
                    identical(_representations[key], representation)) {
                  retain(part);
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
              yield* forward(prefixBytes);
              var iterator = chunks;
              var resumeAttempts = 0;
              DateTime? recoveryStarted;
              var awaitingRecoveredByte = false;
              try {
                while (true) {
                  bool advanced;
                  var interrupted = false;
                  if (prefixInterrupted) {
                    prefixInterrupted = false;
                    advanced = false;
                    interrupted = true;
                  } else {
                    try {
                      advanced = await _advance(iterator, read);
                    } catch (_) {
                      read.check();
                      // The original length and strong validator let us request
                      // only the undelivered suffix after a broken body stream.
                      advanced = false;
                      interrupted = true;
                    }
                  }
                  if (advanced) {
                    read.check();
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
                  read.iterators.remove(iterator);
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
                        read,
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
                        read: read,
                        overrides: {
                          'range': 'bytes=${bodyStart + received}-$bodyEnd',
                          'if-range': bodyEtag,
                          'if-none-match': null,
                          'if-modified-since': null,
                        },
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
                        retryAfter = candidate.statusCode == 429
                            ? _retryAfter(
                                candidate.headers.value('retry-after'),
                              )
                            : null;
                        for (final request in read.requests.toList()) {
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
                  iterator = StreamIterator<List<int>>(resumed);
                  read.iterators.add(iterator);
                  awaitingRecoveredByte = true;
                }
              } finally {
                if (!identical(iterator, chunks)) {
                  read.iterators.remove(iterator);
                  await iterator.cancel();
                }
              }
            }

            // One bound stream propagates downstream cancellation upstream.
            // Repeated add/flush calls can silently succeed after dart:io has
            // swallowed a broken-pipe error, draining an abandoned movie.
            await output.addStream(body());
            if (bodyLength > 0 && received != bodyLength) {
              throw const HttpException('Truncated media representation');
            }
            complete = true;
            if (representation != null) {
              if (assembled > 0 &&
                  identical(_representations[key], representation)) {
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
            if (assemblyReserved) {
              _charge(-blockSize);
              _cacheWorkspace -= blockSize;
            }
            if (!complete &&
                representation != null &&
                representation.policy.strongEtag == null) {
              _invalidate(key, representation);
            }
          }
        }
      } finally {
        read.iterators.remove(chunks);
        await chunks.cancel();
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
    Uri effective,
  ) {
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
      final previous = _representations[key];
      if (previous != null) _invalidate(key, previous);
      return null;
    }
    final total = contentRange?.total ?? response.contentLength;
    final requested = MediaByteRange.resolve(
      incoming.headers.value('range'),
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
    if (previous != null && !same) _invalidate(key, previous);
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
      if (previous != null) _invalidate(key, previous);
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
    _representations[key] = representation;
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
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        read.check();
        final rewritten = rewrite(line);
        if (timelineText != null) {
          timelineTextBytes += utf8.encode(rewritten).length + 1;
          if (timelineTextBytes <= 128 * 1024) {
            timelineText.write('$rewritten\n');
          } else {
            timelineText = null;
          }
        }
        read.outputStarted = true;
        output.add(utf8.encode('$rewritten\n'));
        await output.flush();
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
    } finally {
      _charge(-512 * 1024);
      _cacheWorkspace -= 512 * 1024;
    }
  }

  void _replaceHlsIndex(String parent, Map<String, _HlsNext> next) {
    _pendingSegmentPrefetch.remove(parent);
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
    await _segmentPrefetch;
    await _readAhead?.close();
    for (final load in _loads.values) {
      load.producer.cancel();
    }
    _client.close(force: true);
    await _server.close(force: true);
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
}

class _ProxyRead {
  _ProxyRead({this.seekGeneration = 0});
  final int seekGeneration;
  String? resourceKey;
  bool cancelled = false;
  bool outputStarted = false;
  final requests = <HttpClientRequest>{};
  final iterators = <StreamIterator<List<int>>>{};
  final _cancelled = Completer<void>();
  Future<void> get cancelledFuture => _cancelled.future;
  void check() {
    if (cancelled) throw const HttpException('Media read cancelled');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
    for (final request in requests) {
      request.abort();
    }
    for (final iterator in iterators.toList()) {
      unawaited(iterator.cancel());
    }
  }
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
