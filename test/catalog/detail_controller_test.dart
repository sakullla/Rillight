import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/detail_controller.dart';

import '../emby/fake_emby_server.dart';

class _SlowSeasonsServer extends FakeEmbyServer {
  final seasonsRequested = Completer<void>();
  final releaseSeasons = Completer<void>();

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (options.uri.queryParameters['IncludeItemTypes'] == 'Season') {
      if (!seasonsRequested.isCompleted) seasonsRequested.complete();
      await releaseSeasons.future;
    }
    return super.handle(options, requestStream);
  }
}

void main() {
  test(
    'series header is ready while season response is still pending',
    () async {
      final server = _SlowSeasonsServer();
      final client = EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: '灯川 Rillight',
          deviceName: 'test',
          deviceId: 'detail-controller-test',
          version: '0.1.0',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      );
      final auth = AuthController(
        client: client,
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final cache = CatalogCache()
        ..debugSetDiskStore(null)
        ..attachSession(serverId: server.serverId, userId: client.userId!);
      final controller = DetailController(
        auth: auth,
        cache: cache,
        itemId: 'series-friends',
      );
      addTearDown(controller.dispose);

      await controller.load();
      await server.seasonsRequested.future;
      expect(controller.item?.id, 'series-friends');
      expect(controller.loading, isFalse);
      expect(controller.seasonsLoading, isTrue);
      expect(
        server.requests.where(
          (entry) => entry.contains('/Items/series-friends?'),
        ),
        hasLength(1),
      );

      final seasonsReady = Completer<void>();
      controller.addListener(() {
        if (controller.seasons.isNotEmpty && !seasonsReady.isCompleted) {
          seasonsReady.complete();
        }
      });
      server.releaseSeasons.complete();
      await seasonsReady.future.timeout(const Duration(seconds: 5));
      expect(controller.seasons, isNotEmpty);
    },
  );
}
