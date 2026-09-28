import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cache_limits.dart';

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

/// Holds at most [maxBytes] of the next episode in memory until the current
/// transport is asked to play that item. It does not open a second disk session.
class NextEpisodePrefix {
  NextEpisodePrefix({NextPrefixFetch? fetch})
    : fetch = fetch ?? fetchNextPrefixSlice;

  static const maxBytes = 32 * 1024 * 1024;

  final NextPrefixFetch fetch;
  final _chunks = <Uint8List>[];
  int storedBytes = 0;
  String? itemId;
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
    required bool Function() yieldToForeground,
  }) async {
    final ticket = ++_ticket;
    _clear();
    if (ticket != _ticket) return;
    this.itemId = itemId;
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
        if (ticket == _ticket) _clear();
        return;
      }
      if (ticket != _ticket) return;
      if (slice == null || !slice.rangeSupported || slice.bytes.isEmpty) {
        _clear();
        return;
      }
      _chunks.add(slice.bytes);
      storedBytes += slice.bytes.length;
      _joined = null;
      offset += slice.bytes.length;
      if (slice.bytes.length < requested) return;
    }
  }

  Future<Uint8List?> readStored() async => bytes;

  Future<void> discard() async {
    _ticket++;
    _clear();
  }

  void _clear() {
    itemId = null;
    storedBytes = 0;
    _chunks.clear();
    _joined = null;
  }
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
