import 'dart:typed_data';

import 'package:dio/dio.dart';
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
    MediaImage.debugClearCache();
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

  tearDown(MediaImage.debugClearCache);

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

  Widget wrap(AuthController auth, Widget child) {
    return MaterialApp(
      theme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AuthScope(
        controller: auth,
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Widget buildSubject(AuthController auth, EmbyItem item) {
    return wrap(auth, MediaImage(item: item, width: 120, height: 180));
  }

  Future<void> pumpUntilImage(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();
  }

  Iterable<String> imageRequests() {
    return server.requests.where((request) => request.contains('/Images/'));
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

  testWidgets('loaded image paints without a fade overlay', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, withTag));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();

    expect(find.byType(SkeletonBlock), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsNothing);
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

  testWidgets('full-width fallback covers the billboard without backdrop', (
    tester,
  ) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: withTag,
            width: 800,
            height: 320,
            preferBackdrop: true,
            maxWidth: 1600,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
    expect(
      imageRequests().where((request) => request.contains('/Images/Backdrop')),
      isEmpty,
    );
  });

  testWidgets('billboard thumb uses cover instead of left contain', (
    tester,
  ) async {
    server.items.add(
      FakeEmbyItem(
        id: 'ep-still',
        name: '剧照',
        type: 'Episode',
        thumbImageTag: 'tag-still',
      ),
    );
    const item = EmbyItem(
      id: 'ep-still',
      name: '剧照',
      type: 'Episode',
      thumbImageTag: 'tag-still',
    );
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: item,
            width: 800,
            height: 320,
            preferBackdrop: true,
            maxWidth: 1600,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
  });

  testWidgets('full-width backdrop uses cover when Backdrop bytes load', (
    tester,
  ) async {
    final dio = dioForFakeEmby(adapter, timeout: Duration.zero);
    dio.httpClientAdapter = _BackdropServingAdapter(adapter);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dio),
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
    const withBackdrop = EmbyItem(
      id: 'img-movie',
      name: '海报电影',
      type: 'Movie',
      primaryImageTag: 'tag-img',
      backdropImageTag: 'tag-back',
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: withBackdrop,
            width: 800,
            height: 320,
            preferBackdrop: true,
            maxWidth: 1600,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
  });

  testWidgets('reuses bytes for the same itemId+type+maxWidth', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const Row(
            children: [
              MediaImage(item: withTag, width: 120, height: 180, maxWidth: 280),
              MediaImage(item: withTag, width: 120, height: 180, maxWidth: 280),
            ],
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    expect(
      imageRequests().where((request) => request.contains('/Images/Primary')),
      hasLength(1),
    );
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('different maxWidth does not share cached bytes', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const Row(
            children: [
              MediaImage(item: withTag, width: 120, height: 180, maxWidth: 280),
              MediaImage(
                item: withTag,
                width: 120,
                height: 180,
                maxWidth: 1600,
              ),
            ],
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    expect(
      imageRequests().where((request) => request.contains('/Images/Primary')),
      hasLength(2),
    );
  });

  testWidgets('episode without Primary uses Thumb', (tester) async {
    server.items.add(
      FakeEmbyItem(
        id: 'ep-thumb',
        name: '只有剧照',
        type: 'Episode',
        seriesId: 'series-friends',
        thumbImageTag: 'tag-ep-thumb',
      ),
    );
    const episode = EmbyItem(
      id: 'ep-thumb',
      name: '只有剧照',
      type: 'Episode',
      seriesId: 'series-friends',
      thumbImageTag: 'tag-ep-thumb',
    );
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: episode,
            width: 210,
            height: 118,
            preferThumb: true,
            maxWidth: 480,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(
      imageRequests().where((request) => request.contains('/Images/Thumb')),
      isNotEmpty,
    );
  });

  testWidgets('episode without still does not paint the series poster', (
    tester,
  ) async {
    const episode = EmbyItem(
      id: 'ep-no-still',
      name: '无剧照',
      type: 'Episode',
      seriesId: 'series-friends',
      seriesPrimaryImageTag: 'tag-friends',
    );
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: episode,
            width: 210,
            height: 118,
            preferThumb: true,
            maxWidth: 480,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);

    expect(find.byType(Image), findsNothing);
    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(
      imageRequests().where(
        (request) => request.contains('/Items/series-friends/Images/Primary'),
      ),
      isEmpty,
    );
    expect(
      imageRequests().where(
        (request) => request.contains('/Items/ep-no-still/Images/Thumb'),
      ),
      isEmpty,
    );
  });

  testWidgets('switching episodes loads the new thumb, not cached series art', (
    tester,
  ) async {
    server.items.addAll([
      FakeEmbyItem(
        id: 'series-art',
        name: '剧',
        type: 'Series',
        backdropImageTag: 'tag-series-back',
      ),
      FakeEmbyItem(
        id: 'ep-a',
        name: 'A',
        type: 'Episode',
        seriesId: 'series-art',
        thumbImageTag: 'tag-a',
        parentBackdropItemId: 'series-art',
        parentBackdropImageTag: 'tag-series-back',
      ),
      FakeEmbyItem(
        id: 'ep-b',
        name: 'B',
        type: 'Episode',
        seriesId: 'series-art',
        thumbImageTag: 'tag-b',
        parentBackdropItemId: 'series-art',
        parentBackdropImageTag: 'tag-series-back',
      ),
    ]);
    const epA = EmbyItem(
      id: 'ep-a',
      name: 'A',
      type: 'Episode',
      seriesId: 'series-art',
      thumbImageTag: 'tag-a',
      parentBackdropItemId: 'series-art',
      parentBackdropImageTag: 'tag-series-back',
    );
    const epB = EmbyItem(
      id: 'ep-b',
      name: 'B',
      type: 'Episode',
      seriesId: 'series-art',
      thumbImageTag: 'tag-b',
      parentBackdropItemId: 'series-art',
      parentBackdropImageTag: 'tag-series-back',
    );
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: epA,
            width: 800,
            height: 320,
            preferBackdrop: true,
            maxWidth: 1600,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);
    expect(
      imageRequests().where(
        (request) => request.contains('/Items/ep-a/Images/Thumb'),
      ),
      isNotEmpty,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          const MediaImage(
            item: epB,
            width: 800,
            height: 320,
            preferBackdrop: true,
            maxWidth: 1600,
          ),
        ),
      );
    });
    await pumpUntilImage(tester);
    expect(
      imageRequests().where(
        (request) => request.contains('/Items/ep-b/Images/Thumb'),
      ),
      isNotEmpty,
    );
  });
}

class _BackdropServingAdapter implements HttpClientAdapter {
  _BackdropServingAdapter(this.inner);

  final FakeEmbyAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.uri.path.contains('/Images/Backdrop')) {
      return Future<ResponseBody>.value(
        ResponseBody.fromBytes(
          kTinyPng,
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
          },
        ),
      );
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    inner.close(force: force);
  }
}
