import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'fake_jellyfin_server.dart';

void main() {
  const device = ClientDeviceInfo(
    clientName: 'Rillight',
    deviceName: 'Fake desktop',
    deviceId: 'device-1',
    version: '1',
  );
  late JellyfinFakeServer fake;
  late JellyfinClient client;
  setUp(() async {
    fake = JellyfinFakeServer();
    await fake.start();
    client = JellyfinClient(device: device);
  });
  tearDown(() async {
    await fake.close();
    expect(fake.violations, isEmpty);
  });
  void attach() {
    client.attachSession(
      baseUrl: fake.url,
      accessToken: 'fake-token',
      userId: 'alice-id',
    );
  }

  Matcher failure(MediaServerFailureKind kind) =>
      isA<MediaServerException>().having((e) => e.kind, 'kind', kind);
  PlaybackReport report(PlaybackInfo info) => PlaybackReport(
    itemId: 'movie-1',
    mediaSourceId: 'version-1',
    playSessionId: info.playSessionId,
    playMethod: PlayMethod.transcode,
    position: const Duration(milliseconds: 1234),
  );

  test(
    'transcode quality uses server encoder selection, never input or request ceiling',
    () async {
      attach();
      for (final sample in <(String, int?)>[
        ('&VideoBitrate=3808000&AudioBitrate=192000', 4000000),
        ('&VideoBitrate=7808000&AudioBitrate=192000', 8000000),
        ('&MaxStreamingBitrate=4000000', null),
        ('&VideoBitrate=3808000', null),
        ('&VideoBitrate=3808000&VideoBitrate=1&AudioBitrate=192000', null),
      ]) {
        fake.transcodeOutputQuery = sample.$1;
        final info = await client.getPlaybackInfo(
          itemId: 'movie-1',
          maxStreamingBitrate: 4000000,
          forceTranscode: true,
        );
        final playback = client.resolvePlayback(
          info: info,
          itemId: 'movie-1',
          forceTranscode: true,
        )!;
        expect(playback.mediaSource.bitrate, 24000000);
        expect(playback.outputBitrate, sample.$2, reason: sample.$1);
        await info.resources!.release();
      }
      expect(fake.resources, isEmpty);
    },
  );
  test(
    'password verifies server identity, restore and logout use official routes',
    () async {
      expect((await client.getPublicInfo(fake.url)).id, 'server-jellyfin');
      final login = await client.authenticateByName(
        baseUrl: fake.url,
        username: 'alice',
        password: 'password',
        serverId: 'server-jellyfin',
      );
      expect(login.user.id, 'alice-id');
      expect(client.hasSession, isFalse);
      await expectLater(
        client.authenticateByName(
          baseUrl: fake.url,
          username: 'alice',
          password: 'bad',
          serverId: 'server-jellyfin',
        ),
        throwsA(failure(MediaServerFailureKind.invalidCredentials)),
      );
      await expectLater(
        client.authenticateByName(
          baseUrl: fake.url,
          username: 'alice',
          password: 'password',
          serverId: 'wrong-server',
        ),
        throwsA(failure(MediaServerFailureKind.incompatibleServer)),
      );
      attach();
      expect((await client.getUser()).name, 'Alice');
      await client.changePassword(
        currentPassword: 'password',
        newPassword: 'updated',
      );
      await client.logout();
      expect(client.hasSession, isFalse);
    },
  );
  test(
    'Quick Connect pending, authorized and one exchange; no automatic session',
    () async {
      final attempt = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      expect(attempt.code, '654321');
      expect(await attempt.poll(), AuthorizationStatus.pending);
      await expectLater(
        attempt.exchange(),
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      fake.quickAuthorized = true;
      expect(await attempt.poll(), AuthorizationStatus.authorized);
      final grants = await Future.wait([
        attempt.exchange(),
        attempt.exchange(),
      ]);
      expect(
        (grants.first as SessionAuthorizationGrant).session.user.id,
        'alice-id',
      );
      expect(client.hasSession, isFalse);
      expect(
        fake.requests
            .where((r) => r.path == '/Users/AuthenticateWithQuickConnect')
            .length,
        1,
      );
    },
  );
  test(
    'Quick Connect disabled, cancelled, expired, denied and offline remain distinct',
    () async {
      fake.quickEnabled = false;
      expect(
        (await client.availability(
          AuthorizationMethod.quickConnect,
          server: fake.url,
        )).availability,
        CapabilityAvailability.restricted,
      );
      await expectLater(
        client.begin(AuthorizationMethod.quickConnect, server: fake.url),
        throwsA(failure(MediaServerFailureKind.unsupported)),
      );
      fake.quickEnabled = true;
      final a = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      await a.cancel();
      expect(await a.poll(), AuthorizationStatus.cancelled);
      var now = DateTime.utc(2026);
      final timed = JellyfinClient(device: device, clock: () => now);
      final b = await timed.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      now = now.add(const Duration(minutes: 11));
      expect(await b.poll(), AuthorizationStatus.expired);
      final c = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      fake.nextStatus = 403;
      expect(await c.poll(), AuthorizationStatus.denied);
      final d = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      fake.nextStatus = 429;
      await expectLater(
        d.poll(),
        throwsA(failure(MediaServerFailureKind.rateLimited)),
      );
    },
  );
  test('cancel during exchange rejects late authorization', () async {
    fake.quickAuthorized = true;
    final a = await client.begin(
      AuthorizationMethod.quickConnect,
      server: fake.url,
    );
    await a.poll();
    final gate = Completer<void>();
    fake.delay = gate;
    fake.arrived = Completer<void>();
    final arrived = fake.arrived!.future;
    final result = a.exchange();
    final assertion = expectLater(
      result,
      throwsA(failure(MediaServerFailureKind.cancelled)),
    );
    await arrived;
    await a.cancel();
    gate.complete();
    await assertion;
    expect(client.hasSession, isFalse);
  });
  test(
    'request guard and session generation reject late user/catalog results',
    () async {
      attach();
      var permitted = true;
      final guarded = client.withRequestGuard(() {
        if (!permitted) {
          throw const MediaServerException(MediaServerFailureKind.forbidden);
        }
      });
      final gate = Completer<void>();
      fake.delay = gate;
      fake.arrived = Completer<void>();
      final arrived = fake.arrived!.future;
      final result = guarded.getViews();
      final assertion = expectLater(
        result,
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      await arrived;
      permitted = false;
      gate.complete();
      await assertion;
      final next = Completer<void>();
      fake.delay = next;
      fake.arrived = Completer<void>();
      final nextArrived = fake.arrived!.future;
      final user = client.getUser();
      final check = expectLater(
        user,
        throwsA(failure(MediaServerFailureKind.cancelled)),
      );
      await nextArrived;
      client.clearSession();
      next.complete();
      await check;
    },
  );
  test(
    'catalog mapping and paging, real segments, genres, counts and watched state',
    () async {
      attach();
      expect((await client.getViews()).single.id, 'library-1');
      final page = await client.queryItems(
        parentId: 'library-1',
        searchTerm: '测试',
        includeItemTypes: 'Movie',
        startIndex: 20,
        limit: 10,
        genres: ['剧情'],
        years: [2026],
        sortBy: 'SortName',
        sortOrder: 'Ascending',
      );
      expect(page.totalRecordCount, 31);
      expect(page.offset, 20);
      expect(page.items.single.runtime, const Duration(seconds: 120));
      final item = await client.getItem('movie-1');
      expect(
        item.chapters.where((c) => c.markerType == 'IntroStart').length,
        1,
      );
      expect(
        item.chapters
            .where((c) => c.markerType == 'IntroEnd')
            .single
            .startPosition,
        const Duration(seconds: 3),
      );
      expect(item.mediaSources.single.streams.single.language, 'zho');
      expect(await client.getLibraryGenres('library-1'), ['剧情']);
      expect((await client.getItemCounts()).series, isNull);
      await client.markPlayed('movie-1');
      expect(fake.watched, contains('movie-1'));
      await client.markUnplayed('movie-1');
      expect(fake.watched, isEmpty);
      await client.hideFromResume('movie-1');
      expect(fake.userData['PlaybackPositionTicks'], 0);
      expect(fake.userData['Played'], false);
      await client.getResumeItems();
      await client.getNextUp();
      await client.getLatestItems(includeItemTypes: 'Movie');
      await client.searchByName('测试');
      expect(
        (await client.querySimilar('movie-1')).pagination.availability,
        CapabilityAvailability.unsupported,
      );
      expect(
        (await client.getNextEpisode(
          const MediaItem(
            id: 'current',
            name: '当前',
            type: 'Episode',
            seriesId: 'series-1',
          ),
        ))?.id,
        'next',
      );
      expect(
        () => client.queryNextUp(sortBy: 'Name'),
        throwsA(failure(MediaServerFailureKind.unsupported)),
      );
    },
  );
  test(
    'playback units, isolated simultaneous leases and crash recovery',
    () async {
      attach();
      final a = await client.getPlaybackInfo(
        itemId: 'movie-1',
        startPosition: const Duration(milliseconds: 1234),
        audioStreamIndex: 1,
        subtitleStreamIndex: 2,
        forceTranscode: true,
        capabilities: const PlaybackCapabilities(h264: true, aac: true),
      );
      final resolved = client.resolvePlayback(
        info: a,
        itemId: 'movie-1',
        forceTranscode: true,
      )!;
      expect(resolved.streamUrl.toString(), contains('sig=a%2Fb+z'));
      expect(resolved.playMethod, PlayMethod.transcode);
      expect(
        resolved.authorization!.headersFor(fake.url)['Authorization'],
        contains('rillight-playback-'),
      );
      expect(fake.requests.last.body!['StartTimeTicks'], 12340000);
      await client.reportPlaying(report(a));
      await client.reportProgress(report(a));
      expect(fake.requests.last.body!['PlayMethod'], 'Transcode');
      expect(fake.requests.last.body!['IsPaused'], false);
      expect(fake.requests.last.body!['CanSeek'], true);
      final b = await client.getPlaybackInfo(itemId: 'movie-1');
      expect(a.playSessionId, isNot(b.playSessionId));
      await Future.wait([b.resources!.release(), b.resources!.release()]);
      expect(fake.nowPlaying.length, 1);
      expect(fake.resources.length, 1);
      expect(fake.userData['PlaybackPositionTicks'], 123456780);
      final restored =
          jsonDecode(jsonEncode({'handle': a.playSessionId}))['handle']
              as String;
      final detached = client.createDetached()
        ..attachSession(
          baseUrl: fake.url,
          accessToken: 'fake-token',
          userId: 'alice-id',
        );
      final recovered = PlaybackReport(
        itemId: 'movie-1',
        mediaSourceId: 'version-1',
        playSessionId: restored,
        playMethod: PlayMethod.transcode,
        position: const Duration(seconds: 8),
      );
      await detached.reportStopped(recovered);
      await detached.releasePlayback(recovered);
      expect(fake.resources, isEmpty);
      expect(fake.nowPlaying, isEmpty);
      expect(fake.userData['PlaybackPositionTicks'], 80000000);
      final wireIds = fake.requests
          .where((r) => r.path.startsWith('/Sessions/Playing'))
          .map((r) => r.body!['PlaySessionId']);
      expect(
        wireIds.every((id) => (id as String).startsWith('raw-session-')),
        isTrue,
      );
      expect(
        () => client.releasePlayback(
          const PlaybackReport(
            itemId: 'x',
            mediaSourceId: 'x',
            playSessionId: 'corrupt',
            playMethod: PlayMethod.transcode,
            position: Duration.zero,
          ),
        ),
        throwsA(failure(MediaServerFailureKind.invalidResponse)),
      );
    },
  );
  test(
    'lease failure retries and retained resource cannot clean a new user',
    () async {
      attach();
      final info = await client.getPlaybackInfo(itemId: 'movie-1');
      fake.nextStatus = 503;
      await expectLater(
        info.resources!.release(),
        throwsA(isA<MediaServerException>()),
      );
      expect(info.resources!.isReleased, isFalse);
      client.attachSession(
        baseUrl: fake.url,
        accessToken: 'other-token',
        userId: 'other-user',
      );
      await info.resources!.release();
      expect(fake.requests.last.authorization, contains('fake-token'));
      expect(info.resources!.isReleased, isTrue);
    },
  );
  test(
    'trickplay maps milliseconds to tile and enforces bounds and close',
    () async {
      attach();
      final preview = (await client.openPreview('movie-1'))!;
      final frame = (await preview.frameAt(const Duration(seconds: 30)))!;
      expect(frame.tile!.x, 160);
      expect(frame.tile!.y, 90);
      expect(frame.bytes, [255, 216, 255, 217]);
      await preview.frameAt(const Duration(seconds: 20));
      expect(
        fake.requests.where((r) => r.path.contains('Trickplay')).length,
        1,
      );
      expect(await preview.frameAt(const Duration(seconds: 60)), isNull);
      await preview.close();
      expect(await preview.frameAt(Duration.zero), isNull);
      await client.getPrimaryImage('movie-1');
      await client.getChapterImage('movie-1', index: 0);
    },
  );
  test(
    'cross-origin redirect strips credentials; resource bounds reject overflow',
    () async {
      attach();
      String? leaked;
      final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      foreign.listen((r) async {
        leaked = r.headers.value('authorization');
        r.response.add([1, 2, 3]);
        await r.response.close();
      });
      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirect.listen((r) async {
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${foreign.port}/image',
        );
        await r.response.close();
      });
      client.attachSession(
        baseUrl: Uri.parse('http://127.0.0.1:${redirect.port}'),
        accessToken: 'fake-token',
        userId: 'alice-id',
      );
      try {
        expect(await client.readAuthorizedBytes(client.baseUrl!), [1, 2, 3]);
        expect(leaked, isNull);
        await expectLater(
          client.readAuthorizedBytes(client.baseUrl!, maxBytes: 2),
          throwsA(failure(MediaServerFailureKind.invalidResponse)),
        );
      } finally {
        await redirect.close(force: true);
        await foreign.close(force: true);
      }
    },
  );
  test(
    'empty catalog differs from malformed, forbidden, expired and offline',
    () async {
      attach();
      fake.nextJson = {'Items': [], 'TotalRecordCount': 0};
      expect((await client.queryItems()).items, isEmpty);
      fake.nextJson = {'Wrong': []};
      await expectLater(
        client.getViews(),
        throwsA(failure(MediaServerFailureKind.invalidResponse)),
      );
      fake.nextStatus = 403;
      await expectLater(
        client.getViews(),
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      var expired = false;
      client.onSessionExpired = () => expired = true;
      fake.nextStatus = 401;
      await expectLater(
        client.getViews(),
        throwsA(failure(MediaServerFailureKind.sessionExpired)),
      );
      expect(expired, isTrue);
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      await expectLater(
        client.getPublicInfo(Uri.parse('http://127.0.0.1:$port')),
        throwsA(failure(MediaServerFailureKind.unreachable)),
      );
    },
  );
  test(
    'late Quick Connect poll cannot survive logout; remote expiry is terminal',
    () async {
      final a = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      fake.nextStatus = 404;
      expect(await a.poll(), AuthorizationStatus.expired);
      final b = await client.begin(
        AuthorizationMethod.quickConnect,
        server: fake.url,
      );
      fake.quickAuthorized = true;
      final gate = Completer<void>();
      fake.delay = gate;
      fake.arrived = Completer<void>();
      final arrived = fake.arrived!.future;
      final assertion = expectLater(
        b.poll(),
        throwsA(failure(MediaServerFailureKind.cancelled)),
      );
      await arrived;
      client.clearSession();
      gate.complete();
      await assertion;
    },
  );
  test(
    'both playing sessions keep separate devices and releasing one preserves other',
    () async {
      attach();
      final a = await client.getPlaybackInfo(itemId: 'movie-1');
      final b = await client.getPlaybackInfo(itemId: 'movie-1');
      await client.reportPlaying(report(a));
      await client.reportPlaying(report(b));
      expect(fake.nowPlaying.length, 2);
      await client.reportStopped(report(a));
      await client.releasePlayback(report(a));
      expect(fake.nowPlaying.length, 1);
      expect(fake.resources.length, 1);
      await client.reportStopped(report(b));
      expect(fake.nowPlaying, isEmpty);
    },
  );
  test(
    'direct resource uses raw session and isolated authorization; unknown version fails',
    () async {
      attach();
      final info = await client.getPlaybackInfo(itemId: 'movie-1');
      final resolved = client.resolvePlayback(info: info, itemId: 'movie-1')!;
      expect(resolved.playMethod, PlayMethod.directPlay);
      expect(
        resolved.streamUrl.queryParameters['playSessionId'],
        'raw-session-1',
      );
      expect(
        resolved.authorization!.headersFor(
          Uri.parse('https://foreign.example/media'),
        )['Authorization'],
        isNull,
      );
      expect(
        client.resolvePlayback(
          info: info,
          itemId: 'movie-1',
          mediaSourceId: 'unknown',
        ),
        isNull,
      );
      await info.resources!.release();
    },
  );
  test(
    'direct stream remux uses negotiated URL instead of static original',
    () async {
      attach();
      final original = await client.getPlaybackInfo(itemId: 'movie-1');
      final info = PlaybackInfo(
        playSessionId: original.playSessionId,
        resources: original.resources,
        mediaSources: const [
          PlaybackMediaSource(
            id: 'remux',
            supportsDirectStream: true,
            supportsTranscoding: true,
            transcodingUrl: '/Videos/movie-1/master.m3u8?copy=true',
          ),
        ],
      );
      final resolved = client.resolvePlayback(info: info, itemId: 'movie-1')!;
      expect(resolved.playMethod, PlayMethod.directStream);
      expect(resolved.streamUrl.path, '/jf/Videos/movie-1/master.m3u8');
      await original.resources!.release();
    },
  );
}
