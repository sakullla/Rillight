import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/search/search_controller.dart';

import '../emby/fake_emby_server.dart';
import '../jellyfin/fake_jellyfin_server.dart';

const _device = ClientDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);

class _HeldEmby extends FakeEmbyAdapter {
  _HeldEmby(super.servers);
  Completer<void>? hold;
  final arrived = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    final response = await super.fetch(options, stream, cancelled);
    final gate = hold;
    if (gate != null &&
        (options.uri.path.contains('/Items') ||
            options.uri.path.contains('/Views') ||
            options.uri.path.contains('/Shows'))) {
      if (!arrived.isCompleted) arrived.complete();
      await gate.future;
    }
    return response;
  }
}

void main() {
  late JellyfinFakeServer jellyfin;
  late FakeEmbyServer emby;
  late _HeldEmby adapter;
  late AuthController auth;
  setUp(() async {
    jellyfin = JellyfinFakeServer();
    await jellyfin.start();
    emby = FakeEmbyServer();
    adapter = _HeldEmby([emby]);
    MediaServerClient create(MediaServerType type) => switch (type) {
      MediaServerType.emby => EmbyClient(
        device: _device,
        dio: dioForFakeEmby(adapter),
      ),
      MediaServerType.jellyfin => JellyfinClient(device: _device),
      _ => throw StateError('Unused provider'),
    };
    auth = AuthController(
      client: create(MediaServerType.emby),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
      providerClientFactory: create,
    );
    expect(
      await auth.connect(
        address: emby.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
      isTrue,
    );
  });
  tearDown(() async {
    auth.dispose();
    await jellyfin.close();
    expect(jellyfin.violations, isEmpty);
  });

  Future<void> selectJellyfin() async {
    final flow = ProviderConnectController(auth: auth)
      ..reset(MediaServerType.jellyfin);
    try {
      await flow.password(jellyfin.url.toString(), 'alice', 'password');
      expect(flow.failure, isNull);
      await flow.finish();
      expect(flow.failure, isNull);
      expect(auth.client.serviceType, MediaServerType.jellyfin);
    } finally {
      flow.dispose();
    }
  }

  test(
    'provider switch replaces captured detail client and discards old catalog/search responses',
    () async {
      final catalog = CatalogController(auth: auth);
      final search = SearchController(auth: auth, cache: catalog.cache);
      final oldId = emby.items.firstWhere((i) => i.type == 'Movie').id;
      final detail = DetailController(
        auth: auth,
        cache: catalog.cache,
        itemId: oldId,
      );
      final gate = Completer<void>();
      adapter.hold = gate;
      final oldSearch = search.submit('movie');
      final oldDetail = detail.load();
      final oldCatalog = catalog.reload();
      await adapter.arrived.future;
      await selectJellyfin();
      adapter.hold = null;
      gate.complete();
      await Future.wait([oldSearch, oldDetail, oldCatalog]);
      expect(detail.repository.client.serviceType, MediaServerType.jellyfin);
      expect(detail.item, isNull);
      expect(search.items, isEmpty);
      await search.submit('测试');
      await catalog.reload();
      expect(search.items.map((i) => i.id), contains('movie-1'));
      expect(catalog.latestMovies.items.map((i) => i.id).toList(), ['movie-1']);
      expect(
        jellyfin.requests.any(
          (r) => r.path.endsWith('/Items') && r.query['searchTerm'] == '测试',
        ),
        isTrue,
      );
      detail.dispose();
      search.dispose();
      catalog.dispose();
    },
  );

  test(
    'logout discards pending catalog rows and selected-source previews',
    () async {
      final catalog = CatalogController(auth: auth);
      final gate = Completer<void>();
      adapter.hold = gate;
      final pending = catalog.reload();
      await adapter.arrived.future;
      await auth.logout();
      adapter.hold = null;
      gate.complete();
      await pending;
      expect(catalog.libraries, isEmpty);
      expect(catalog.latestMovies.items, isEmpty);
      expect(catalog.resume.items, isEmpty);
      expect(catalog.librariesLoading, isFalse);
      catalog.dispose();
    },
  );

  test(
    'selected session survives aggregation scope but Home/relogin authority revokes pending requests',
    () async {
      await selectJellyfin();
      final id = auth.session!.server.id;
      await auth.sources.configureScope(
        id,
        participates: false,
        libraryIds: {},
      );
      expect(auth.isLoggedIn, isTrue);
      expect((await auth.client.getItem('movie-1')).id, 'movie-1');
      final old = auth.client;
      final gate = Completer<void>();
      jellyfin.delay = gate;
      jellyfin.arrived = Completer<void>();
      final request = old.getItem('movie-1');
      final rejection = expectLater(request, throwsA(anything));
      await jellyfin.arrived!.future;
      final attempt = await auth.sources.beginAuthorization(
        serviceType: MediaServerType.jellyfin,
        region: AccessRegion.ordinary,
        configuredServerId: id,
      );
      expect(auth.isLoggedIn, isFalse);
      gate.complete();
      await rejection;
      attempt.cancel();
    },
  );
}
