import '../helpers/region_access_fixture.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';
import 'package:rillight/plex/plex_codec.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'Rillight test',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);
const caps = PlaybackCapabilities(h264: true, aac: true);
Matcher forbidden = isA<MediaServerException>().having(
  (e) => e.kind,
  'kind',
  MediaServerFailureKind.forbidden,
);
void main() {
  late FakePlex fake;
  late PlexClient client;
  late PlexAuthentication auth;
  late Map<String, Map<String, dynamic>> store;
  setUp(() async {
    fake = FakePlex();
    await fake.start();
    client = PlexClient(device: device)
      ..attachSession(
        baseUrl: fake.url,
        accessToken: 'owner-resource',
        userId: '1',
      );
    store = {};
    auth = PlexAuthentication(
      device: device,
      accountUrl: fake.url,
      homeUrl: fake.url,
      readCredential: (ref) async => store[ref],
      writeCredential: (ref, value) async {
        store[ref] = value;
      },
      deleteCredential: (ref) async {
        store.remove(ref);
      },
    );
  });
  tearDown(() async {
    await fake.close();
  });
  Future<CloudAccount> authorize() async {
    final attempt = await auth.begin(AuthorizationMethod.browserPin);
    fake.authorized = true;
    await attempt.poll();
    return ((await attempt.exchange()) as CloudAuthorizationGrant).account;
  }

  Future<PlexVerifiedResourceIdentity> verify(
    CloudAccount account,
    AuthorizedServerResource resource, {
    String? token,
    String? userId,
    String? homeUserId,
  }) => auth.verifyResourceIdentity(
    cloudCredentialRef: account.credentialRef,
    resourceCredentialRef: resource.resourceCredentialRef,
    cloudAccountId: account.id,
    serverId: resource.server.id,
    userId: userId ?? resource.user.id,
    homeUserId: homeUserId ?? resource.homeUserId,
    resourceToken:
        token ??
        store[resource.resourceCredentialRef]!['accessToken'] as String,
    connection: fake.url,
  );

  test(
    'search uses full filtered media query beyond default hubs and subsequent page',
    () async {
      fake.catalog = [
        for (var n = 0; n < 90; n++)
          {
            ...fake.movie,
            'ratingKey': '${100 + n}',
            'title': 'Needle $n',
            'viewCount': n % 3 == 0 ? 1 : 0,
          },
        {...fake.movie, 'ratingKey': '999', 'title': 'Unrelated'},
      ];
      // This is the real structure that defeated the original implementation.
      final response = await Dio().getUri(
        fake.url.replace(
          path: '${fake.url.path}/hubs/search',
          queryParameters: {'query': 'Needle'},
        ),
        options: Options(
          headers: {
            'Accept': 'application/json',
            'X-Plex-Token': 'owner-resource',
          },
        ),
      );
      final hub = (response.data['MediaContainer']['Hub'] as List).single;
      expect(hub['Metadata'], hasLength(3));
      expect(hub['more'], true);
      expect(hub['totalSize'], 90);
      final first = await client.queryItems(
        searchTerm: 'Needle',
        includeItemTypes: 'Movie',
        filters: ['IsUnplayed'],
        limit: 40,
        startIndex: 0,
      );
      final second = await client.queryItems(
        searchTerm: 'Needle',
        includeItemTypes: 'Movie',
        filters: ['IsUnplayed'],
        limit: 40,
        startIndex: 40,
      );
      expect(first.totalRecordCount, 60);
      expect(first.items, hasLength(40));
      expect(second.items, hasLength(20));
      expect({
        ...first.items.map((v) => v.id),
        ...second.items.map((v) => v.id),
      }, hasLength(60));
      expect(
        [...first.items, ...second.items].every((v) => !v.userData.played),
        true,
      );
      expect(fake.requests.last.path, '/library/all');
      expect(fake.requests.last.query['title'], 'Needle');
      expect(
        (await client.searchByName('Needle', startIndex: 80)),
        hasLength(10),
      );
    },
  );

  test(
    'genre display labels resolve to each library tag ID and unknown labels stay empty',
    () async {
      fake.catalog = [
        fake.movie,
        {
          ...fake.movie,
          'ratingKey': '44',
          'type': 'episode',
          'librarySectionID': 2,
          'Genre': [
            {'id': 27, 'tag': 'Drama'},
          ],
        },
        {
          ...fake.movie,
          'ratingKey': '45',
          'type': 'episode',
          'librarySectionID': 2,
          'Genre': [
            {'id': 28, 'tag': 'Comedy'},
          ],
        },
      ];
      expect(await client.getLibraryGenres('section:1'), ['Drama']);
      final movie = await client.queryItems(
        parentId: 'section:1',
        genres: ['Drama'],
      );
      expect(movie.items.map((v) => v.id), ['42']);
      expect(fake.requests.last.query['genre'], '17');
      final tv = await client.queryItems(
        parentId: 'section:2',
        genres: ['Drama'],
      );
      expect(tv.items.map((v) => v.id), ['44']);
      expect(fake.requests.last.query['genre'], '27');
      final all = await client.queryItems(genres: ['Drama']);
      expect(all.items.map((v) => v.id), ['42', '44']);
      expect(
        (await client.queryItems(
          parentId: 'section:1',
          genres: ['Unknown'],
        )).items,
        isEmpty,
      );
    },
  );

  test(
    'owner token cannot be bound to child, including forged local resource record',
    () async {
      final account = await authorize();
      final owner = (await auth.discoverResources(account)).single;
      client.attachSession(
        baseUrl: fake.url,
        accessToken: 'owner-resource',
        userId: '2',
      );
      await expectLater(client.getUser(), throwsA(forbidden));
      await expectLater(
        verify(account, owner, userId: '2', homeUserId: '2'),
        throwsA(forbidden),
      );
      final child = (await auth.switchHomeUser(
        account,
        (await auth.homeUsers(account)).last,
        pin: '1234',
      )).single;
      store[child.resourceCredentialRef]!['accessToken'] = 'owner-resource';
      await expectLater(
        verify(account, child, token: 'owner-resource'),
        throwsA(forbidden),
      );
    },
  );

  test(
    'live Home proof grants restricted child and attach invalidates old proof',
    () async {
      final account = await authorize();
      final child = (await auth.switchHomeUser(
        account,
        (await auth.homeUsers(account)).last,
        pin: '1234',
      )).single;
      final proof = await verify(account, child);
      client.attachSession(
        baseUrl: fake.url,
        accessToken: 'child-resource',
        userId: '2',
      );
      client.bindVerifiedIdentity(proof);
      expect((await client.getUser()).name, 'Child');
      expect((await client.getViews()).map((v) => v.id), ['section:1']);
      expect((await client.withRequestGuard(() {}).getUser()).id, '2');
      client.attachSession(
        baseUrl: fake.url,
        accessToken: 'owner-resource',
        userId: '2',
      );
      expect(() => client.bindVerifiedIdentity(proof), throwsA(forbidden));
      await expectLater(client.getUser(), throwsA(forbidden));
      fake.expireHome = true;
      await expectLater(
        verify(account, child),
        throwsA(
          isA<MediaServerException>().having(
            (e) => e.kind,
            'kind',
            MediaServerFailureKind.authorizationExpired,
          ),
        ),
      );
      expect(fake.refreshes, 0);
    },
  );

  test('live resources revocation rejects formerly stored binding', () async {
    final account = await authorize();
    final resource = (await auth.discoverResources(account)).single;
    final proof = await verify(account, resource);
    client.bindVerifiedIdentity(proof);
    expect((await client.getUser()).id, '1');
    fake.sharedDenied = true;
    await expectLater(verify(account, resource), throwsA(forbidden));
  });

  test(
    'source authority commit and restore both require live Plex resource binding',
    () async {
      final account = await authorize();
      final child = (await auth.switchHomeUser(
        account,
        (await auth.homeUsers(account)).last,
        pin: '1234',
      )).single;
      final savedStore = MemoryServerListStore();
      final credentialStore = MemoryCredentialStore();
      SourceSessionRegistry registry() => SourceSessionRegistry(
        access: TestRegionAccessController(),
        store: savedStore,
        credentials: credentialStore,
        createClient: () => PlexClient(device: device),
        createProviderClient: (_) => PlexClient(device: device),
        sessionIdentityVerifier: (server, value, attached) async {
          final proof = await auth.verifyResourceIdentity(
            cloudCredentialRef: server.cloudCredentialRef!,
            resourceCredentialRef: server.resourceCredentialRef!,
            cloudAccountId: server.cloudAccountId!,
            serverId: server.verifiedServerId!,
            userId: value.userId,
            resourceToken: value.accessToken,
            homeUserId: server.homeUserId,
            connection: Uri.parse(server.baseUrl),
          );
          (attached as PlexClient).bindVerifiedIdentity(proof);
        },
      );
      final sourceRegistry = registry();
      addTearDown(sourceRegistry.dispose);
      Future<SourceSession> commit(String token) async {
        final attempt = await sourceRegistry.beginAuthorization(
          serviceType: MediaServerType.plex,
          region: AccessRegion.ordinary,
        );
        final server = SavedServer(
          id: attempt.id,
          name: 'Shared',
          username: 'Child',
          serviceType: MediaServerType.plex,
          verifiedServerId: 'server-a',
          cloudAccountId: account.id,
          cloudCredentialRef: account.credentialRef,
          homeUserId: '2',
          resourceCredentialRef: child.resourceCredentialRef,
          lines: [ServerLine(id: 'local', address: fake.url.toString())],
        );
        return sourceRegistry.commitAuthorization(
          attempt,
          server: server,
          value: StoredCredentials(
            accessToken: token,
            userId: '2',
            username: 'Child',
            serviceType: MediaServerType.plex,
            cloudAccountId: account.id,
            cloudCredentialRef: account.credentialRef,
            homeUserId: '2',
            resourceCredentialRef: child.resourceCredentialRef,
          ),
        );
      }

      await expectLater(commit('owner-resource'), throwsA(forbidden));
      final session = await commit('child-resource');
      expect(session.account.userId, '2');
      final restored = registry();
      addTearDown(restored.dispose);
      await restored.load();
      final resumed = await restored.ensureSession(
        session.account.configuredServerId,
      );
      expect((await resumed.client.getViews()).map((v) => v.id), ['section:1']);
      fake.sharedDenied = true;
      final refused = registry();
      addTearDown(refused.dispose);
      await refused.load();
      await expectLater(
        refused.ensureSession(session.account.configuredServerId),
        throwsA(forbidden),
      );
    },
  );

  test(
    'capability decision follows selected audio in the located Part only',
    () async {
      fake.secondAudioCodec = 'dts';
      fake.additionalUnsupportedAudio = true;
      final first = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        audioStreamIndex: 12,
      );
      expect(
        client.resolvePlayback(info: first, itemId: '42')!.playMethod,
        PlayMethod.directPlay,
      );
      expect(fake.requests.any((r) => r.path.endsWith('/decision')), false);
      final second = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        startPosition: const Duration(seconds: 62),
        audioStreamIndex: 22,
      );
      expect(
        client.resolvePlayback(info: second, itemId: '42')!.playMethod,
        PlayMethod.transcode,
      );
      expect(fake.requests.last.query['partIndex'], '1');
      expect(fake.requests.last.query['directStreamAudio'], '0');
      expect(second.primarySource!.streamByIndex(22)!.codec, 'aac');
      final defaultAudio = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        startPosition: const Duration(seconds: 62),
      );
      expect(defaultAudio.primarySource!.defaultAudioStreamIndex, 22);
      expect(fake.requests.last.query['directStreamAudio'], '0');
      final chosenUnsupported = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        audioStreamIndex: 14,
      );
      expect(
        client
            .resolvePlayback(info: chosenUnsupported, itemId: '42')!
            .playMethod,
        PlayMethod.transcode,
      );
    },
  );

  test(
    'external ASS burning maps actual delivery and turning off renegotiates without burn',
    () async {
      fake.subtitleCodec = 'ass';
      final info = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        subtitleStreamIndex: 13,
      );
      final subtitle =
          info.primarySource!.streamByIndex(13)! as PlexNegotiatedStream;
      expect(fake.requests.last.query['subtitles'], 'burn');
      expect(subtitle.deliveryMethod, 'Encode');
      expect(subtitle.deliveryUrl, isNull);
      expect(subtitle.isExternal, false);
      expect(subtitle.index, 13);
      expect(subtitle.playbackIndex, 2);
      final backend = RillightVideoBackend();
      addTearDown(backend.dispose);
      expect(
        backend.transcodeSubtitleDelivery(subtitle),
        TranscodeSubtitleDelivery.burnIn,
      );
      final off = await client.getPlaybackInfo(
        itemId: '42',
        capabilities: caps,
        subtitleStreamIndex: -1,
        forceTranscode: true,
      );
      expect(off.primarySource!.defaultSubtitleStreamIndex, -1);
      expect(fake.requests.last.query['subtitles'], 'none');
      expect(
        off.primarySource!.subtitleStreams.any(
          (s) => s.deliveryMethod == 'Encode',
        ),
        false,
      );
    },
  );

  for (final entry in {
    'segments-subs': 'Hls',
    'sidecar-subs': 'External',
    'embedded': 'Embed',
  }.entries) {
    test(
      'decision ${entry.key} preserves delivery codec and source/output association',
      () async {
        fake.subtitleLocation = entry.key;
        final info = await client.getPlaybackInfo(
          itemId: '42',
          forceTranscode: true,
          subtitleStreamIndex: 13,
        );
        final stream =
            info.primarySource!.streamByIndex(13)! as PlexNegotiatedStream;
        expect(stream.deliveryMethod, entry.value);
        expect(stream.index, 13);
        expect(stream.playbackIndex, 2);
        final backend = RillightVideoBackend();
        addTearDown(backend.dispose);
        expect(
          backend.transcodeSubtitleDelivery(stream),
          entry.value == 'External'
              ? TranscodeSubtitleDelivery.external
              : TranscodeSubtitleDelivery.manifest,
        );
        if (entry.key != 'embedded') expect(stream.codec, 'webvtt');
        if (entry.value == 'External') {
          expect(stream.deliveryUrl, endsWith('/transcoded/subtitle.vtt'));
        }
        if (entry.value == 'Hls') expect(stream.isExternal, false);
      },
    );
  }
  test(
    'unavailable selected subtitle fails and releases preflight resource',
    () async {
      fake.subtitleDecision = 'unavailable';
      await expectLater(
        client.getPlaybackInfo(
          itemId: '42',
          forceTranscode: true,
          subtitleStreamIndex: 13,
        ),
        throwsA(forbidden),
      );
      expect(fake.sessions, isEmpty);
      expect(fake.stops, 1);
    },
  );
}
