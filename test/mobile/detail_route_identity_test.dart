import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/home/catalog_keys.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  testWidgets(
    'season banner prefers wide artwork and failures never touch the poster',
    (tester) async {
      isolateImageCache();
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = FakeEmbyServer();
      server.items
              .firstWhere((item) => item.id == 'series-friends')
              .backdropImageTag =
          'shared-series';
      server.setSeasons('series-friends', const [
        FakeSeason(
          id: 'season-friends-1',
          name: '第 1 季',
          indexNumber: 1,
          primaryImageTag: 'one-poster',
          backdropImageTag: 'one-backdrop',
        ),
        FakeSeason(
          id: 'season-friends-2',
          name: '第 2 季',
          indexNumber: 2,
          primaryImageTag: 'two-poster',
        ),
        FakeSeason(id: 'season-friends-3', name: '第 3 季', indexNumber: 3),
      ]);
      final auth = _authFor(server);
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      await tester.runAsync(() => _allowLibraries(auth));
      final app = RillightApp(
        auth: auth,
        environment: PresentationEnvironment.phone,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        auth.dispose();
      });
      await tester.pumpWidget(app);
      app.router.go('/item/series-friends?season=season-friends-1');
      await _artworkFrames(tester);
      MediaImage header() => tester.widget<MediaImage>(
        find.descendant(
          of: find.byKey(PhoneItemBanner.bannerKey),
          matching: find.byType(MediaImage),
        ),
      );
      // Entering a series keeps its artwork until the user selects a season.
      expect(header().item.id, 'series-friends');
      expect(
        server.requests.any(
          (r) => r.contains('/series-friends/Images/Backdrop'),
        ),
        isTrue,
      );
      server.requests.clear();
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-2')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-2');
      // 只有竖版季海报时复用已缓存的剧集横版背景。
      expect(header().item.parentBackdropItemId, 'series-friends');
      expect(
        server.requests.any(
          (r) => r.contains('/season-friends-2/Images/Primary'),
        ),
        isFalse,
      );
      server.requests.clear();
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-3')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-3');
      // 无图季复用上一季已缓存的剧集背景,不为季本身发起任何图片请求。
      expect(
        server.requests.any((r) => r.contains('/season-friends-3/Images/')),
        isFalse,
      );
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-1')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-1');
      expect(
        server.requests.any(
          (r) => r.contains('/season-friends-1/Images/Backdrop'),
        ),
        isTrue,
      );
      // 季海报失效不再影响横幅:共享背景直接命中,失效的季海报根本不被请求,
      // 也不会残留上一季旧图。
      server.items
              .firstWhere((item) => item.id == 'season-friends-2')
              .primaryImageTag =
          'two-failed';
      server.failingImageIds.add('season-friends-2');
      app.router.go('/item/movie-up');
      await _artworkFrames(tester);
      server.requests.clear();
      app.router.go('/item/series-friends?season=season-friends-2');
      await _artworkFrames(tester);
      expect(header().item.id, 'series-friends');
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-1')));
      await _artworkFrames(tester);
      server.requests.clear();
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-2')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-2');
      expect(header().item.primaryImageTag, 'two-failed');
      // 横幅直接复用缓存的剧集背景,失效的季海报根本不被请求。
      expect(
        server.requests.any((r) => r.contains('/season-friends-2/Images/')),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} direct detail navigation replaces the displayed item',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = FakeEmbyServer();
        final auth = _authFor(server);
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        await tester.runAsync(() => _allowLibraries(auth));
        final app = RillightApp(auth: auth, environment: environment);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
          auth.dispose();
        });
        await tester.pumpWidget(app);
        for (final id in ['movie-up', 'movie-inception']) {
          app.router.go('/item/$id');
          await _artworkFrames(tester);
          expect(
            tester
                .widget<DetailAlbumStrip>(find.byType(DetailAlbumStrip))
                .item
                .id,
            id,
          );
        }
      },
      tags: ['integration'],
    );
  }
}

AuthController _authFor(FakeEmbyServer server) {
  final adapter = FakeEmbyAdapter([server]);
  EmbyClient client() => EmbyClient(
    device: const EmbyDeviceInfo(
      clientName: 'test',
      deviceName: 'test',
      deviceId: 'route-identity',
      version: '1',
    ),
    dio: dioForFakeEmby(adapter),
  );
  final credentials = MemoryCredentialStore();
  final servers = MemoryServerListStore();
  return AuthController(
    client: client(),
    credentials: credentials,
    servers: servers,
    sources: SourceSessionRegistry(
      access: RegionAccessController(),
      store: servers,
      credentials: credentials,
      createClient: client,
    ),
  );
}

Future<void> _allowLibraries(AuthController auth) =>
    auth.sources.configureScope(
      auth.session!.server.id,
      participates: true,
      libraryIds: {'view-tv', 'view-movies'},
    );

Future<void> _artworkFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
