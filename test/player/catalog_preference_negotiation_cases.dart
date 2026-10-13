import '../helpers/region_access_fixture.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

const _device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'catalog-preference',
  deviceId: 'catalog-preference-device',
  version: '1',
);

/// Transport-only fake: catalog and playback decoding use the real providers.
class _CatalogAdapter implements HttpClientAdapter {
  bool failStartupCatalog = false;
  bool removeSavedVersion = false;
  int movieRequests = 0;
  final negotiations = <Map<String, dynamic>>[];
  final unexpected = <String>[];

  Map<String, dynamic> _source(String id) => {
    'Id': id,
    'Name': id,
    'Type': 'Default',
    'Protocol': 'File',
    'Path': '/media/$id.mkv',
    'Container': 'mkv',
    'RunTimeTicks': 600000000,
    'Bitrate': 6000000,
    'SupportsDirectPlay': true,
    'SupportsDirectStream': true,
    'SupportsTranscoding': true,
    'DefaultAudioStreamIndex': 12,
    'DefaultSubtitleStreamIndex': 21,
    'MediaStreams': [
      {
        'Type': 'Video',
        'Index': 0,
        'Codec': 'h264',
        'Width': 1920,
        'Height': 1080,
      },
      for (final index in [12, 14])
        {
          'Type': 'Audio',
          'Index': index,
          'Codec': 'aac',
          'Channels': 2,
          'Language': 'eng',
          'Title': 'Same',
          'DisplayTitle': 'Same',
          'IsDefault': index == 12,
        },
      {
        'Type': 'Subtitle',
        'Index': 21,
        'Codec': 'ass',
        'Language': 'eng',
        'IsDefault': true,
      },
    ],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    var status = 200;
    Object payload = <String, dynamic>{};
    if (options.method == 'GET' && path.endsWith('/Items/movie')) {
      movieRequests++;
      // Let runtime establish membership first; fail controller catalog loading.
      if (failStartupCatalog && movieRequests >= 2) {
        status = 503;
        payload = {'Message': 'Synthetic catalog outage'};
      } else {
        payload = {
          'Id': 'movie',
          'Name': 'Catalog fixture',
          'Type': 'Movie',
          'MediaType': 'Video',
          'ParentId': 'library',
          'RunTimeTicks': 600000000,
          'MediaSources': [
            _source('first'),
            if (!removeSavedVersion) _source('second'),
          ],
        };
      }
    } else if (options.method == 'GET' && path.endsWith('/Items/library')) {
      payload = {'Id': 'library', 'Name': 'Films', 'Type': 'CollectionFolder'};
    } else if (options.method == 'GET' &&
        (path.endsWith('/Users/user') || path.endsWith('/Users/Me'))) {
      payload = {'Id': 'user', 'Name': 'Viewer'};
    } else if (options.method == 'GET' &&
        path.endsWith('/MediaSegments/movie')) {
      payload = {'Items': <Object>[]};
    } else if (options.method == 'POST' && path.endsWith('/PlaybackInfo')) {
      final body = Map<String, dynamic>.from(
        (options.data is String ? jsonDecode(options.data) : options.data)
            as Map,
      );
      negotiations.add(body);
      payload = {
        'PlaySessionId': 'synthetic-session',
        'MediaSources': [_source(body['MediaSourceId'] as String? ?? 'first')],
      };
    } else if (path.contains('/Sessions/Playing') ||
        path.endsWith('/Videos/ActiveEncodings')) {
      // Playback reports and release are accepted only on provider routes.
    } else {
      unexpected.add('${options.method} $path');
      status = 404;
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({PlayerController player, FakeVideoBackend backend})> _player(
  MediaServerType type,
  _CatalogAdapter adapter,
) async {
  MediaServerClient createClient() {
    final dio = Dio()..httpClientAdapter = adapter;
    return type == MediaServerType.emby
        ? EmbyClient(device: _device, dio: dio)
        : JellyfinClient(device: _device, dio: dio);
  }

  final servers = MemoryServerListStore(
    ServerListSnapshot(
      servers: [
        SavedServer(
          id: 'source',
          name: type.name,
          username: 'Viewer',
          serviceType: type,
          verifiedServerId: 'server',
          scopeKnown: true,
          libraryIds: const ['library'],
          lines: const [
            ServerLine(id: 'line', address: 'https://catalog.test'),
          ],
        ),
      ],
    ),
  );
  final credentials = MemoryCredentialStore({
    'source': StoredCredentials(
      serviceType: type,
      accessToken: 'synthetic-resource-token',
      userId: 'user',
      username: 'Viewer',
    ),
  });
  final registry = SourceSessionRegistry(
    access: TestRegionAccessController(),
    store: servers,
    credentials: credentials,
    createClient: createClient,
    createProviderClient: (_) => createClient(),
    sessionIdentityVerifier: (_, _, _) async {},
  );
  await registry.load();
  final session = await registry.ensureSession('source');
  final auth = AuthController(
    client: createClient(),
    credentials: credentials,
    servers: servers,
    sources: registry,
  );
  final history = await HistoryWriter.open(
    registry: registry,
    store: MemoryHistoryStore(),
  );
  addTearDown(() async {
    await history.close();
    auth.dispose();
  });
  final work = SourceReference(account: session.account, itemId: 'movie');
  await history.savePreference(
    SourcePreference(
      owner: work,
      target: SourceReference(
        account: session.account,
        itemId: 'movie',
        mediaSourceId: 'second',
      ),
      libraryId: 'library',
      lineId: 'line',
      settings: const PlayerSeriesPreference(
        mediaSourceId: 'second',
        maxStreamingBitrate: 8000000,
        audioStreamIndex: 14,
        audioLanguage: 'eng',
        audioTitle: 'Same',
        subtitleOff: true,
      ),
    ),
  );
  final backend = FakeVideoBackend(duration: const Duration(seconds: 60));
  final player = PlayerController(
    client: auth.client,
    itemId: 'movie',
    backend: backend,
    window: PlayerWindow(),
    runtime: PlaybackRuntime(auth: auth, history: history),
    autoResume: false,
    settingsStore: MemoryPlayerSettingsStore(),
    snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    openRequest: PlayerOpenRequest(
      itemId: 'movie',
      source: work,
      libraryId: 'library',
    ),
  );
  addTearDown(() async {
    await player.disposeAsync();
    player.dispose();
    expect(adapter.unexpected, isEmpty);
  });
  return (player: player, backend: backend);
}

void main() {
  for (final type in [MediaServerType.emby, MediaServerType.jellyfin]) {
    test(
      '${type.name} first negotiation contains the saved full intent',
      () async {
        final adapter = _CatalogAdapter();
        final fixture = await _player(type, adapter);
        await fixture.player.start();

        expect(fixture.player.error, isNull);
        expect(adapter.negotiations, hasLength(1));
        final request = adapter.negotiations.single;
        expect(request['MediaSourceId'], 'second');
        expect(request['AudioStreamIndex'], 14);
        expect(request['SubtitleStreamIndex'], -1);
        expect(request['MaxStreamingBitrate'], 8000000);
        expect(request['StartTimeTicks'], 0);
        expect(fixture.player.resolved!.mediaSource.id, 'second');
        expect(fixture.player.audioStreamIndex, 14);
        expect(fixture.player.subtitleStreamIndex, isNull);
        expect(fixture.backend.openedUrl, isNotNull);
      },
    );

    test(
      '${type.name} catalog failure cannot fall back to negotiation',
      () async {
        final adapter = _CatalogAdapter()..failStartupCatalog = true;
        final fixture = await _player(type, adapter);
        await fixture.player.start();

        expect(adapter.movieRequests, greaterThanOrEqualTo(2));
        expect(fixture.player.error, PlayerErrorKind.load);
        expect(fixture.player.loadFailure, isNotNull);
        expect(adapter.negotiations, isEmpty);
        expect(fixture.backend.openedUrl, isNull);
      },
    );

    test(
      '${type.name} missing saved version fails before negotiation',
      () async {
        final adapter = _CatalogAdapter()..removeSavedVersion = true;
        final fixture = await _player(type, adapter);
        await fixture.player.start();

        expect(fixture.player.error, isNotNull);
        expect(
          fixture.player.disconnectDetail,
          contains('Source preference requires explicit selection'),
        );
        expect(adapter.negotiations, isEmpty);
        expect(fixture.backend.openedUrl, isNull);
      },
    );
  }
}
