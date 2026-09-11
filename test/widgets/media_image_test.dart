import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-media-image',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    server.items.add(
      FakeEmbyItem(
        id: 'img-movie',
        name: '海报电影',
        type: 'Movie',
        primaryImageTag: 'tag-img',
      ),
    );
  });

  Future<AuthController> connect(WidgetTester tester) async {
    final auth = AuthController(
      client: EmbyClient(
        device: _device,
        // 零超时,避免 dio 在测试的 fake-async 区间内遗留 Timer。
        dio: dioForFakeEmby(adapter, timeout: Duration.zero),
      ),
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
    expect(auth.isLoggedIn, isTrue);
    return auth;
  }

  Widget buildSubject(AuthController auth, EmbyItem item) {
    return MaterialApp(
      theme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AuthScope(
        controller: auth,
        child: Scaffold(
          body: Center(child: MediaImage(item: item, width: 120, height: 180)),
        ),
      ),
    );
  }

  const withTag = EmbyItem(
    id: 'img-movie',
    name: '海报电影',
    type: 'Movie',
    primaryImageTag: 'tag-img',
  );

  testWidgets('shows a skeleton placeholder while loading', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, withTag));
      // 首帧 future 未完成,应展示骨架占位。
      expect(find.byType(SkeletonBlock), findsOneWidget);
      expect(find.byType(PosterPlaceholder), findsNothing);
    });
  });

  testWidgets('loaded image fades in through AnimatedOpacity', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, withTag));
      // 让 dio 与图片解码的真实异步完成。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    // Image 解码在真实异步区间完成后再重建,frameBuilder 才拿到帧。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();

    expect(find.byType(SkeletonBlock), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsOneWidget);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('falls back to PosterPlaceholder without an image tag', (
    tester,
  ) async {
    final auth = await connect(tester);
    const noTag = EmbyItem(id: 'img-none', name: '无图', type: 'Movie');
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, noTag));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(find.byType(SkeletonBlock), findsNothing);
  });

  testWidgets('falls back to PosterPlaceholder when the image fails', (
    tester,
  ) async {
    final auth = await connect(tester);
    server.failingImageIds.add('img-movie');
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, withTag));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byType(PosterPlaceholder), findsOneWidget);
  });
}
