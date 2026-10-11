import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:rillight/media_server/resources.dart';

import 'cache_limits.dart';

/// One bounded response from the next episode's existing stream URL.
class NextPrefixSlice {
  const NextPrefixSlice(
    this.bytes, {
    this.rangeSupported = true,
    this.etag,
    this.totalBytes,
  });

  final Uint8List bytes;

  /// False when the server ignored the range and the prefix must be dropped.
  final bool rangeSupported;
  final String? etag;
  final int? totalBytes;
}

typedef NextPrefixFetch =
    Future<NextPrefixSlice?> Function({
      required Uri url,
      required Map<String, String> headers,
      required int start,
      required int endInclusive,
    });

/// Holds at most [maxBytes] of the next episode in memory until the current
/// transport is asked to play that item. It does not open a second disk session.
class NextEpisodePrefix {
  NextEpisodePrefix({NextPrefixFetch? fetch})
    : fetch = fetch ?? fetchNextPrefixSlice,
      _usesDefaultFetch = fetch == null;

  static const maxBytes = 32 * 1024 * 1024;

  final NextPrefixFetch fetch;
  final bool _usesDefaultFetch;
  HttpClient? _activeClient;
  final _chunks = <Uint8List>[];
  int storedBytes = 0;
  String? itemId;
  String? etag;
  int? totalBytes;
  Uint8List? _joined;
  int _ticket = 0;

  Uint8List? get bytes {
    if (itemId == null || storedBytes == 0) return null;
    final joined = _joined;
    if (joined != null && joined.length == storedBytes) return joined;
    final out = Uint8List(storedBytes);
    var offset = 0;
    for (final chunk in _chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return _joined = out;
  }

  Future<void> start({
    required String itemId,
    required Uri url,
    Map<String, String> headers = const {},
    ResourceAuthorization? authorization,
    required bool Function() yieldToForeground,
  }) async {
    final ticket = ++_ticket;
    _activeClient?.close(force: true);
    _activeClient = null;
    _clear();
    if (ticket != _ticket) return;
    this.itemId = itemId;
    final auth = authorization ?? _prefixAuthorization(url, headers);
    var offset = 0;
    while (offset < maxBytes && ticket == _ticket) {
      while (ticket == _ticket && yieldToForeground()) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (ticket != _ticket) return;
      final endInclusive = min(offset + maxCacheBlockBytes, maxBytes) - 1;
      final requested = endInclusive - offset + 1;
      NextPrefixSlice? slice;
      final client = _usesDefaultFetch ? HttpClient() : null;
      _activeClient = client;
      try {
        if (client != null) {
          slice = await fetchNextPrefixSlice(
            url: url,
            headers: headers,
            authorization: auth,
            start: offset,
            endInclusive: endInclusive,
            client: client,
            isCurrent: () => ticket == _ticket,
          );
        } else {
          final target = auth.sanitizeUri(url);
          slice = await fetch(
            url: target,
            headers: auth.headersFor(target),
            start: offset,
            endInclusive: endInclusive,
          );
        }
      } catch (_) {
        if (ticket == _ticket) _clear();
        return;
      } finally {
        client?.close(force: true);
        if (identical(_activeClient, client)) _activeClient = null;
      }
      if (ticket != _ticket) return;
      if (slice == null ||
          !slice.rangeSupported ||
          slice.etag == null ||
          !slice.etag!.startsWith('"') ||
          !slice.etag!.endsWith('"') ||
          slice.totalBytes == null ||
          offset + slice.bytes.length > slice.totalBytes! ||
          (etag != null &&
              (etag != slice.etag || totalBytes != slice.totalBytes)) ||
          slice.bytes.isEmpty ||
          slice.bytes.length > requested) {
        _clear();
        return;
      }
      etag = slice.etag;
      totalBytes = slice.totalBytes;
      _chunks.add(slice.bytes);
      storedBytes += slice.bytes.length;
      _joined = null;
      offset += slice.bytes.length;
      if (offset == totalBytes) return;
      if (slice.bytes.length < requested) return;
    }
  }

  Future<Uint8List?> readStored() async => bytes;

  Future<void> discard() async {
    _ticket++;
    _activeClient?.close(force: true);
    _activeClient = null;
    _clear();
  }

  void _clear() {
    itemId = null;
    etag = null;
    totalBytes = null;
    storedBytes = 0;
    _chunks.clear();
    _joined = null;
  }
}

ResourceAuthorization _prefixAuthorization(
  Uri url,
  Map<String, String> headers,
) => ResourceAuthorization(
  headersByOrigin: {url.origin: headers},
  publicHeaders: {
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() == 'user-agent') entry.key: entry.value,
  },
);

Future<NextPrefixSlice?> fetchNextPrefixSlice({
  required Uri url,
  required Map<String, String> headers,
  ResourceAuthorization? authorization,
  required int start,
  required int endInclusive,
  HttpClient? client,
  bool Function()? isCurrent,
}) async {
  final wanted = endInclusive - start + 1;
  if (start < 0 || wanted <= 0 || wanted > maxCacheBlockBytes) {
    throw ArgumentError('Invalid next-episode prefix range');
  }
  void checkCurrent() {
    if (isCurrent?.call() == false) {
      throw StateError('Next-episode prefix cancelled');
    }
  }

  checkCurrent();
  final auth = authorization ?? _prefixAuthorization(url, headers);
  final owned = client ?? HttpClient();
  owned.connectionTimeout = const Duration(seconds: 2);
  HttpClientRequest? pending;
  try {
    var target = url;
    for (var hop = 0; hop <= 5; hop++) {
      checkCurrent();
      if (!{'http', 'https'}.contains(target.scheme) ||
          target.userInfo.isNotEmpty ||
          target.toString().length > 16384) {
        throw StateError('Unsupported next-episode prefix URL');
      }
      target = auth.sanitizeUri(target);
      final opening = owned.getUrl(target);
      pending = await opening.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          unawaited(
            opening.then<void>((late) => late.abort(), onError: (Object _) {}),
          );
          throw const HttpException('Next-episode prefix connection timed out');
        },
      );
      checkCurrent();
      pending.followRedirects = false;
      for (final header in auth.headersFor(target).entries) {
        pending.headers.set(header.key, header.value);
      }
      pending.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-$endInclusive',
      );
      pending.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await pending.close().timeout(
        const Duration(seconds: 8),
      );
      if (isCurrent?.call() == false) {
        await response.listen((_) {}).cancel();
        checkCurrent();
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || hop == 5) {
          throw StateError('Invalid next-episode prefix redirect');
        }
        target = target.resolve(location);
        continue;
      }
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      final rangeStart = range == null ? null : int.tryParse(range[1]!);
      final rangeEnd = range == null ? null : int.tryParse(range[2]!);
      final total = range == null ? null : int.tryParse(range[3]!);
      final etag = response.headers.value('etag');
      if (response.statusCode != HttpStatus.partialContent ||
          rangeStart != start ||
          rangeEnd == null ||
          total == null ||
          rangeEnd >= total ||
          response.compressionState ==
              HttpClientResponseCompressionState.decompressed ||
          rangeEnd < start ||
          rangeEnd > endInclusive) {
        await response.listen((_) {}).cancel();
        return NextPrefixSlice(Uint8List(0), rangeSupported: false);
      }
      final expected = rangeEnd - start + 1;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        checkCurrent();
        if (chunk.length > expected - builder.length) {
          return NextPrefixSlice(Uint8List(0), rangeSupported: false);
        }
        builder.add(chunk);
      }
      checkCurrent();
      if (builder.length != expected) {
        return NextPrefixSlice(Uint8List(0), rangeSupported: false);
      }
      return NextPrefixSlice(
        builder.takeBytes(),
        etag: etag != null && etag.startsWith('"') && etag.endsWith('"')
            ? etag
            : null,
        totalBytes: total,
      );
    }
    throw StateError('Too many next-episode prefix redirects');
  } finally {
    pending?.abort();
    if (client == null) owned.close(force: true);
  }
}
