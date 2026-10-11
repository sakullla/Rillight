import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_codec.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/media_server/serialization.dart';
import 'package:rillight/player/playback_persistence.dart';
import '../emby/fake_emby_server.dart';

class _CatalogProvider implements MediaServerClient {
  @override
  MediaServerType get serviceType => MediaServerType.plex;
  String? parent;
  @override
  Future<MediaItemPage> queryItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    String fields = MediaServerClient.gridFields,
    String imageTypes = MediaServerClient.imageTypes,
  }) async {
    parent = parentId;
    return const MediaItemPage(
      items: [
        MediaItem(
          id: 'not/a-guid?1',
          name: 'Film',
          type: 'Movie',
          runtime: Duration(minutes: 91),
        ),
      ],
      totalRecordCount: 1,
      pagination: CapabilityStatus(
        CapabilityAvailability.restricted,
        reason: 'synthetic account limit',
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
    'catalog consumer calls an independent provider and preserves opaque IDs and capability reason',
    () async {
      final provider = _CatalogProvider();
      final json = await executeCatalogRequest(
        provider,
        catalogItemsRequest(userId: 'u', parentId: 'library/opaque'),
      );
      final page = parseCatalogPage(json);
      expect(provider.parent, 'library/opaque');
      expect(page.items.single.id, 'not/a-guid?1');
      expect(page.items.single.runtime, const Duration(minutes: 91));
      expect(page.pagination.availability, CapabilityAvailability.restricted);
      expect(page.pagination.reason, 'synthetic account limit');
      await expectLater(
        executeCatalogRequest(provider, const CatalogRequest('/Users/u/Items')),
        throwsArgumentError,
      );
    },
  );

  test(
    'business serialization uses microseconds and keeps all catalog metadata',
    () {
      final item = decodeEmbyMediaItem({
        'Id': '001/opaque',
        'Name': 'Movie',
        'Type': 'Movie',
        'RunTimeTicks': 90123450,
        'ProviderIds': {'Tmdb': '007'},
        'UserData': {'PlaybackPositionTicks': 11234560},
        'Chapters': [
          {'Name': 'Chapter', 'StartPositionTicks': 1234560},
        ],
      });
      final encoded = encodeMediaItem(item);
      expect(encoded.containsKey('RunTimeTicks'), isFalse);
      final restored = decodeMediaItem(encoded);
      expect(restored.runtime, const Duration(microseconds: 9012345));
      expect(
        restored.userData.playbackPosition,
        const Duration(microseconds: 1123456),
      );
      expect(
        restored.chapters.single.startPosition,
        const Duration(microseconds: 123456),
      );
      expect(restored.providerIds, {'Tmdb': '007'});
    },
  );

  test(
    'part boundaries and unknown durations never fabricate a global seek',
    () {
      final authorization = ResourceAuthorization(headersByOrigin: const {});
      MediaPart part(String id, Duration? duration) => MediaPart(
        id: id,
        duration: duration,
        resource: AuthorizedMediaResource(
          url: 'https://synthetic.invalid/$id',
          authorization: authorization,
        ),
      );
      final timeline = MediaTimeline([
        part('a', const Duration(seconds: 10)),
        part('b', const Duration(seconds: 20)),
      ]);
      expect(timeline.duration, const Duration(seconds: 30));
      expect(timeline.locate(const Duration(seconds: 10))!.index, 1);
      expect(
        timeline.locate(const Duration(seconds: 12))!.local,
        const Duration(seconds: 2),
      );
      expect(timeline.locate(const Duration(seconds: 31)), isNull);
      expect(
        MediaTimeline([
          part('a', null),
          part('b', const Duration(seconds: 20)),
        ]).locate(const Duration(seconds: 12)),
        isNull,
      );
    },
  );

  test('resource cleanup coalesces and failure remains retryable', () async {
    var attempts = 0;
    final gate = Completer<void>();
    final lease = PlaybackResourceLease(
      id: 'own-session',
      release: () async {
        attempts++;
        if (attempts == 1) await gate.future;
      },
    );
    final first = lease.release(), second = lease.release();
    expect(identical(first, second), isTrue);
    final failed = expectLater(first, throwsStateError);
    gate.completeError(StateError('server offline'));
    await failed;
    expect(lease.isReleased, isFalse);
    await lease.release();
    await lease.release();
    expect(attempts, 2);
    expect(lease.isReleased, isTrue);
  });

  test('redirect authorization is origin-specific and preserves public UA', () {
    final auth = ResourceAuthorization(
      headersByOrigin: const {
        'https://server.invalid': {'X-Plex-Token': 'synthetic'},
      },
      publicHeaders: const {'User-Agent': 'test'},
    );
    expect(
      auth.headersFor(Uri.parse('https://server.invalid/part'))['X-Plex-Token'],
      'synthetic',
    );
    expect(auth.headersFor(Uri.parse('https://other.invalid/part')), {
      'User-Agent': 'test',
    });
    expect(auth.headersFor(Uri.parse('http://server.invalid/part')), {
      'User-Agent': 'test',
    });
  });

  test(
    'old Emby snapshot reads ticks while current snapshot records provider and microseconds',
    () {
      final old = PlaybackSessionSnapshot.fromJson({
        'itemId': 'i',
        'mediaSourceId': 'm',
        'playSessionId': 'p',
        'positionTicks': 12345678,
        'baseUrl': 'https://synthetic.invalid',
        'userId': 'u',
        'playMethod': 'Transcode',
      })!;
      expect(old.serviceType, MediaServerType.emby);
      expect(old.position, const Duration(microseconds: 1234567));
      expect(old.toJson()['positionUs'], 1234567);
      expect(old.toJson().containsKey('positionTicks'), isFalse);
      expect(
        PlaybackSessionSnapshot.fromJson({
          ...old.toJson(),
          'serviceType': 'unknown',
        }),
        isNull,
      );
    },
  );

  test(
    'Emby cleanup targets only its session and succeeds independently of stopped reporting',
    () async {
      final server = FakeEmbyServer();
      final client = EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'device',
          version: '1',
        ),
        dio: Dio()..httpClientAdapter = FakeEmbyAdapter([server]),
      );
      final info = await client.getPublicInfo(server.baseUrl);
      final auth = await client.authenticateByName(
        baseUrl: server.baseUrl,
        username: 'alice',
        password: 'correct-horse',
        serverId: info.id,
      );
      client.attachSession(
        baseUrl: server.baseUrl,
        accessToken: auth.accessToken,
        userId: auth.user.id,
      );
      final playback = await client.getPlaybackInfo(
        itemId: 'movie-transcode',
        startPosition: const Duration(seconds: 3),
      );
      expect(playback.resources, isNotNull);
      final report = PlaybackReport(
        itemId: 'movie-transcode',
        mediaSourceId: playback.mediaSources.first.id,
        playSessionId: playback.playSessionId,
        playMethod: PlayMethod.transcode,
        position: const Duration(seconds: 3),
      );
      server.stoppedStatus = 500;
      await expectLater(client.stopPlayback(report), throwsA(isA<Exception>()));
      expect(server.releasedPlaybackSessions, [playback.playSessionId]);
      await client.releasePlayback(report);
      expect(server.releasedPlaybackSessions, hasLength(1));
      expect(
        server.requests.where((r) => r.contains('ActiveEncodings')).single,
        contains('PlaySessionId='),
      );
    },
  );
}
