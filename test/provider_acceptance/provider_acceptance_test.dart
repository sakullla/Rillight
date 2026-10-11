import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';

import '../emby/fake_emby_server.dart';
import '../jellyfin/fake_jellyfin_server.dart';
import '../plex/fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'Rillight acceptance',
  deviceName: 'synthetic loopback',
  deviceId: 'test-device',
  version: 'synthetic',
);
const progress = Duration(milliseconds: 37345);
final rejected = throwsA(isA<MediaServerException>());

Future<void> passwordLogin(
  MediaServerClient client,
  Uri url,
  String password,
) async {
  final server = await client.getPublicInfo(url);
  final login = await client.authenticateByName(
    baseUrl: url,
    username: 'alice',
    password: password,
    serverId: server.id,
  );
  client.attachSession(
    baseUrl: url,
    accessToken: login.accessToken,
    userId: login.user.id,
  );
  expect((await client.getUser()).id, login.user.id);
}

/// Executes protocol negotiation and reporting. No decoder or video backend is
/// involved: these reports are synthetic observations, not displayed playback.
Future<void> playAndStop(MediaServerClient client, String itemId) async {
  expect(await client.getViews(), isNotEmpty);
  final item = await client.getItem(itemId);
  expect(item.id, itemId);
  final info = await client.getPlaybackInfo(
    itemId: itemId,
    forceTranscode: true,
    maxStreamingBitrate: 8000000,
  );
  final playback = client.resolvePlayback(
    info: info,
    itemId: itemId,
    forceTranscode: true,
  );
  expect(playback, isNotNull);
  expect(playback!.streamUrl.hasAuthority, isTrue);
  PlaybackReport report(Duration position) => PlaybackReport(
    itemId: itemId,
    mediaSourceId: playback.mediaSource.id,
    playSessionId: info.playSessionId,
    playMethod: PlayMethod.transcode,
    position: position,
  );
  await client.reportPlaying(report(Duration.zero));
  await client.reportProgress(report(progress));
  await client.stopPlayback(report(progress));
  await info.resources?.release();
}

Future<void> resumeAndStop(MediaServerClient client, String itemId) async {
  final resume = await client.getResumeItems();
  expect(
    resume.where((item) => item.id == itemId).single.resumePosition,
    progress,
  );
  expect((await client.getItem(itemId)).resumePosition, progress);
  final info = await client.getPlaybackInfo(
    itemId: itemId,
    startPosition: progress,
    forceTranscode: true,
  );
  expect(client.resolvePlayback(info: info, itemId: itemId), isNotNull);
  await info.resources?.release();
}

void main() {
  // Bind a real socket to the established Emby route fixture. This exercises
  // the production HTTP transport without duplicating the Emby protocol oracle.
  late HttpServer embySocket;
  late FakeEmbyServer emby;
  late JellyfinFakeServer jellyfin;
  late FakePlex plex;
  setUp(() async {
    embySocket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    emby = FakeEmbyServer(
      baseUrl: Uri.parse('http://127.0.0.1:${embySocket.port}'),
      items: [
        FakeEmbyItem(
          id: 'acceptance-film',
          name: 'Synthetic AAC film',
          type: 'Movie',
          parentId: 'view-movies',
          runtime: const Duration(minutes: 2),
          forceTranscode: true,
          mediaStreams: const [
            FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
            FakeMediaStream(index: 1, type: 'Audio', codec: 'aac'),
          ],
        ),
      ],
    );
    embySocket.listen((request) async {
      final headers = <String, dynamic>{};
      request.headers.forEach(
        (name, values) => headers[name] = values.join(','),
      );
      final response = await emby.handle(
        RequestOptions(
          path: emby.baseUrl.resolveUri(request.uri).toString(),
          method: request.method,
          headers: headers,
        ),
        request.map(Uint8List.fromList),
      );
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        request.response.headers.set(name, values);
      });
      await request.response.addStream(response.stream);
      await request.response.close();
    });
    jellyfin = JellyfinFakeServer();
    await jellyfin.start();
    plex = FakePlex();
    await plex.start();
  });
  tearDown(() async {
    await embySocket.close(force: true);
    await jellyfin.close();
    await plex.close();
    expect(jellyfin.violations, isEmpty);
  });

  test('acceptance emby login catalog playback stop logout resume', () async {
    final client = EmbyClient(device: device);
    await passwordLogin(client, emby.baseUrl, 'correct-horse');
    final item = emby.items.firstWhere((item) => item.type == 'Movie');
    await playAndStop(client, item.id);
    expect(emby.playbackEvents.map((event) => event.kind), [
      'Playing',
      'Progress',
      'Stopped',
    ]);
    expect(item.playbackPosition, progress);
    expect(emby.releasedPlaybackSessions, hasLength(1));
    await client.logout();
    // Emby logout revokes the remote token; its source owner clears local state.
    await expectLater(client.getUser(), rejected);
    client.clearSession();
    expect(client.hasSession, isFalse);
    await passwordLogin(client, emby.baseUrl, 'correct-horse');
    await resumeAndStop(client, item.id);
    expect(
      emby.lastPlaybackInfoBody!['StartTimeTicks'],
      progress.inMicroseconds * 10,
    );
    await client.logout();
  });

  test('acceptance emby rejects credentials and revoked session', () async {
    final client = EmbyClient(device: device);
    await expectLater(passwordLogin(client, emby.baseUrl, 'bad'), rejected);
    expect(client.hasSession, isFalse);
    await passwordLogin(client, emby.baseUrl, 'correct-horse');
    emby.expireAuthenticatedRequests = true;
    await expectLater(client.getViews(), rejected);
    expect(emby.playbackEvents, isEmpty);
  });

  test(
    'acceptance jellyfin login catalog playback stop logout resume',
    () async {
      final client = JellyfinClient(device: device);
      await passwordLogin(client, jellyfin.url, 'password');
      await playAndStop(client, 'movie-1');
      expect(
        jellyfin.userData['PlaybackPositionTicks'],
        progress.inMicroseconds * 10,
      );
      expect(jellyfin.resources, isEmpty);
      expect(jellyfin.nowPlaying, isEmpty);
      await client.logout();
      expect(client.hasSession, isFalse);
      await passwordLogin(client, jellyfin.url, 'password');
      await resumeAndStop(client, 'movie-1');
      expect(
        jellyfin.requests
            .lastWhere((r) => r.path.endsWith('/PlaybackInfo'))
            .body!['StartTimeTicks'],
        progress.inMicroseconds * 10,
      );
      expect(jellyfin.resources, isEmpty);
      await client.logout();
    },
  );

  test(
    'acceptance jellyfin rejects password cancellation and forbidden playback',
    () async {
      final client = JellyfinClient(device: device);
      await expectLater(passwordLogin(client, jellyfin.url, 'bad'), rejected);
      expect(client.hasSession, isFalse);
      final attempt = await client.begin(
        AuthorizationMethod.quickConnect,
        server: jellyfin.url,
      );
      await attempt.cancel();
      jellyfin.quickAuthorized = true;
      expect(await attempt.poll(), AuthorizationStatus.cancelled);
      await expectLater(() => attempt.exchange(), rejected);
      await passwordLogin(client, jellyfin.url, 'password');
      jellyfin.nextStatus = 403;
      await expectLater(client.getPlaybackInfo(itemId: 'movie-1'), rejected);
      expect(jellyfin.resources, isEmpty);
      expect(jellyfin.userData['PlaybackPositionTicks'], 123456780);
    },
  );

  Future<(PlexAuthentication, CloudAccount, Map<String, Map<String, dynamic>>)>
  account() async {
    final credentials = <String, Map<String, dynamic>>{};
    final auth = PlexAuthentication(
      device: device,
      accountUrl: plex.url,
      homeUrl: plex.url,
      readCredential: (ref) async => credentials[ref],
      writeCredential: (ref, value) async {
        credentials[ref] = value;
      },
      deleteCredential: (ref) async {
        credentials.remove(ref);
      },
    );
    final attempt = await auth.begin(AuthorizationMethod.browserPin);
    expect(await attempt.poll(), AuthorizationStatus.pending);
    plex.authorized = true;
    expect(await attempt.poll(), AuthorizationStatus.authorized);
    final grant = await attempt.exchange() as CloudAuthorizationGrant;
    return (auth, grant.account, credentials);
  }

  Future<PlexClient> attach(
    PlexAuthentication auth,
    CloudAccount account,
    Map<String, Map<String, dynamic>> credentials,
  ) async {
    final resource = (await auth.discoverResources(account)).single;
    final token =
        credentials[resource.resourceCredentialRef]!['accessToken'] as String;
    final client = PlexClient(device: device)
      ..attachSession(
        baseUrl: plex.url,
        accessToken: token,
        userId: resource.user.id,
      );
    client.bindVerifiedIdentity(
      await auth.verifyResourceIdentity(
        cloudCredentialRef: account.credentialRef,
        resourceCredentialRef: resource.resourceCredentialRef,
        cloudAccountId: account.id,
        serverId: resource.server.id,
        userId: resource.user.id,
        resourceToken: token,
        connection: plex.url,
      ),
    );
    expect((await client.getUser()).id, resource.user.id);
    return client;
  }

  test('acceptance plex login catalog playback stop logout resume', () async {
    final (auth, cloud, credentials) = await account();
    var client = await attach(auth, cloud, credentials);
    await playAndStop(client, '42');
    expect(
      plex.playbackOffsets['owner-resource']!['42'],
      progress.inMilliseconds,
    );
    expect(
      plex.requests
          .where((r) => r.path == '/:/timeline')
          .map((r) => r.query['state']),
      ['playing', 'playing', 'stopped'],
    );
    expect(plex.sessions, isEmpty);
    expect(plex.stops, 1);
    await client.logout();
    expect(client.hasSession, isFalse);
    final restored = await auth.restoreAccount(cloud.credentialRef);
    client = await attach(auth, restored, credentials);
    await resumeAndStop(client, '42');
    expect(
      plex.requests
          .lastWhere((r) => r.path.endsWith('/decision'))
          .query['offset'],
      '37.345',
    );
    expect(plex.sessions, isEmpty);
    // A Home user must not inherit the owner's resume offset.
    final users = await auth.homeUsers(cloud);
    final child = (await auth.switchHomeUser(
      cloud,
      users.last,
      pin: '1234',
    )).single;
    final childClient = PlexClient(device: device)
      ..attachSession(
        baseUrl: plex.url,
        accessToken:
            credentials[child.resourceCredentialRef]!['accessToken'] as String,
        userId: child.user.id,
      );
    expect(
      (await childClient.getItem('42')).resumePosition,
      const Duration(milliseconds: 12345),
    );
    await client.logout();
    await auth.revokeAccount(cloud);
    expect(credentials.containsKey(cloud.credentialRef), isFalse);
  });

  test(
    'acceptance plex rejects Home PIN shared revocation and transcode',
    () async {
      final (auth, cloud, credentials) = await account();
      final users = await auth.homeUsers(cloud);
      await expectLater(
        auth.switchHomeUser(cloud, users.last, pin: 'bad'),
        rejected,
      );
      expect(
        credentials.values.where((value) => value['kind'] == 'home'),
        isEmpty,
      );
      plex.sharedDenied = true;
      await expectLater(auth.discoverResources(cloud), rejected);
      plex.sharedDenied = false;
      final client = await attach(auth, cloud, credentials);
      plex.transcodeDenied = true;
      await expectLater(
        client.getPlaybackInfo(itemId: '42', forceTranscode: true),
        rejected,
      );
      expect(plex.sessions, isEmpty);
      expect(plex.playbackOffsets, isEmpty);
    },
  );

  test(
    'acceptance plex discovers owned and shared without granting Home ownership',
    () async {
      plex.includeOwnedResource = true;
      final (auth, cloud, credentials) = await account();
      final resources = await auth.discoverResources(cloud);
      expect(resources.map((resource) => resource.server.id), [
        'server-a',
        'server-b',
      ]);
      // Discovery does not attach either resource to a source client.
      final client = PlexClient(device: device);
      expect(client.hasSession, isFalse);
      final selected = resources.last;
      final connection = selected.connections.single.uri;
      final token =
          credentials[selected.resourceCredentialRef]!['accessToken'] as String;
      client.attachSession(
        baseUrl: connection,
        accessToken: token,
        userId: selected.user.id,
      );
      client.bindVerifiedIdentity(
        await auth.verifyResourceIdentity(
          cloudCredentialRef: cloud.credentialRef,
          resourceCredentialRef: selected.resourceCredentialRef,
          cloudAccountId: cloud.id,
          serverId: selected.server.id,
          userId: selected.user.id,
          resourceToken: token,
          connection: connection,
        ),
      );
      expect((await client.getUser()).id, selected.user.id);
      expect(client.baseUrl, connection);
      expect(await client.getViews(), isNotEmpty);
      final users = await auth.homeUsers(cloud);
      final child = await auth.switchHomeUser(cloud, users.last, pin: '1234');
      expect(child.map((resource) => resource.server.id), ['server-a']);
      expect(child.single.homeUserId, '2');
    },
  );
}
