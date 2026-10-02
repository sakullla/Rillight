import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
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
    'selected season artwork precedes shared series artwork and failures fall back',
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
      final auth = AuthController.memory(
        client: EmbyClient(
          device: const EmbyDeviceInfo(
            clientName: 'test',
            deviceName: 'test',
            deviceId: 'season-art',
            version: '1',
          ),
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
      );
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
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
      expect(header().item.id, 'season-friends-1');
      expect(
        server.requests.any(
          (r) => r.contains('/season-friends-1/Images/Backdrop'),
        ),
        isTrue,
      );
      server.requests.clear();
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-2')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-2');
      expect(
        server.requests.any(
          (r) => r.contains('/season-friends-2/Images/Primary'),
        ),
        isTrue,
      );
      expect(
        server.requests.any(
          (r) => r.contains('/series-friends/Images/Backdrop'),
        ),
        isFalse,
      );
      server.requests.clear();
      await tester.tap(find.byKey(CatalogKeys.season('season-friends-3')));
      await _artworkFrames(tester);
      expect(header().item.id, 'season-friends-3');
      expect(
        server.requests.any(
          (r) => r.contains('/series-friends/Images/Backdrop'),
        ),
        isTrue,
      );
      // A previously displayed season's new tag can fail independently; its
      // fallback must be the shared source, without retaining the old poster.
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
      expect(header().item.id, 'season-friends-2');
      expect(header().item.primaryImageTag, 'two-failed');
      expect(
        server.requests.any(
          (r) => r.contains('/season-friends-2/Images/Primary'),
        ),
        isTrue,
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
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'test',
              deviceId: 'route-identity',
              version: '1',
            ),
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final app = RillightApp(auth: auth, environment: environment);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
          auth.dispose();
        });
        await tester.pumpWidget(app);
        for (final id in ['movie-up', 'movie-inception']) {
          app.router.go('/item/$id');
          await tester.pumpAndSettle();
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

Future<void> _artworkFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
