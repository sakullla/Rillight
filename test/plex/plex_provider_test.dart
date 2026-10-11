import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';
import 'fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'Rillight test',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);
Matcher failure(MediaServerFailureKind kind) =>
    isA<MediaServerException>().having((e) => e.kind, 'kind', kind);
void main() {
  late FakePlex fake;
  late PlexAuthentication auth;
  late PlexClient client;
  late Map<String, Map<String, dynamic>> credentials;
  setUp(() async {
    fake = FakePlex();
    await fake.start();
    credentials = {};
    auth = PlexAuthentication(
      device: device,
      accountUrl: fake.url,
      homeUrl: fake.url,
      readCredential: (ref) async => credentials[ref],
      writeCredential: (ref, value) async {
        credentials[ref] = value;
      },
      deleteCredential: (ref) async {
        credentials.remove(ref);
      },
    );
    client = PlexClient(device: device)
      ..attachSession(
        baseUrl: fake.url,
        accessToken: 'owner-resource',
        userId: '1',
      );
  });
  tearDown(() async {
    await fake.close();
  });
  Future<CloudAccount> authorize() async {
    final attempt = await auth.begin(AuthorizationMethod.browserPin);
    fake.authorized = true;
    expect(await attempt.poll(), AuthorizationStatus.authorized);
    return ((await attempt.exchange()) as CloudAuthorizationGrant).account;
  }

  test(
    'JWK PIN signature, cloud verification, refresh coalescing and separate Home resources',
    () async {
      final attempt = await auth.begin(AuthorizationMethod.browserPin);
      expect(attempt.code, 'ABCD');
      expect(attempt.verificationUri!.host, 'app.plex.tv');
      expect(await attempt.poll(), AuthorizationStatus.pending);
      fake.authorized = true;
      expect(await attempt.poll(), AuthorizationStatus.authorized);
      final account =
          ((await attempt.exchange()) as CloudAuthorizationGrant).account;
      expect(
        credentials[account.credentialRef]!['accessToken'],
        FakePlex.cloudToken,
      );
      final resources = await auth.discoverResources(account);
      expect(resources.single.server.id, 'server-a');
      expect(resources.single.connections.last.limitedBandwidth, true);
      expect(
        credentials[resources.single.resourceCredentialRef]!['accessToken'],
        'owner-resource',
      );
      final users = await auth.homeUsers(account);
      expect(users.last.requiresPin, true);
      await expectLater(
        auth.switchHomeUser(account, users.last, pin: 'bad'),
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      final switched = await auth.switchHomeUser(
        account,
        users.last,
        pin: '1234',
      );
      expect(switched.single.user.id, '2');
      expect(switched.single.homeUserId, '2');
      expect(
        credentials[switched.single.resourceCredentialRef]!['accessToken'],
        'child-resource',
      );
      expect(
        credentials[resources.single.resourceCredentialRef]!['accessToken'],
        'owner-resource',
      );
      await Future.wait([
        auth.refreshAccount(account),
        auth.refreshAccount(account),
      ]);
      expect(fake.refreshes, 1);
      expect(
        credentials[account.credentialRef]!['accessToken'],
        FakePlex.refreshedToken,
      );
      expect((await auth.restoreAccount(account.credentialRef)).id, '1');
    },
  );
  test('late authorized PIN cannot commit after cancellation', () async {
    final attempt = await auth.begin(AuthorizationMethod.browserPin);
    fake.authorized = true;
    fake.pollGate = Completer<void>();
    final pending = attempt.poll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await attempt.cancel();
    fake.pollGate!.complete();
    expect(await pending, AuthorizationStatus.cancelled);
    await expectLater(
      attempt.exchange(),
      throwsA(failure(MediaServerFailureKind.cancelled)),
    );
    expect(credentials.values.where((v) => v['kind'] == 'cloud'), isEmpty);
  });
  test('PIN expiration is distinct from pending', () async {
    var now = DateTime.now();
    final timed = PlexAuthentication(
      device: device,
      accountUrl: fake.url,
      homeUrl: fake.url,
      now: () => now,
      readCredential: (ref) async => credentials[ref],
      writeCredential: (ref, value) async {
        credentials[ref] = value;
      },
      deleteCredential: (ref) async {},
    );
    final attempt = await timed.begin(AuthorizationMethod.browserPin);
    now = now.add(const Duration(minutes: 6));
    expect(await attempt.poll(), AuthorizationStatus.expired);
    await expectLater(
      attempt.exchange(),
      throwsA(failure(MediaServerFailureKind.authorizationExpired)),
    );
  });
  test('JWK PIN never silently accepts a legacy token', () async {
    final attempt = await auth.begin(AuthorizationMethod.browserPin);
    fake.authorized = true;
    fake.pinToken = 'legacy-token';
    expect(await attempt.poll(), AuthorizationStatus.authorized);
    await expectLater(
      attempt.exchange(),
      throwsA(failure(MediaServerFailureKind.invalidResponse)),
    );
    expect(credentials.values.where((v) => v['kind'] == 'cloud'), isEmpty);
  });
  test(
    'explicit cloud revocation clears its reference after signout',
    () async {
      final account = await authorize();
      await auth.revokeAccount(account);
      expect(fake.requests.last.path, '/api/v2/users/signout');
      expect(fake.requests.last.method, 'DELETE');
      expect(credentials.containsKey(account.credentialRef), false);
    },
  );
  test('shared permission refusal is not an empty discovery', () async {
    final account = await authorize();
    fake.sharedDenied = true;
    await expectLater(
      auth.discoverResources(account),
      throwsA(failure(MediaServerFailureKind.forbidden)),
    );
  });
  test('failed preflight cleanup exposes original retryable lease', () async {
    fake.transcodeDenied = true;
    fake.failStops = true;
    PlexPlaybackPreparationException? failure;
    try {
      await client.getPlaybackInfo(itemId: '42', forceTranscode: true);
    } on PlexPlaybackPreparationException catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(fake.sessions.length, 1);
    fake.failStops = false;
    await failure!.resources.release();
    expect(fake.sessions, isEmpty);
    expect(fake.requests.where((r) => r.path.endsWith('/decision')).length, 1);
  });
  test(
    'expired cloud resources refresh once without legacy fallback',
    () async {
      final account = await authorize();
      fake.expireCloud = true;
      expect(
        (await auth.discoverResources(account)).single.server.id,
        'server-a',
      );
      expect(fake.refreshes, 1);
      expect(
        credentials[account.credentialRef]!['accessToken'],
        FakePlex.refreshedToken,
      );
    },
  );
  for (final entry in {
    401: MediaServerFailureKind.sessionExpired,
    403: MediaServerFailureKind.forbidden,
    429: MediaServerFailureKind.rateLimited,
    498: MediaServerFailureKind.authorizationExpired,
    422: MediaServerFailureKind.signatureRejected,
  }.entries) {
    test(
      'HTTP ${entry.key} retains failure semantics and strips body secrets',
      () async {
        fake.errorStatus = entry.key;
        fake.errorMessage = 'secret-token';
        await expectLater(client.getViews(), throwsA(failure(entry.value)));
        try {
          await client.getViews();
        } catch (error) {
          expect(error.toString(), isNot(contains('secret-token')));
        }
      },
    );
  }
  test('clock rejection is distinguishable from signature errors', () async {
    fake.errorStatus = 422;
    fake.errorMessage = 'clock timestamp out of range';
    await expectLater(
      client.getViews(),
      throwsA(failure(MediaServerFailureKind.clockSkew)),
    );
  });
  test(
    'JSON films, sections, pagination, filters, opaque keys and milliseconds',
    () async {
      expect((await client.getViews()).map((v) => v.id), [
        'section:1',
        'section:2',
      ]);
      final page = await client.queryItems(
        parentId: 'section:1',
        includeItemTypes: 'Movie',
        startIndex: 1,
        limit: 1,
        genres: ['Drama'],
        years: [2026],
        filters: ['IsUnplayed'],
        sortBy: 'DateCreated',
        sortOrder: 'Descending',
      );
      expect(page.offset, 1);
      expect(page.totalRecordCount, 2);
      expect(page.pagination.isAvailable, true);
      final query = fake.requests.last.query;
      expect(query['genre'], 'Drama');
      expect(query['unwatched'], '1');
      expect(query['sort'], 'addedAt:desc');
      final item = await client.getItem('42');
      expect(item.runtime, const Duration(minutes: 2));
      expect(
        item.userData.playbackPosition,
        const Duration(milliseconds: 12345),
      );
      expect(item.providerIds, {'tmdb': '100', 'imdb': 'tt100'});
      expect(item.parentId, 'section:1');
      expect(item.chapters.length, 2);
      expect(item.chapters.last.startPosition, const Duration(seconds: 4));
      expect((await client.getResumeItems()).single.id, '42');
      expect(await client.getLibraryGenres('section:1'), ['Drama']);
      expect((await client.getItemCounts()).movie, 2);
      await client.markPlayed('42');
      expect(fake.requests.last.path, '/:/scrobble');
      await client.markUnplayed('42');
      await client.hideFromResume('42');
      expect(fake.requests.last.method, 'PUT');
    },
  );
  test('direct Part timeline and selected version/track validation', () async {
    final info = await client.getPlaybackInfo(
      itemId: '42',
      mediaSourceId: '7',
      startPosition: const Duration(seconds: 62),
      audioStreamIndex: 22,
    );
    final resolved =
        client.resolvePlayback(info: info, itemId: '42')
            as PlexResolvedPlayback;
    expect(resolved.partIndex, 1);
    expect(resolved.partStartPosition, const Duration(seconds: 2));
    expect(resolved.streamUrl.path, '/prefix/library/parts/102/file.mkv');
    expect(
      resolved.timeline!.locate(const Duration(seconds: 62))!.local,
      const Duration(seconds: 2),
    );
    expect(resolved.mediaSource.mediaStreams.map((s) => s.index), [21, 22]);
    await expectLater(
      client.getPlaybackInfo(
        itemId: '42',
        startPosition: const Duration(seconds: 62),
        audioStreamIndex: 12,
      ),
      throwsA(failure(MediaServerFailureKind.invalidResponse)),
    );
    await expectLater(
      client.getPlaybackInfo(itemId: '42', mediaSourceId: 'wrong'),
      throwsA(failure(MediaServerFailureKind.invalidResponse)),
    );
    fake.missingPartDuration = true;
    await expectLater(
      client.getPlaybackInfo(
        itemId: '42',
        startPosition: const Duration(seconds: 62),
      ),
      throwsA(failure(MediaServerFailureKind.unsupported)),
    );
  });
  test(
    'decision local offset, global timeline report and owned idempotent cleanup',
    () async {
      final info = await client.getPlaybackInfo(
        itemId: '42',
        mediaSourceId: '7',
        forceTranscode: true,
        maxStreamingBitrate: 8000000,
        startPosition: const Duration(seconds: 62),
        audioStreamIndex: 22,
      );
      final decision = fake.requests.last;
      expect(decision.path, '/video/:/transcode/universal/decision');
      expect(decision.query['partIndex'], '1');
      expect(decision.query['offset'], '2.0');
      final selection = fake.requests
          .where((r) => r.method == 'PUT' && r.path == '/library/parts/102')
          .single;
      expect(selection.query['audioStreamID'], '22');
      expect(selection.query['allParts'], '0');
      expect(decision.query['videoBitrate'], '8000');
      expect(decision.query['peakBitrate'], '8000');
      final resolved =
          client.resolvePlayback(info: info, itemId: '42')
              as PlexResolvedPlayback;
      expect(resolved.timeline, isNull);
      expect(resolved.filmTimeline.duration, const Duration(minutes: 2));
      expect(resolved.partStartPosition, const Duration(seconds: 2));
      expect(resolved.streamUrl.path, endsWith('/start.m3u8'));
      expect(
        utf8.decode(await client.readAuthorizedBytes(resolved.streamUrl)),
        contains('#EXTM3U'),
      );
      final report = PlaybackReport(
        itemId: '42',
        mediaSourceId: '7',
        playSessionId: info.playSessionId,
        playMethod: PlayMethod.transcode,
        position: const Duration(milliseconds: 62345),
      );
      await client.reportPlaying(report);
      expect(fake.requests.last.query['time'], '62345');
      expect(fake.requests.last.query['duration'], '120000');
      await client.reportStopped(report);
      expect(fake.sessions, isNotEmpty);
      client.clearSession();
      await Future.wait([info.resources!.release(), info.resources!.release()]);
      expect(fake.stops, 1);
      expect(fake.sessions, isEmpty);
      expect(fake.requests.last.token, 'owner-resource');
    },
  );
  test(
    'rejected preflight releases own resource without timeline or new start',
    () async {
      fake.transcodeDenied = true;
      await expectLater(
        client.getPlaybackInfo(itemId: '42', forceTranscode: true),
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      expect(fake.sessions, isEmpty);
      expect(fake.stops, 1);
      expect(
        fake.requests.any(
          (r) => r.path == '/:/timeline' || r.path.endsWith('start.m3u8'),
        ),
        false,
      );
    },
  );
  test(
    'failed release is retryable and recovered cleanup never starts a transcode',
    () async {
      final info = await client.getPlaybackInfo(
        itemId: '42',
        forceTranscode: true,
      );
      fake.errorStatus = 403;
      await expectLater(
        info.resources!.release(),
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      expect(info.resources!.isReleased, false);
      fake.errorStatus = null;
      await info.resources!.release();
      expect(info.resources!.isReleased, true);
      final recovered = PlexClient(device: device)
        ..attachSession(
          baseUrl: fake.url,
          accessToken: 'owner-resource',
          userId: '1',
        );
      final report = PlaybackReport(
        itemId: '42',
        mediaSourceId: '7',
        playSessionId: 'recorded-old-session',
        playMethod: PlayMethod.transcode,
        position: Duration.zero,
      );
      final before = fake.requests.length;
      await recovered.releasePlayback(report);
      await recovered.releasePlayback(report);
      expect(fake.requests.skip(before).map((r) => r.path), [
        '/video/:/transcode/universal/stop',
      ]);
      expect(fake.requests.last.query['session'], 'recorded-old-session');
    },
  );
  test(
    'source guard rejects late response, cleanup survives revoked read guard',
    () async {
      var allowed = true;
      final guarded = client.withRequestGuard(() {
        if (!allowed) {
          throw const MediaServerException(MediaServerFailureKind.forbidden);
        }
      });
      final info = await guarded.getPlaybackInfo(
        itemId: '42',
        forceTranscode: true,
      );
      fake.metadataGate = Completer<void>();
      final pending = guarded.getItem('42');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      allowed = false;
      fake.metadataGate!.complete();
      await expectLater(
        pending,
        throwsA(failure(MediaServerFailureKind.forbidden)),
      );
      await info.resources!.release();
      expect(fake.sessions, isEmpty);
    },
  );
  test(
    'preview uses actual indexes and second-part local milliseconds',
    () async {
      final preview = await client.openPreview('42');
      expect(preview, isNotNull);
      expect((await preview!.frameAt(const Duration(seconds: 62)))!.bytes, [
        1,
        2,
        3,
      ]);
      expect(fake.requests.last.path, '/library/parts/102/indexes/sd/2000');
      await preview.close();
      expect(await preview.frameAt(Duration.zero), isNull);
    },
  );
  test('foreign image redirect never receives resource token', () async {
    final sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? leaked;
    sink.listen((request) async {
      leaked = request.headers.value('x-plex-token');
      request.response.add([7]);
      await request.response.close();
    });
    try {
      final foreign = Uri.parse('http://127.0.0.1:${sink.port}/image');
      fake.redirectTo = foreign.toString();
      expect(
        await client.readAuthorizedBytes(client.resolveResource('/redirect')),
        [7],
      );
      expect(leaked, isNull);
      final info = await client.getPlaybackInfo(itemId: '42');
      final resolved = client.resolvePlayback(info: info, itemId: '42')!;
      expect(
        resolved.authorization!.headersFor(foreign).keys,
        isNot(contains('X-Plex-Token')),
      );
    } finally {
      await sink.close(force: true);
    }
  });
  test('bounded authorized image reads reject oversized bytes', () async {
    await expectLater(client.getPrimaryImage('42'), completion([1, 2, 3]));
    await expectLater(
      client.readAuthorizedBytes(
        client.resolveResource('/library/metadata/42/thumb/1'),
        maxBytes: 2,
      ),
      throwsA(failure(MediaServerFailureKind.invalidResponse)),
    );
  });
}
