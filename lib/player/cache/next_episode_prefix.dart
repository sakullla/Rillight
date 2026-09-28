import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cache_limits.dart';
import 'session_byte_cache.dart';

/// One bounded response from the next episode's existing stream URL.
class NextPrefixSlice {
  const NextPrefixSlice(this.bytes, {this.rangeSupported = true});

  final Uint8List bytes;

  /// False when the server ignored the range and the prefix must be dropped.
  final bool rangeSupported;
}

typedef NextPrefixFetch =
    Future<NextPrefixSlice?> Function({
      required Uri url,
      required Map<String, String> headers,
      required int start,
      required int endInclusive,
    });

/// Fetches at most [NextEpisodePrefix.maxBytes] of one next episode into the
/// current session cache, under that episode's own resource key.
class NextEpisodePrefix {
  NextEpisodePrefix({required this.cache, NextPrefixFetch? fetch})
    : fetch = fetch ?? fetchNextPrefixSlice;

  static const maxBytes = 32 * 1024 * 1024;

  final SessionByteCache cache;
  final NextPrefixFetch fetch;
  int storedBytes = 0;
  String? itemId;
  int _ticket = 0;
  HttpClient? _client;

  static String resourceFor(String itemId) {
    final bounded = itemId.length > 240 ? itemId.substring(0, 240) : itemId;
    return 'next-prefix:$bounded';
  }

  Future<void> start({
    required String itemId,
    required Uri url,
    Map<String, String> headers = const {},
    required bool Function() yieldToForeground,
  }) async {
    final ticket = ++_ticket;
    await _drop(itemId: this.itemId, ticket: ticket);
    if (ticket != _ticket) return;
    this.itemId = itemId;
    storedBytes = 0;
    final resource = resourceFor(itemId);
    var offset = 0;
    while (offset < maxBytes && ticket == _ticket) {
      while (ticket == _ticket && yieldToForeground()) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (ticket != _ticket) return;
      final endInclusive = min(offset + maxCacheBlockBytes, maxBytes) - 1;
      final requested = endInclusive - offset + 1;
      NextPrefixSlice? slice;
      try {
        slice = await fetch(
          url: url,
          headers: headers,
          start: offset,
          endInclusive: endInclusive,
        );
      } catch (_) {
        if (ticket == _ticket) await discard();
        return;
      }
      if (ticket != _ticket) return;
      if (slice == null || !slice.rangeSupported || slice.bytes.isEmpty) {
        await discard();
        return;
      }
      final stored = await cache.putPreservingReadable(
        resource: resource,
        generation: 1,
        offset: offset,
        bytes: slice.bytes,
      );
      if (!stored || ticket != _ticket) return;
      storedBytes += slice.bytes.length;
      offset += slice.bytes.length;
      if (slice.bytes.length < requested) return;
    }
  }

  Future<Uint8List?> readStored() async {
    final id = itemId;
    if (id == null || storedBytes == 0) return null;
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < storedBytes) {
      final hit = await cache.read(
        resource: resourceFor(id),
        generation: 1,
        offset: offset,
      );
      if (hit == null || hit.bytes.isEmpty) return null;
      builder.add(hit.bytes);
      offset += hit.bytes.length;
    }
    return builder.takeBytes();
  }

  Future<void> discard() async {
    final ticket = ++_ticket;
    final id = itemId;
    itemId = null;
    storedBytes = 0;
    await _drop(itemId: id, ticket: ticket);
  }

  Future<void> _drop({required String? itemId, required int ticket}) async {
    _client?.close(force: true);
    _client = null;
    if (itemId == null) return;
    await cache.discardResource(resourceFor(itemId));
    if (ticket != _ticket) return;
  }

  HttpClient openClient() => _client = HttpClient();
}

Future<NextPrefixSlice?> fetchNextPrefixSlice({
  required Uri url,
  required Map<String, String> headers,
  required int start,
  required int endInclusive,
  HttpClient? client,
}) async {
  final owned = client ?? HttpClient();
  owned.connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await owned.getUrl(url).timeout(const Duration(seconds: 2));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endInclusive');
    for (final header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      return NextPrefixSlice(Uint8List(0), rangeSupported: false);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 8))) {
      builder.add(chunk);
      if (builder.length > endInclusive - start + 1) break;
    }
    final bytes = builder.takeBytes();
    final wanted = endInclusive - start + 1;
    if (bytes.length > wanted) {
      return NextPrefixSlice(Uint8List.sublistView(bytes, 0, wanted));
    }
    return NextPrefixSlice(bytes);
  } finally {
    if (client == null) owned.close(force: true);
  }
}
