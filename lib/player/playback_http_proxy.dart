import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A per-session loopback transport. mpv never receives Emby credentials;
/// every redirect, HLS child resource and subtitle is authorized separately.
class PlaybackHttpProxy {
  PlaybackHttpProxy._(this._server, this.origin, this.headers)
    : _secret = List.generate(
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
  final _urls = <String, Uri>{};
  final _ids = <Uri, String>{};
  bool _closed = false;

  static Future<PlaybackHttpProxy> create({
    Uri? origin,
    Map<String, String> headers = const {},
  }) async => PlaybackHttpProxy._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    origin,
    Map.unmodifiable(headers),
  );

  Uri register(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw ArgumentError('Only HTTP(S) media resources are allowed');
    }
    final id = _ids.putIfAbsent(url, () {
      final suffix = url.path.split('/').last;
      final id = '${_urls.length}/${Uri.encodeComponent(suffix)}';
      _urls[id] = url;
      return id;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}/$_secret/$id');
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
  }) async {
    for (var redirects = 0; redirects <= 10; redirects++) {
      if (_closed) throw StateError('Media session closed');
      url = _withoutForeignCredentials(url);
      final request = await _client.openUrl(incoming.method, url);
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
        final value = incoming.headers.value(name);
        if (value != null) request.headers.set(name, value);
      }
      for (final header in headers.entries) {
        if (header.key.toLowerCase() == 'user-agent' ||
            (origin != null && url.origin == origin!.origin)) {
          request.headers.set(header.key, header.value);
        }
      }
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        await response.drain<void>();
        final next = url.resolve(location);
        if (next.scheme != 'http' && next.scheme != 'https') {
          throw StateError('Unsupported media redirect');
        }
        url = next;
        continue;
      }
      return (response, url);
    }
    throw StateError('Too many media redirects');
  }

  Future<void> _serve(HttpRequest incoming, {bool allowRange = true}) async {
    final output = incoming.response;
    try {
      final prefix = '/$_secret/';
      final key = incoming.uri.path.startsWith(prefix)
          ? incoming.uri.path.substring(prefix.length)
          : '';
      // URI.path is decoded; generated keys may retain escaped filename chars.
      final url =
          _urls[key] ??
          _urls.entries
              .where((e) => Uri.decodeComponent(e.key) == key)
              .map((e) => e.value)
              .firstOrNull;
      if (_closed ||
          url == null ||
          !['GET', 'HEAD'].contains(incoming.method)) {
        output.statusCode = HttpStatus.notFound;
        return;
      }
      final (response, effective) = await _fetch(
        incoming,
        url,
        allowRange: allowRange,
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
        await response.drain<void>();
        return;
      }
      final chunks = StreamIterator<List<int>>(response);
      try {
        final prefixBytes = <int>[];
        while (prefixBytes.length < 8 && await chunks.moveNext()) {
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
              await _serve(incoming, allowRange: false);
              return;
            }
            rangeTotal = int.parse(range[2]!);
          }
          final bytes = <int>[...prefixBytes];
          while (await chunks.moveNext()) {
            bytes.addAll(chunks.current);
            if (bytes.length > 4 * 1024 * 1024) {
              throw StateError('Media playlist is too large');
            }
          }
          if (rangeTotal != null && bytes.length != rangeTotal) {
            throw StateError('Truncated HLS manifest');
          }
          final rewritten = _playlist(utf8.decode(bytes), effective);
          final body = utf8.encode(rewritten);
          output.statusCode = HttpStatus.ok;
          output.headers.removeAll('content-range');
          output.headers.set('accept-ranges', 'none');
          output.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          output.contentLength = body.length;
          output.add(body);
        } else {
          output.contentLength =
              response.compressionState ==
                  HttpClientResponseCompressionState.decompressed
              ? -1
              : response.contentLength;
          output.add(prefixBytes);
          while (await chunks.moveNext()) {
            output.add(chunks.current);
            await output.flush();
          }
        }
      } finally {
        await chunks.cancel();
      }
    } catch (_) {
      // Do not expose upstream URLs/credentials in player errors or logs.
      try {
        output.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      try {
        await output.close();
      } catch (_) {}
    }
  }

  String _playlist(String text, Uri base) => text
      .split('\n')
      .map((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return line;
        if (!trimmed.startsWith('#')) {
          return register(base.resolve(trimmed)).toString();
        }
        return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (match) {
          return 'URI="${register(base.resolve(match[1]!))}"';
        });
      })
      .join('\n');

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    await _server.close(force: true);
    _urls.clear();
    _ids.clear();
  }
}
