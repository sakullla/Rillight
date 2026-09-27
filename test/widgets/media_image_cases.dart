import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:rillight/emby/emby_errors.dart';
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
    MediaImage.debugResetCacheConfiguration();
    MediaImage.debugClearCache();
    MediaImageCache.instance.debugSetDiskStore(_DisabledDiskStore());
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

  tearDown(() {
    MediaImage.debugClearCache();
    MediaImage.debugResetCacheConfiguration();
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

  testWidgets('same-server account switch reloads protected artwork', (
    tester,
  ) async {
    server = FakeEmbyServer(
      users: [
        const FakeEmbyUser(
          username: 'alice',
          password: 'correct-horse',
          userId: 'user-alice',
        ),
        const FakeEmbyUser(
          username: 'bob',
          password: 'bob-password',
          userId: 'user-bob',
        ),
      ],
      items: [...server.items],
    );
    adapter = FakeEmbyAdapter([server]);
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, withTag));
      for (var i = 0; i < 30 && imageRequests().isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(imageRequests(), hasLength(1));

    await tester.runAsync(() async {
      await auth.logout();
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'bob',
        password: 'bob-password',
      );
    });
    await tester.runAsync(() async {
      for (var i = 0; i < 30 && imageRequests().length < 2; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(imageRequests(), hasLength(2));
  });

  Future<void> pumpPosterStrip(
    WidgetTester tester,
    AuthController auth, {
    required int count,
    double cacheExtent = 400,
  }) {
    return tester.pumpWidget(
      wrap(
        auth,
        SizedBox(
          width: 120,
          height: 180,
          child: ListView.builder(
            scrollCacheExtent: ScrollCacheExtent.pixels(cacheExtent),
            itemExtent: 180,
            itemCount: count,
            itemBuilder: (context, index) {
              return MediaImage(
                key: ValueKey('poster-$index'),
                item: EmbyItem(
                  id: 'poster-$index',
                  name: '海报$index',
                  type: 'Movie',
                  primaryImageTag: 'tag-$index',
                ),
                width: 120,
                height: 180,
              );
            },
          ),
        ),
      ),
    );
  }

  AuthController detachedAuth(_ControlledImageClient client) => AuthController(
    client: client,
    credentials: MemoryCredentialStore(),
    servers: MemoryServerListStore(),
  );

  testWidgets(
    'attached player client loads and isolates endpoint, user and logout',
    (tester) async {
      final client = _ControlledImageClient();
      final auth = detachedAuth(client);
      expect(auth.session, isNull);
      expect(auth.isLoggedIn, isFalse);
      await tester.pumpWidget(buildSubject(auth, withTag));
      await pumpUntilImage(tester);
      expect(client.requested, ['img-movie']);
      expect(find.byType(Image), findsOneWidget);
      var provider = tester.widget<Image>(find.byType(Image)).image;

      for (final identity in [
        ('https://second.example/emby', 'alice'),
        ('https://second.example/emby', 'bob'),
      ]) {
        client.attachSession(
          baseUrl: Uri.parse(identity.$1),
          accessToken: 'synthetic',
          userId: identity.$2,
        );
        await tester.pumpWidget(buildSubject(auth, withTag));
        await pumpUntilImage(tester);
        final next = tester.widget<Image>(find.byType(Image)).image;
        expect(next, isNot(provider));
        provider = next;
      }
      expect(client.requested, hasLength(3));
      client.clearSession();
      await tester.pumpWidget(buildSubject(auth, withTag));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(PosterPlaceholder), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'chapter cache follows attached endpoint and drops late logout response',
    (tester) async {
      final client = _ControlledImageClient();
      final auth = detachedAuth(client);
      late BuildContext imageContext;
      await tester.pumpWidget(
        wrap(
          auth,
          Builder(
            builder: (context) {
              imageContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      Future<Uint8List?> chapter() => loadChapterImage(
        imageContext,
        itemId: 'chapter-item',
        index: 0,
        tag: 'tag',
      );
      expect(await chapter(), kTinyPng);
      expect(await chapter(), kTinyPng);
      expect(client.requested, hasLength(1));
      client.attachSession(
        baseUrl: Uri.parse('https://second.example/emby'),
        accessToken: 'synthetic',
        userId: 'alice',
      );
      client.hold = true;
      final late = chapter();
      await tester.pump();
      expect(client.requested, hasLength(2));
      client.clearSession();
      client.pending['chapter-item']!.complete(kTinyPng);
      expect(await late, isNull);
      expect(await chapter(), isNull);
      expect(client.requested, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'transient image failure retries while absent image remains negative cached',
    (tester) async {
      for (final failure in [
        const EmbyException(EmbyFailureKind.timeout),
        const EmbyException(EmbyFailureKind.unreachable),
        const EmbyException(EmbyFailureKind.unknown, statusCode: 429),
        const EmbyException(EmbyFailureKind.unknown, statusCode: 503),
      ]) {
        MediaImage.debugClearCache();
        final client = _ControlledImageClient()..failures.add(failure);
        await tester.pumpWidget(buildSubject(detachedAuth(client), withTag));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 201));
        await pumpUntilImage(tester);
        expect(client.requested, hasLength(2), reason: '$failure');
        expect(find.byType(Image), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      MediaImage.debugClearCache();
      final absent = _ControlledImageClient()
        ..failures.add(
          const EmbyException(EmbyFailureKind.unknown, statusCode: 404),
        );
      await tester.pumpWidget(buildSubject(detachedAuth(absent), withTag));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(absent.requested, hasLength(1));
      expect(find.byType(PosterPlaceholder), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'repeated transient failures stop after three attempts and remount can recover',
    (tester) async {
      final client = _ControlledImageClient()
        ..failures.addAll(
          List.filled(
            10,
            const EmbyException(EmbyFailureKind.unknown, statusCode: 503),
          ),
        );
      final auth = detachedAuth(client);
      await tester.pumpWidget(buildSubject(auth, withTag));
      await tester.pump();
      for (final delay in [201, 401, 601]) {
        await tester.pump(Duration(milliseconds: delay));
      }
      await tester.pump(const Duration(seconds: 5));
      expect(client.requested, hasLength(3));
      expect(find.byType(PosterPlaceholder), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      client.failures.clear();
      await tester.pumpWidget(buildSubject(auth, withTag));
      await pumpUntilImage(tester);
      expect(client.requested, hasLength(4));
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'slow queue promotes newly visible poster and backscroll uses warm cache',
    (tester) async {
      final client = _ControlledImageClient()..hold = true;
      final auth = detachedAuth(client);
      await pumpPosterStrip(tester, auth, count: 24, cacheExtent: 10000);
      await tester.pump();
      expect(client.requested, List.generate(8, (i) => 'poster-$i'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(client.requested, hasLength(8));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(15 * 180);
      await tester.pump();
      client.pending['poster-0']!.complete(kTinyPng);
      await tester.pump();
      expect(client.requested[8], 'poster-15');
      expect(client.maxActive, 8);
      client.pending['poster-15']!.complete(kTinyPng);
      await tester.pump();
      await pumpUntilImage(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('poster-15')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      position.jumpTo(0);
      await tester.pump();
      position.jumpTo(15 * 180);
      MediaImageCache.instance.markScrollActivity();
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('poster-15')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(client.requested.where((id) => id == 'poster-15'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      for (final pending in client.pending.values) {
        if (!pending.isCompleted) pending.complete(kTinyPng);
      }
      await tester.pump(MediaImageCache.defaultScrollIdle);
    },
  );

  test(
    'deduplicated queue keeps current consumer when its first widget leaves',
    () async {
      final cache = MediaImageCache.instance;
      final blockers = List.generate(8, (_) => Completer<Uint8List?>());
      Future<Uint8List?> load(
        String id,
        Future<Uint8List?> Function() fetch, {
        bool Function()? current,
        bool Function()? visible,
      }) => cache.load(
        serverId: 'scope',
        itemId: id,
        type: 'Primary',
        maxWidth: 120,
        fetch: fetch,
        isCurrent: current,
        inViewport: visible,
      );
      final active = [
        for (var i = 0; i < 8; i++) load('active-$i', () => blockers[i].future),
      ];
      await Future<void>.delayed(Duration.zero);
      var firstValid = true;
      final started = <String>[];
      final abandoned = load('abandoned', () async {
        started.add('abandoned');
        return kTinyPng;
      }, current: () => firstValid);
      final first = load('shared', () async {
        started.add('first');
        return kTinyPng;
      }, current: () => firstValid);
      final second = load('shared', () async {
        started.add('second');
        return kTinyPng;
      }, visible: () => true);
      await Future<void>.delayed(Duration.zero);
      firstValid = false;
      blockers[0].complete(kTinyPng);
      expect(await abandoned, isNull);
      expect(await first, kTinyPng);
      expect(await second, kTinyPng);
      expect(started, ['second']);
      for (final blocker in blockers.skip(1)) {
        blocker.complete(kTinyPng);
      }
      await Future.wait(active);
      expect(
        cache.isNegativeCached(
          serverId: 'scope',
          itemId: 'abandoned',
          type: 'Primary',
          maxWidth: 120,
        ),
        isFalse,
      );
    },
  );

  test('backdrop request width follows the window pixels and clamps', () {
    expect(
      mediaBackdropRequestWidth(layoutWidth: 960, devicePixelRatio: 1),
      960,
    );
    expect(
      mediaBackdropRequestWidth(layoutWidth: 1920, devicePixelRatio: 1),
      kMediaBackdropMaxRequestWidth,
    );
    expect(
      mediaBackdropRequestWidth(layoutWidth: 800, devicePixelRatio: 1.25),
      1000,
    );
    expect(
      mediaBackdropRequestWidth(layoutWidth: 400, devicePixelRatio: 1),
      kMediaBackdropMinRequestWidth,
    );
  });

  test(
    'painting image cache budgets apply and shrink for the player process',
    () {
      expect(kPaintingImageCacheMaxBytes, 64 * 1024 * 1024);
      expect(kPaintingImageCacheMaxEntries, 400);
      expect(MediaImageCache.defaultMemoryLimitBytes, 64 * 1024 * 1024);

      configurePaintingImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSize,
        kPaintingImageCacheMaxEntries,
      );
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        kPaintingImageCacheMaxBytes,
      );

      configurePaintingImageCache(playerProcess: true);
      expect(
        PaintingBinding.instance.imageCache.maximumSize,
        kPlayerProcessImageCacheMaxEntries,
      );
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        kPlayerProcessImageCacheMaxBytes,
      );
      expect(
        MediaImageCache.instance.memoryLimitBytes,
        kPlayerProcessImageCacheMaxBytes,
      );
      configurePaintingImageCache();
    },
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

  testWidgets('falls back to PosterPlaceholder when the image fails', (
    tester,
  ) async {
    final auth = await connect(tester);
    const missing = EmbyItem(
      id: 'img-missing',
      name: '缺失海报',
      type: 'Movie',
      primaryImageTag: 'tag-missing',
    );
    server.items.add(
      FakeEmbyItem(
        id: missing.id,
        name: missing.name,
        type: missing.type,
        primaryImageTag: missing.primaryImageTag,
      ),
    );
    server.failingImageIds.add(missing.id);
    MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 80);

    await tester.runAsync(() async {
      await tester.pumpWidget(buildSubject(auth, missing));
      // FutureBuilder listens on this zone. Pump here after the 404, not
      // back in fake-async where the completion never rebuilds the tree.
      for (var i = 0; i < 40; i++) {
        await tester.pump();
        if (find.byType(PosterPlaceholder).evaluate().isNotEmpty) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(find.byType(Image), findsNothing);
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

  testWidgets('implicit image width uses the same DPR bounded request', (
    tester,
  ) async {
    final auth = await connect(tester);
    await tester.runAsync(() => tester.pumpWidget(buildSubject(auth, withTag)));
    await pumpUntilImage(tester);
    final expected = (120 * tester.view.devicePixelRatio).round().clamp(
      1,
      kMediaBackdropMaxRequestWidth,
    );
    expect(imageRequests().single, contains('maxWidth=$expected'));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('missing width cannot request an unbounded original image', (
    tester,
  ) async {
    final auth = await connect(tester);
    await tester.runAsync(
      () => tester.pumpWidget(
        wrap(
          auth,
          const SizedBox(
            width: 200,
            height: 200,
            child: MediaImage(item: withTag),
          ),
        ),
      ),
    );
    await pumpUntilImage(tester);
    final expected = (280 * tester.view.devicePixelRatio).round().clamp(
      1,
      kMediaBackdropMaxRequestWidth,
    );
    expect(imageRequests().single, contains('maxWidth=$expected'));
    expect(find.byType(Image), findsOneWidget);
  });

  test('one oversized image does not exceed the memory byte budget', () async {
    MediaImageCache.instance.memoryLimitBytes = kTinyPng.length - 1;
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      return kTinyPng;
    }

    Future<Uint8List?> load() => MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'oversized',
      type: 'Primary',
      maxWidth: 280,
      fetch: fetch,
    );

    expect(await load(), kTinyPng);
    expect(
      MediaImageCache.instance.peek(
        serverId: 'server-1',
        itemId: 'oversized',
        type: 'Primary',
        maxWidth: 280,
      ),
      isNull,
    );
    await load();
    expect(fetches, 2);
  });

  test('one oversized image does not exceed the disk byte budget', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rillight-image-budget-',
    );
    try {
      final store = FileMediaImageDiskStore(
        directory,
        limitBytes: kTinyPng.length - 1,
      );
      await store.write('oversized', kTinyPng);
      expect(await store.read('oversized'), isNull);
      expect(await directory.list().toList(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'memory cache evicts least recently used above the byte limit',
    () async {
      MediaImageCache.instance.memoryLimitBytes = kTinyPng.length * 2;
      var fetches = 0;
      Future<Uint8List?> fetch() async {
        fetches++;
        return kTinyPng;
      }

      Future<Uint8List?> load(String itemId) {
        return MediaImageCache.instance.load(
          serverId: 'server-1',
          itemId: itemId,
          type: 'Primary',
          tag: 'tag-x',
          maxWidth: 280,
          fetch: fetch,
        );
      }

      await load('a');
      await load('b');
      // 最近使用 a 后,再装 c 会淘汰最久未用的 b。
      await load('a');
      expect(fetches, 2);
      await load('c');
      expect(fetches, 3);
      await load('a');
      expect(fetches, 3);
      await load('b');
      expect(fetches, 4);
    },
  );

  test('disk cache survives a memory clear like an app restart', () async {
    final disk = _FakeDiskStore();
    MediaImageCache.instance.debugSetDiskStore(disk);
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      return kTinyPng;
    }

    final bytes = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'a',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    expect(bytes, isNotNull);
    expect(disk.files, hasLength(1));

    MediaImage.debugClearMemory();
    final again = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'a',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    expect(again, isNotNull);
    expect(fetches, 1);
  });

  test('disk write failure degrades to memory-only caching', () async {
    final disk = _FakeDiskStore()..failWrites = true;
    MediaImageCache.instance.debugSetDiskStore(disk);
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      return kTinyPng;
    }

    final bytes = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'a',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    // 磁盘写入失败不影响本次取回与显示。
    expect(bytes, isNotNull);
    expect(fetches, 1);

    MediaImage.debugClearMemory();
    final again = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'a',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    expect(again, isNotNull);
    expect(fetches, 2);
  });

  test('negative cache expires after its TTL', () async {
    var now = DateTime(2026, 1, 1, 12);
    MediaImageCache.instance.clock = () => now;
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      return null;
    }

    Future<Uint8List?> load() {
      return MediaImageCache.instance.load(
        serverId: 'server-1',
        itemId: 'a',
        type: 'Primary',
        tag: 'tag-x',
        maxWidth: 280,
        fetch: fetch,
      );
    }

    await load();
    expect(fetches, 1);
    expect(
      MediaImageCache.instance.isNegativeCached(
        serverId: 'server-1',
        itemId: 'a',
        type: 'Primary',
        tag: 'tag-x',
        maxWidth: 280,
      ),
      isTrue,
    );
    // TTL 内不再重试。
    await load();
    expect(fetches, 1);
    now = now.add(const Duration(seconds: 31));
    await load();
    expect(fetches, 2);
  });

  test('tag change invalidates the cached entry and miss', () async {
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      return fetches == 1 ? kTinyPng : null;
    }

    Future<Uint8List?> load(String tag) {
      return MediaImageCache.instance.load(
        serverId: 'server-1',
        itemId: 'a',
        type: 'Primary',
        tag: tag,
        maxWidth: 280,
        fetch: fetch,
      );
    }

    final first = await load('tag-1');
    expect(first, isNotNull);
    final cached = await load('tag-1');
    expect(fetches, 1);
    expect(identical(cached, first), isTrue);

    // tag 变化即换 key:命中缓存不再生效,重新拉取并按新结果处理。
    final second = await load('tag-2');
    expect(fetches, 2);
    expect(second, isNull);

    // tag-1 的负缓存不阻塞 tag-2,tag-2 自身的负缓存也不阻塞 tag-1 的旧命中。
    await load('tag-1');
    expect(fetches, 2);
    await load('tag-2');
    expect(fetches, 2);
  });

  test('fetch timeouts release slots, abort, and stay retryable', () async {
    MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 40);

    // 超时释放并发槽位,后续加载不受影响。
    final hung = Completer<Uint8List?>();
    addTearDown(() {
      if (!hung.isCompleted) {
        hung.complete(null);
      }
    });
    final missed = MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'hung',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: () => hung.future,
    );
    var extraFetches = 0;
    final extra = MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'ok',
      type: 'Primary',
      tag: 'tag-y',
      maxWidth: 280,
      fetch: () async {
        extraFetches++;
        return kTinyPng;
      },
    );
    expect(await missed, isNull);
    expect(await extra, isNotNull);
    expect(extraFetches, 1);

    // 超时调用 onAbort 以便取消 HTTP,且不进入负缓存。
    var aborted = false;
    final abortedLoad = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'abort',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: () => hung.future,
      onAbort: () => aborted = true,
    );
    expect(abortedLoad, isNull);
    expect(aborted, isTrue);
    expect(
      MediaImageCache.instance.isNegativeCached(
        serverId: 'server-1',
        itemId: 'abort',
        type: 'Primary',
        tag: 'tag-x',
        maxWidth: 280,
      ),
      isFalse,
    );

    // 慢 fetch 超时后重试可以成功。
    var fetches = 0;
    Future<Uint8List?> fetch() async {
      fetches++;
      if (fetches == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return kTinyPng;
      }
      return kTinyPng;
    }

    final first = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'retry',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    expect(first, isNull);
    expect(fetches, 1);

    final second = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'retry',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: fetch,
    );
    expect(second, isNotNull);
    expect(fetches, 2);
  });

  test('slow disk writes do not block other image fetches', () async {
    final hang = Completer<void>();
    addTearDown(() {
      if (!hang.isCompleted) {
        hang.complete();
      }
    });
    MediaImageCache.instance.debugSetDiskStore(_HangingWriteStore(hang));

    final first = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'a',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: () async => kTinyPng,
    );
    expect(first, isNotNull);

    final second = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'b',
      type: 'Primary',
      tag: 'tag-y',
      maxWidth: 280,
      fetch: () async => kTinyPng,
    );
    expect(second, isNotNull);
    hang.complete();
  });

  testWidgets('paints cached tiles immediately after jumpTo recreates them', (
    tester,
  ) async {
    for (var i = 0; i < 8; i++) {
      server.items.add(
        FakeEmbyItem(
          id: 'scroll-$i',
          name: '海报$i',
          type: 'Movie',
          primaryImageTag: 'tag-scroll-$i',
        ),
      );
    }
    final auth = await connect(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          auth,
          SizedBox(
            width: 120,
            height: 200,
            child: ListView.builder(
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              itemExtent: 190,
              itemCount: 8,
              itemBuilder: (context, index) {
                return MediaImage(
                  item: EmbyItem(
                    id: 'scroll-$index',
                    name: '海报$index',
                    type: 'Movie',
                    primaryImageTag: 'tag-scroll-$index',
                  ),
                  width: 120,
                  height: 180,
                );
              },
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsWidgets);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(190 * 6);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    position.jumpTo(0);
    await tester.pump();
    expect(find.byType(Image), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(MediaImageCache.defaultFetchTimeout);
  });

  test('waitForScrollIdle holds until the idle window elapses', () async {
    MediaImageCache.instance.markScrollActivity();
    expect(MediaImageCache.instance.isScrollBusy, isTrue);
    var finished = false;
    final waiting = MediaImageCache.instance.waitForScrollIdle().whenComplete(
      () => finished = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(finished, isFalse);
    await waiting;
    expect(MediaImageCache.instance.isScrollBusy, isFalse);
  });

  test('scroll idle follows the timer when wall clock is behind', () {
    FakeAsync().run((async) {
      MediaImageCache.instance.markScrollActivity();
      expect(MediaImageCache.instance.isScrollBusy, isTrue);
      async.elapse(MediaImageCache.defaultScrollIdle);
      expect(MediaImageCache.instance.isScrollBusy, isFalse);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('disk writes wait until scrolling stops', () async {
    final disk = _FakeDiskStore();
    MediaImageCache.instance.debugSetDiskStore(disk);
    MediaImageCache.instance.markScrollActivity();
    await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'scroll-write',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: () async => kTinyPng,
    );
    expect(disk.files, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(disk.files, hasLength(1));
  });

  testWidgets('scroll notifications mark the image cache busy', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 200,
          child: MediaImageScrollListener(
            child: ListView(
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(height: 80, child: Text('$i')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(MediaImageCache.instance.isScrollBusy, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();
    expect(MediaImageCache.instance.isScrollBusy, isTrue);
    await tester.pump(MediaImageCache.defaultScrollIdle);
    expect(MediaImageCache.instance.isScrollBusy, isFalse);
  });

  testWidgets('visible uncached posters fetch while scrolling', (tester) async {
    final auth = await connect(tester);
    await tester.runAsync(() async {
      MediaImageCache.instance.markScrollActivity();
      await tester.pumpWidget(buildSubject(auth, withTag));
      MediaImageCache.instance.markScrollActivity();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(imageRequests(), isNotEmpty);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump();
    expect(imageRequests(), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    MediaImage.debugResetCacheConfiguration();
  });

  void addPosterItems(int count) {
    for (var i = 0; i < count; i++) {
      server.items.add(
        FakeEmbyItem(
          id: 'poster-$i',
          name: '海报$i',
          type: 'Movie',
          primaryImageTag: 'tag-$i',
        ),
      );
    }
  }

  String? requestedItemId(String request) {
    return RegExp(r'/Items/([^/]+)/Images/').firstMatch(request)?.group(1);
  }

  testWidgets(
    'viewport disk hits paint while scrolling and offscreen disk stays deferred',
    (tester) async {
      final auth = await connect(tester);
      final serverId = const DartSha256()
          .hashSync(
            utf8.encode(
              jsonEncode([
                auth.client.baseUrl.toString().replaceFirst(RegExp(r'/+$'), ''),
                auth.client.userId,
              ]),
            ),
          )
          .bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final disk = _FakeDiskStore();
      MediaImageCache.instance.debugSetDiskStore(disk);
      for (final index in [0, 1]) {
        await MediaImageCache.instance.load(
          serverId: serverId,
          itemId: 'poster-$index',
          type: 'Primary',
          tag: 'tag-$index',
          maxWidth: (120 * tester.view.devicePixelRatio).round(),
          fetch: () async => kTinyPng,
        );
      }
      MediaImage.debugClearMemory();
      expect(disk.files, isNotEmpty);

      MediaImageCache.instance.markScrollActivity();
      await pumpPosterStrip(tester, auth, count: 2);
      MediaImageCache.instance.markScrollActivity();
      await tester.pump();
      expect(MediaImageCache.instance.isScrollBusy, isTrue);
      expect(imageRequests(), isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('poster-0')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('poster-1')),
          matching: find.byType(Image),
        ),
        findsNothing,
      );

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(180);
      MediaImageCache.instance.markScrollActivity();
      await tester.pump();
      await tester.pump();
      expect(MediaImageCache.instance.isScrollBusy, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('poster-1')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(imageRequests(), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(MediaImageCache.defaultScrollIdle);
    },
  );

  testWidgets('visible posters start during scrolling before offscreen ones', (
    tester,
  ) async {
    addPosterItems(2);
    final auth = await connect(tester);
    await tester.runAsync(() async {
      MediaImageCache.instance.markScrollActivity();
      await pumpPosterStrip(tester, auth, count: 2);
      MediaImageCache.instance.markScrollActivity();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(imageRequests().map(requestedItemId), contains('poster-0'));
    expect(imageRequests().map(requestedItemId), isNot(contains('poster-1')));
    expect(find.byType(MediaImage), findsWidgets);

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump();
    final ids = imageRequests().map(requestedItemId).whereType<String>();
    expect(ids, contains('poster-0'));
    expect(ids, contains('poster-1'));
    expect(
      ids.toList().indexOf('poster-0'),
      lessThan(ids.toList().indexOf('poster-1')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(MediaImageCache.defaultFetchTimeout);
  });
}

class _HangingWriteStore implements MediaImageDiskStore {
  _HangingWriteStore(this.hang);

  final Completer<void> hang;

  @override
  Future<Uint8List?> read(String key) async => null;

  @override
  Future<void> write(String key, Uint8List bytes) => hang.future;

  @override
  Future<void> remove(String key) async {}

  @override
  Future<void> clear() async {}
}

class _DisabledDiskStore implements MediaImageDiskStore {
  @override
  Future<Uint8List?> read(String key) async => null;

  @override
  Future<void> write(String key, Uint8List bytes) async {}

  @override
  Future<void> remove(String key) async {}

  @override
  Future<void> clear() async {}
}

class _FakeDiskStore implements MediaImageDiskStore {
  final Map<String, Uint8List> files = {};
  bool failWrites = false;

  @override
  Future<Uint8List?> read(String key) async => files[key];

  @override
  Future<void> write(String key, Uint8List bytes) async {
    if (failWrites) {
      throw Exception('disk full');
    }
    files[key] = bytes;
  }

  @override
  Future<void> remove(String key) async {
    files.remove(key);
  }

  @override
  Future<void> clear() async {
    files.clear();
  }
}

class _ControlledImageClient extends EmbyClient {
  _ControlledImageClient() : super(device: _device) {
    attachSession(
      baseUrl: Uri.parse('https://first.example/emby'),
      accessToken: 'synthetic',
      userId: 'alice',
    );
  }

  bool hold = false;
  final requested = <String>[];
  final pending = <String, Completer<Uint8List>>{};
  final failures = <EmbyException>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  }) => getItemImage(
    itemId,
    type: 'Chapter',
    index: index,
    tag: tag,
    maxWidth: maxWidth,
    cancelToken: cancelToken,
  );

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    int? index,
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) async {
    requested.add(itemId);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (failures.isNotEmpty) throw failures.removeAt(0);
      if (hold) {
        final completer = Completer<Uint8List>();
        pending[itemId] = completer;
        return await completer.future;
      }
      return kTinyPng;
    } finally {
      active--;
    }
  }
}
