import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

import 'mp4_fixture.dart';

void main() {
  test('VOD fMP4 HLS exposes only fully verified cached segments', () async {
    final diskRoot = await Directory.systemTemp.createTemp('rillight-hls-crc-');
    final fixture = fragmentedMp4Fixture();
    final init = Uint8List.sublistView(
      fixture.bytes,
      0,
      fixture.firstMoofStart,
    );
    final first = Uint8List.sublistView(
      fixture.bytes,
      fixture.firstMoofStart,
      fixture.firstFragmentEnd,
    );
    final second = Uint8List.sublistView(
      fixture.bytes,
      fixture.firstFragmentEnd,
    );
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(
      root: diskRoot,
      memoryLimitBytes: 0,
      diskLimitBytes: 16 * 1024 * 1024,
    );
    final proxy = await PlaybackHttpProxy.create(
      origin: Uri.parse('http://127.0.0.1:${upstream.port}'),
      cache: cache,
      sessionBuffering: true,
      readAheadBytes: 0,
    );
    final client = HttpClient();
    upstream.listen((request) async {
      final path = request.uri.path;
      final bytes = switch (path) {
        '/init.mp4' => init,
        '/seg0.m4s' => first,
        '/seg1.m4s' => second,
        _ => null,
      };
      request.response.headers.set('cache-control', 'public,max-age=300');
      request.response.headers.set('etag', '"$path"');
      if (path == '/index.m3u8') {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2,
seg0.m4s
#EXTINF:2,
seg1.m4s
#EXT-X-ENDLIST
''');
      } else if (bytes != null) {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });

    Future<String> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, 200);
      return utf8.decode(
        await response.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        allowMalformed: true,
      );
    }

    List<(int, int)> timeline() =>
        (proxy.diagnostics['cachedTimeRanges'] as List).map((item) {
          final map = item as Map;
          return (map['startMs'] as int, map['endMs'] as int);
        }).toList();

    try {
      final playlist = await get(
        proxy.register(
          Uri.parse('http://127.0.0.1:${upstream.port}/index.m3u8'),
        ),
      );
      final map = Uri.parse(RegExp('URI="([^"]+)"').firstMatch(playlist)![1]!);
      final segments = playlist
          .split('\n')
          .where((line) => line.startsWith('http://'))
          .map(Uri.parse)
          .toList();
      expect(segments, hasLength(2));

      await get(segments[0]);
      await _waitFor(() => proxy.diagnostics['hlsActivePlaylists'] == 1);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), isEmpty);
      expect(proxy.diagnostics['timelineUnknownReason'], isNotNull);

      await get(map);
      await _waitFor(() => cache.diagnostics['pendingBytes'] == 0);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(
        timeline(),
        anyOf(equals([(0, 2000)]), equals([(0, 4000)])),
        reason: proxy.diagnostics.toString(),
      );
      expect(proxy.diagnostics['timelineUnknownReason'], isNull);

      await get(segments[1]);
      await _waitFor(() => cache.diagnostics['pendingBytes'] == 0);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), [(0, 4000)]);

      final firstBlock = diskRoot
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.block'))
          .firstWhere((file) {
            final bytes = file.readAsBytesSync();
            if (bytes.length != first.length) return false;
            for (var i = 0; i < bytes.length; i++) {
              if (bytes[i] != first[i]) return false;
            }
            return true;
          });
      final damaged = await firstBlock.readAsBytes();
      damaged[0] ^= 0xff;
      await firstBlock.writeAsBytes(damaged, flush: true);
      await firstBlock.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), isEmpty);

      await cache.resize(
        memoryBytes: 0,
        pendingBytes: 1024 * 1024,
        diskBytes: 0,
      );
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), isEmpty);
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
      await diskRoot.delete(recursive: true);
    }
  });

  test('separate HLS audio must be selected and cached', () async {
    final video = fragmentedMp4Fixture(includeAudio: false);
    final audio = fragmentedMp4Fixture(includeVideo: false);
    final bodies = <String, Uint8List>{};
    void addFixture(String prefix, FragmentedMp4Fixture fixture) {
      bodies['/$prefix/init.mp4'] = Uint8List.sublistView(
        fixture.bytes,
        0,
        fixture.firstMoofStart,
      );
      bodies['/$prefix/seg0.m4s'] = Uint8List.sublistView(
        fixture.bytes,
        fixture.firstMoofStart,
        fixture.firstFragmentEnd,
      );
      bodies['/$prefix/seg1.m4s'] = Uint8List.sublistView(
        fixture.bytes,
        fixture.firstFragmentEnd,
      );
    }

    addFixture('video', video);
    addFixture('audio', audio);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(
      memoryLimitBytes: 1024 * 1024,
      diskLimitBytes: 0,
    );
    final proxy = await PlaybackHttpProxy.create(
      origin: Uri.parse('http://127.0.0.1:${upstream.port}'),
      cache: cache,
      sessionBuffering: true,
      readAheadBytes: 0,
    );
    final client = HttpClient();
    upstream.listen((request) async {
      final path = request.uri.path;
      final bytes = bodies[path];
      request.response.headers.set('cache-control', 'public,max-age=300');
      request.response.headers.set('etag', '"$path"');
      if (path.endsWith('/index.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2,
seg0.m4s
#EXTINF:2,
seg1.m4s
#EXT-X-ENDLIST
''');
      } else if (bytes != null) {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    Future<String> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, 200);
      return utf8.decode(
        await response.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        allowMalformed: true,
      );
    }

    Future<(Uri, List<Uri>)> playlist(String name) async {
      final text = await get(
        proxy.register(
          Uri.parse('http://127.0.0.1:${upstream.port}/$name/index.m3u8'),
        ),
      );
      return (
        Uri.parse(RegExp('URI="([^"]+)"').firstMatch(text)![1]!),
        text
            .split('\n')
            .where((line) => line.startsWith('http://'))
            .map(Uri.parse)
            .toList(),
      );
    }

    List<(int, int)> timeline() =>
        (proxy.diagnostics['cachedTimeRanges'] as List).map((item) {
          final map = item as Map;
          return (map['startMs'] as int, map['endMs'] as int);
        }).toList();
    try {
      final (videoMap, videoSegments) = await playlist('video');
      final (audioMap, audioSegments) = await playlist('audio');
      await get(videoMap);
      await get(audioMap);
      await get(videoSegments[0]);
      await _waitFor(() => proxy.diagnostics['hlsActivePlaylists'] == 1);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), isEmpty);
      expect(proxy.diagnostics['timelineUnknownReason'], isNotNull);

      await get(audioSegments[0]);
      await _waitFor(() => proxy.diagnostics['hlsActivePlaylists'] == 2);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), [(0, 2000)], reason: proxy.diagnostics.toString());

      await get(videoSegments[1]);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), [(0, 2000)]);
      await get(audioSegments[1]);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(timeline(), [(0, 4000)]);
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for HLS proxy state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
