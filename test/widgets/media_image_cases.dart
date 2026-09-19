import 'dart:async';
import 'dart:typed_data';

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

  test('image cache budgets stay well below the old 256 MiB dual cap', () {
    expect(kPaintingImageCacheMaxBytes, 64 * 1024 * 1024);
    expect(kPaintingImageCacheMaxEntries, 400);
    expect(MediaImageCache.defaultMemoryLimitBytes, 64 * 1024 * 1024);
  });

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

  test('configurePaintingImageCache applies the decode budget', () {
    configurePaintingImageCache();
    expect(
      PaintingBinding.instance.imageCache.maximumSize,
      kPaintingImageCacheMaxEntries,
    );
    expect(
      PaintingBinding.instance.imageCache.maximumSizeBytes,
      kPaintingImageCacheMaxBytes,
    );
  });

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

  test('hung fetches time out and release concurrency slots', () async {
    MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 40);
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
  });

  test('timeout abort is invoked so HTTP can be cancelled', () async {
    MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 40);
    final hung = Completer<Uint8List?>();
    addTearDown(() {
      if (!hung.isCompleted) {
        hung.complete(null);
      }
    });
    var aborted = false;
    final missed = await MediaImageCache.instance.load(
      serverId: 'server-1',
      itemId: 'abort',
      type: 'Primary',
      tag: 'tag-x',
      maxWidth: 280,
      fetch: () => hung.future,
      onAbort: () => aborted = true,
    );
    expect(missed, isNull);
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
  });

  test('timeouts are not negatively cached and can retry', () async {
    MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 40);
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
