import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_bindings.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../helpers/synthetic_source_fixture.dart';

// Keep this platform-specific app test in its own isolate. AppTheme caches
// ThemeData (including platform), so an earlier Android-theme test in the
// catalog suite would disable desktop primary-scroll-controller inheritance.
void main() {
  setUp(isolateImageCache);
  late FakeEmbyServer server;
  setUp(() {
    server = FakeEmbyServer();
    for (var i = 0; i < 60; i++) {
      server.items.add(
        FakeEmbyItem(
          id: 'wall-$i',
          name: '海报墙 $i',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      );
    }
  });
  Future<RillightApp> openMovieLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adapter = FakeEmbyAdapter([server]);
    final auth = SyntheticSourceAuth(
      adapter: adapter,
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'desktop',
        deviceId: 'desktop-wheel-pages',
        version: '1',
      ),
      libraryIds: {'view-movies'},
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    final runtime = (await tester.runAsync(auth.runtime))!;
    final app = RillightApp(
      auth: auth,
      playerBindings: PlayerBindings(runtime: runtime),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      await tester.runAsync(
        () => runtime.history.close().timeout(const Duration(seconds: 5)),
      );
      auth.dispose();
    });
    app.router.go('/library/view-movies');
    await tester.pumpWidget(app);
    await settle(tester);
    expect(find.byType(ShelfGridPage), findsOneWidget);
    return app;
  }

  testWidgets(
    'home and library categories move during continuous vertical wheel input',
    (tester) async {
      final app = await openMovieLibrary(tester);
      for (final path in ['/', '/library/view-movies']) {
        app.router.go(path);
        await settle(tester);
        final page = path == '/'
            ? find.byType(HomePage)
            : find.byType(ShelfGridPage);
        final scroll = find
            .descendant(of: page, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scroll).position;
        expect(position.maxScrollExtent, greaterThan(300));
        position.jumpTo(0);
        await tester.pump();
        var previous = 0.0;
        for (var frame = 0; frame < 6; frame++) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: PointerDeviceKind.mouse,
              position: tester.getCenter(page),
              scrollDelta: const Offset(0, 40),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (frame == 0) {
            expect(
              position.pixels,
              0,
              reason: '$path uses the smooth wheel controller',
            );
          } else {
            expect(
              position.pixels,
              greaterThan(previous),
              reason: '$path frame $frame',
            );
          }
          previous = position.pixels;
        }
        await tester.pump(const Duration(milliseconds: 64));
        expect(position.pixels, closeTo(6 * 40 * 1.6, 0.01));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(MediaImageCache.defaultScrollIdle);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
    tags: ['integration'],
  );
}
