import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/provider_registry.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/playback_persistence.dart';
import 'package:rillight/player/player_window_host.dart';

const device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'test',
  deviceId: 'process-test',
  version: '1',
);

void main() {
  test('pending cleanup snapshot is bounded, release-only and cannot recursively nest', () {
    final primary = PlaybackSessionSnapshot(
      itemId: 'item',
      mediaSourceId: 'version',
      playSessionId: 'active',
      position: const Duration(seconds: 33),
      baseUrl: 'https://primary.test',
      userId: 'primary',
      timestamp: DateTime.utc(2026),
    );
    final child = PlaybackSessionSnapshot(
      itemId: 'target',
      mediaSourceId: 'other',
      playSessionId: 'pending',
      position: Duration.zero,
      baseUrl: 'https://plex.test',
      userId: 'child',
      timestamp: DateTime.utc(2026),
      serviceType: MediaServerType.plex,
      cleanupOnly: true,
    );
    final saved = primary.withPendingCleanups([child]);
    final decoded = PlaybackSessionSnapshot.fromJson(
      jsonDecode(jsonEncode(saved.toJson())),
    )!;
    expect(decoded.playSessionId, 'active');
    expect(decoded.position, const Duration(seconds: 33));
    expect(decoded.pendingCleanups.single.playSessionId, 'pending');
    expect(decoded.pendingCleanups.single.serviceType, MediaServerType.plex);
    expect(decoded.pendingCleanups.single.cleanupOnly, isTrue);
    expect(primary.pendingCleanups, isEmpty);
    expect(() => primary.withPendingCleanups([primary]), throwsFormatException);
    expect(
      PlaybackSessionSnapshot.fromJson({
        ...primary.toJson(),
        'pendingCleanups': [
          {
            ...child.toJson(),
            'pendingCleanups': [child.toJson()],
          },
        ],
      }),
      isNull,
    );
    expect(
      PlaybackSessionSnapshot.fromJson({
        ...primary.toJson(),
        'pendingCleanups': List.filled(
          PlaybackSessionSnapshot.maxPendingCleanups + 1,
          child.toJson(),
        ),
      }),
      isNull,
    );
  });
  for (final type in MediaServerType.values) {
    test(
      '${type.name} standalone factory and launch preserve provider identity',
      () {
        final client = MediaServerProviders.create(type, device);
        expect(client.serviceType, type);
        expect(client.hasSession, isFalse);
        final source = SourceReference(
          account: SourceAccount(
            serviceType: type,
            region: AccessRegion.ordinary,
            configuredServerId: 'configured',
            verifiedServerId: 'server',
            userId: 'user',
          ),
          itemId: 'item',
        );
        final launch = PlayerWindowLaunch(
          request: PlayerOpenRequest(
            itemId: 'item',
            source: source,
            startPosition: const Duration(seconds: 95),
          ),
          serviceType: type,
          baseUrl: 'https://source.test',
          accessToken: 'resource-token',
          userId: 'user',
          device: device,
        );
        final decoded = PlayerWindowLaunch.fromArguments(launch.toArguments());
        expect(decoded.serviceType, type);
        expect(decoded.request.source, source);
        expect(decoded.request.startPosition, const Duration(seconds: 95));
        expect(decoded.accessToken, 'resource-token');
        final json = decoded.toJson();
        expect(json.keys, isNot(contains('authMaterial')));
        expect(json.keys, isNot(contains('signingKey')));
        expect(json.keys, isNot(contains('cloudCredential')));
      },
    );
  }

  test('launch rejects provider and effective-user mismatch', () {
    final source = SourceReference(
      account: const SourceAccount(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
        configuredServerId: 'configured',
        verifiedServerId: 'server',
        userId: 'child',
      ),
      itemId: 'item',
    );
    final launch = PlayerWindowLaunch(
      request: PlayerOpenRequest(itemId: 'item', source: source),
      serviceType: MediaServerType.plex,
      baseUrl: 'https://source.test',
      accessToken: 'resource-token',
      userId: 'child',
      device: device,
    );
    expect(
      () => PlayerWindowLaunch.fromJson({
        ...launch.toJson(),
        'serviceType': 'emby',
      }),
      throwsFormatException,
    );
    expect(
      () =>
          PlayerWindowLaunch.fromJson({...launch.toJson(), 'userId': 'owner'}),
      throwsFormatException,
    );
  });

  test(
    'Jellyfin opaque cleanup handle survives snapshot and report unchanged',
    () {
      const handle =
          'jf-play-v1:eyJkZXZpY2UiOiJ1bmlxdWUiLCJzZXNzaW9uIjoib2xkIn0';
      final snapshot = PlaybackSessionSnapshot(
        itemId: 'item',
        mediaSourceId: 'version',
        playSessionId: handle,
        position: const Duration(seconds: 95),
        serviceType: MediaServerType.jellyfin,
        baseUrl: 'https://source.test',
        userId: 'user',
        timestamp: DateTime.utc(2026),
      );
      final decoded = PlaybackSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
      )!;
      expect(decoded.serviceType, MediaServerType.jellyfin);
      expect(playbackReportFromSnapshot(decoded).playSessionId, handle);
      expect(decoded.position, const Duration(seconds: 95));
    },
  );

  test(
    'legacy snapshot is Emby and unknown providers cannot default to Emby',
    () {
      final json = <String, dynamic>{
        'itemId': 'item',
        'mediaSourceId': 'version',
        'playSessionId': 'session',
        'positionTicks': 10000000,
        'baseUrl': 'https://source.test',
        'userId': 'user',
      };
      expect(
        PlaybackSessionSnapshot.fromJson(json)!.serviceType,
        MediaServerType.emby,
      );
      expect(
        PlaybackSessionSnapshot.fromJson({...json, 'serviceType': 'unknown'}),
        isNull,
      );
      expect(
        PlaybackSessionSnapshot.fromJson({...json, 'serviceType': 42}),
        isNull,
      );
    },
  );
}
