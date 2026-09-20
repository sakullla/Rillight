import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cache/http_cache_policy.dart';
import 'cache/session_byte_cache.dart';
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

/// A per-session loopback transport. mpv never receives Emby credentials;
/// every redirect, HLS child resource and subtitle is authorized separately.
class PlaybackHttpProxy {
  PlaybackHttpProxy._(
    this._server,
    this.origin,
    this.headers,
    this.cache,
    this.dynamicSource,
    this.onStreamChanged,
  ) : _secret = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join() {
    _client.autoUncompress = true;
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
  final FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged;
  final _routes = SealedMediaRoutes();
  final _roles = <String, PlaybackResourceRole>{};
  final _representations = <String, _Representation>{};
  final _reads = <_ProxyRead>{};
  final _loads = <String, _SharedLoad>{};
  final _slots = <Completer<void>>[];
  final _writes = <Future<bool>>{};
  int _active = 0;
  int _nextRepresentation = 0;
  int _upstreamBytes = 0;
  int _cancelled = 0;
  int _inFlight = 0;
  int _inFlightPeak = 0;
  final _samples = <(DateTime, int)>[];
  PlaybackCacheStream _stream = PlaybackCacheStream.conservative;
  bool _closed = false;

  int get upstreamBytes => _upstreamBytes;
  PlaybackCacheStream get stream => _stream;
  double get upstreamBytesPerSecond {
    _pruneSamples();
    return _samples.fold<int>(0, (sum, sample) => sum + sample.$2).toDouble();
  }

  Map<String, Object?> get diagnostics => {
    ...?cache?.diagnostics,
    'upstreamBytes': _upstreamBytes,
    'cancelledReads': _cancelled,
    'proxyInFlightBytes': _inFlight,
    'proxyInFlightPeakBytes': _inFlightPeak,
    'registeredResources': _roles.length,
    'registryBudgetBytes': _roles.length * 4096,
    'streamPolicy': _stream.name,
  };

  static Future<PlaybackHttpProxy> create({
    Uri? origin,
    Map<String, String> headers = const {},
    SessionByteCache? cache,
    bool dynamicSource = false,
    FutureOr<void> Function(PlaybackCacheStream)? onStreamChanged,
  }) async => PlaybackHttpProxy._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    origin,
    Map.unmodifiable(headers),
    cache,
    dynamicSource,
    onStreamChanged,
  );

  Uri register(
    Uri url, {
    PlaybackResourceRole role = PlaybackResourceRole.media,
    String context = '',
  }) {
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
    for (var redirects = 0; redirects <= 10; redirects++) {
      read.check();
      url = _withoutForeignCredentials(url);
      final request = await _client.openUrl(method ?? incoming.method, url);
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

  void _received(int count) {
    _upstreamBytes += count;
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

  Future<void> _discard(HttpClientResponse response, _ProxyRead read) async {
    final iterator = StreamIterator(response);
    read.iterators.add(iterator);
    try {
      while (await iterator.moveNext()) {
        read.check();
        _received(iterator.current.length);
      }
    } finally {
      read.iterators.remove(iterator);
      await iterator.cancel();
    }
  }

  /// The backend calls this before seek. Published representation bytes survive;
  /// outstanding consumers and the last consumer's upstream work do not.
  void cancelPendingReads() {
    for (final read in _reads.toList()) {
      if (!read.cancelled) {
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
    final newPolicy = MediaCachePolicy(response.headers);
    final valid =
        effective == representation.effective &&
        newPolicy.storable &&
        (response.statusCode == 304 &&
                (newPolicy.etag == null || newPolicy.etag == etag) ||
            response.statusCode == 200 &&
                etag != null &&
                newPolicy.strongEtag == representation.policy.strongEtag &&
                newPolicy.strongEtag != null &&
                response.contentLength == representation.total);
    if (!valid) {
      _invalidate(key, representation);
      return false;
    }
    if (response.headers.value('cache-control') != null) {
      representation.policy = newPolicy;
    }
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
        final (response, effective) = await _fetch(
          incoming,
          url,
          read: producer,
          overrides: {
            'range': 'bytes=$start-$end',
            'if-range': representation.policy.strongEtag,
            'if-none-match': null,
            'if-modified-since': null,
          },
        );
        final range = MediaContentRange.parse(
          response.headers.value('content-range'),
        );
        final policy = MediaCachePolicy(response.headers);
        if (response.statusCode != 206 ||
            range == null ||
            range.start != start ||
            range.end != end ||
            range.total != representation.total ||
            effective != representation.effective ||
            policy.strongEtag != representation.policy.strongEtag ||
            !policy.storable ||
            response.contentLength != end - start + 1 ||
            response.compressionState ==
                HttpClientResponseCompressionState.decompressed) {
          producer.cancel();
          _invalidate(key, representation);
          return null;
        }
        // A validator identifies bytes, not their current reuse policy. Apply
        // the latest response's freshness/Vary constraints even for the same
        // strong ETag before publishing any newly downloaded interval.
        representation.policy = policy;
        final bytes = BytesBuilder(copy: false);
        final iterator = StreamIterator(response);
        producer.iterators.add(iterator);
        try {
          while (await iterator.moveNext()) {
            producer.check();
            _received(iterator.current.length);
            if (bytes.length + iterator.current.length > end - start + 1) {
              throw const HttpException('Invalid range body');
            }
            bytes.add(iterator.current);
          }
          producer.check();
          if (bytes.length != end - start + 1 ||
              !identical(_representations[key], representation)) {
            return null;
          }
          final body = bytes.takeBytes();
          _store(key, representation, start, body);
          producer.check();
          return body;
        } finally {
          producer.iterators.remove(iterator);
          await iterator.cancel();
        }
      })();
      return shared;
    });
    load.consumers++;
    // At most two consumers, each working on <=256 KiB, plus the storage's
    // separately bounded pending budget. The reservation includes assembly copy.
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
        var position = range.start;
        while (position <= range.end) {
          final hit = await lease.read(
            position,
            maxLength: min(64 * 1024, range.end - position + 1),
          );
          read.check();
          if (hit == null) {
            if (!read.outputStarted) return false;
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
          incoming.response.add(hit.bytes);
          await incoming.response.flush();
          position += hit.bytes.length;
        }
        return true;
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
              return false;
            }
            if (representation.policy.strongEtag == null) {
              if (!sent) return false;
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
              if (!sent) return false;
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
          incoming.response.add(bytes);
          await incoming.response.flush();
          sent = true;
          position += bytes.length;
        } finally {
          _charge(-length);
        }
      }
      return true;
    } finally {
      _charge(-prefetchedLength);
    }
  }

  Future<void> _serve(HttpRequest incoming) async {
    final read = _ProxyRead();
    _reads.add(read);
    unawaited(
      incoming.response.done.then(
        (_) => read.cancel(),
        onError: (Object _) {
          read.cancel();
        },
      ),
    );
    Completer<void>? slot;
    var acquired = false;
    try {
      if (_active >= 2) {
        if (_slots.length >= 16) {
          incoming.response.statusCode = 503;
          await incoming.response.close();
          return;
        }
        slot = Completer<void>();
        _slots.add(slot);
        await Future.any([slot.future, read.cancelledFuture]);
        read.check();
      } else {
        _active++;
      }
      acquired = true;
      await _serveResponse(incoming, read);
    } catch (_) {
      try {
        await incoming.response.close();
      } catch (_) {}
    } finally {
      if (slot != null) _slots.remove(slot);
      _reads.remove(read);
      read.cancel();
      if (acquired || slot?.isCompleted == true) {
        if (_slots.isEmpty) {
          _active--;
        } else {
          _slots.removeAt(0).complete();
        }
      }
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
          final previous = _representations[oldest];
          if (previous != null) _invalidate(oldest, previous);
        }
        _roles[key] = PlaybackResourceRole.values[route.role];
      }
      if (allowRange && await _tryCached(incoming, key, url, read)) return;
      final (response, effective) = await _fetch(
        incoming,
        url,
        allowRange: allowRange,
        read: read,
      );
      output.statusCode = response.statusCode;
      for (final name in [
        'content-type',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        output.headers.removeAll(name);
        final value = response.headers.value(name);
        if (value != null) output.headers.set(name, value);
      }
      if (incoming.method == 'HEAD') {
        output.contentLength = response.contentLength;
        await _discard(response, read);
        return;
      }
      final chunks = StreamIterator<List<int>>(response);
      read.iterators.add(chunks);
      try {
        final prefixBytes = <int>[];
        while (prefixBytes.length < 8 && await chunks.moveNext()) {
          read.check();
          _received(chunks.current.length);
          prefixBytes.addAll(chunks.current);
        }
        final contentType = response.headers.contentType?.mimeType ?? '';
        final playlist =
            effective.path.toLowerCase().endsWith('.m3u8') ||
            contentType.contains('mpegurl') ||
            ascii.decode(prefixBytes.take(7).toList(), allowInvalid: true) ==
                '#EXTM3U';
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
              if (!await chunks.moveNext()) break;
              bytes = chunks.current;
              _received(bytes.length);
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
          Uint8List? assembly = representation == null
              ? null
              : Uint8List(blockSize);
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

          Future<void> forward(List<int> bytes) async {
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
                if (representation != null &&
                    identical(_representations[key], representation)) {
                  retain(part);
                }
                read.outputStarted = true;
                output.add(part);
                await output.flush();
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
            await forward(prefixBytes);
            while (await chunks.moveNext()) {
              read.check();
              _received(chunks.current.length);
              await forward(chunks.current);
            }
            if (representation != null &&
                received !=
                    representation.responseEnd -
                        representation.responseStart +
                        1) {
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
            if (assembly != null) _charge(-blockSize);
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
    final policy = MediaCachePolicy(response.headers);
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
        previous.effective == effective &&
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
    var playlistNext = false;
    String child(Uri url, PlaybackResourceRole role, String context) {
      final result = register(url, role: role, context: context);
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
      if (trimmed == '#EXT-X-DISCONTINUITY') discontinuity++;
      if (trimmed.startsWith('#EXT-X-KEY:')) keyContext = trimmed;
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
    _charge(512 * 1024);
    try {
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        read.check();
        final rewritten = rewrite(line);
        read.outputStarted = true;
        output.add(utf8.encode('$rewritten\n'));
        await output.flush();
      }
      await _classify(
        stable && !master
            ? PlaybackCacheStream.stable
            : PlaybackCacheStream.conservative,
      );
    } finally {
      _charge(-512 * 1024);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancelPendingReads();
    for (final load in _loads.values) {
      load.producer.cancel();
    }
    _client.close(force: true);
    await _server.close(force: true);
    await cache?.close();
    await Future.wait(_writes.toList());
    _routes.close();
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
  });
  final int generation;
  MediaCachePolicy policy;
  final int total;
  final Uri effective;
  final Map<String, String> headers;
  final int responseStart;
  final int responseEnd;
  bool complete = false;
}

class _ProxyRead {
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
