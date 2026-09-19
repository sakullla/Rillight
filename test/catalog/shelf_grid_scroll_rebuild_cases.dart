import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-grid-scroll',
  version: '0.1.0',
);

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
          overview: '简介 <b>$i</b>',
          productionYear: 2000 + (i % 20),
        ),
      );
    }
    HomeHero.autoAdvanceEnabled = false;
  });

  tearDown(() {
    HomeHero.autoAdvanceEnabled = true;
    debugOnRebuildDirtyWidget = null;
  });

  Future<void> openMovieLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    final app = RillightApp(auth: auth);
    app.router.go('/library/view-movies');
    await tester.pumpWidget(app);
    await settle(tester);
    expect(find.byType(ShelfGridPage), findsOneWidget);
  }

  ScrollPosition gridPosition(WidgetTester tester) {
    final scrollable = find.descendant(
      of: find.byType(ShelfGridPage),
      matching: find.byType(Scrollable),
    );
    return tester.state<ScrollableState>(scrollable.first).position;
  }

  testWidgets('scrolling the poster wall does not rebuild live cards', (
    tester,
  ) async {
    await openMovieLibrary(tester);
    final position = gridPosition(tester);
    expect(find.byType(PosterCard), findsWidgets);

    final livePosters = find.byType(PosterCard).evaluate().toSet();
    final liveImages = find.byType(MediaImage).evaluate().toSet();
    var posterBuilds = 0;
    var imageBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final widget = element.widget;
      if (widget is PosterCard && livePosters.contains(element)) {
        posterBuilds++;
      } else if (widget is MediaImage && liveImages.contains(element)) {
        imageBuilds++;
      }
    };

    // 模拟桌面滚轮:每帧跳一小段。已挂上的卡片不应因滚动重建;
    // 缓存区只有半屏,底部可能新进一行,那些首建不算。
    for (var frame = 0; frame < 6; frame++) {
      position.jumpTo(position.pixels + 40);
      await tester.pump();
    }

    expect(posterBuilds, 0, reason: '滚动不应重建已存活的 PosterCard');
    expect(imageBuilds, 0, reason: '滚动不应重建已存活的 MediaImage');

    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, greaterThan(1));

    final firstTop = tester.getTopLeft(find.byType(PosterCard).first).dy;
    final firstRow = find.byType(PosterCard).evaluate().where((element) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero).dy == firstTop;
    }).length;
    expect(firstRow, delegate.crossAxisCount);
    await tester.pumpWidget(const SizedBox.shrink());
    MediaImage.debugResetCacheConfiguration();
  }, tags: ['integration']);
}
