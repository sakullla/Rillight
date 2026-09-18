import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog-controller',
  version: '0.1.0',
);

class _FakeCatalogDisk implements CatalogDiskStore {
  final Map<String, String> files = {};

  @override
  Future<String?> read(String key) async => files[key];

  @override
  Future<void> write(String key, String body) async {
    files[key] = body;
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

void main() {
  test('logout then same-server login reloads home rows', () async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    final catalog = CatalogController(auth: auth);
    addTearDown(catalog.dispose);

    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await catalog.reload();
    final resumeBefore = server.requests
        .where((request) => request.contains('Items/Resume'))
        .length;

    await auth.logout();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      server.requests
          .where((request) => request.contains('Items/Resume'))
          .length,
      greaterThan(resumeBefore),
    );
  });

  test(
    'restart hits the disk cache and rows survive an offline refresh',
    () async {
      final server = FakeEmbyServer();
      final adapter = FakeEmbyAdapter([server]);
      final auth = AuthController(
        client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );

      final disk = _FakeCatalogDisk();
      final first = CatalogController(
        auth: auth,
        cache: CatalogCache()..debugSetDiskStore(disk),
      );
      addTearDown(first.dispose);
      await first.reload();
      expect(first.resume.items.map((item) => item.id), ['movie-inception']);
      expect(disk.files, isNotEmpty);

      // 模拟重启:新控制器 + 新缓存实例,只共享磁盘层。
      final second = CatalogController(
        auth: auth,
        cache: CatalogCache()..debugSetDiskStore(disk),
      );
      addTearDown(second.dispose);

      // 断网:resume 请求失败,先显缓存仍应显示上次内容。
      server.resumeStatus = 500;
      await second.reload();
      expect(second.resume.items.map((item) => item.id), ['movie-inception']);
      expect(second.resume.loading, isFalse);

      // 恢复网络后刷新:行数据更新为服务器最新状态。
      server.resumeStatus = null;
      for (final item in server.items) {
        if (item.id == 'movie-up') {
          item.playbackPositionTicks = 60 * 10000000;
        }
      }
      await second.reloadHomeRows();
      expect(
        second.resume.items.map((item) => item.id),
        containsAll(['movie-inception', 'movie-up']),
      );
    },
  );

  test('hideFromResume stays gone after a resume refresh', () async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(_FakeCatalogDisk()),
    );
    addTearDown(catalog.dispose);
    await catalog.reload();
    expect(catalog.resume.items.map((item) => item.id), ['movie-inception']);

    await catalog.hideFromResume(catalog.resume.items.single);
    expect(catalog.resume.items, isEmpty);
    expect(catalog.resume.hidden, isTrue);

    await catalog.reloadHomeRows();
    expect(catalog.resume.items, isEmpty);
    expect(catalog.resume.hidden, isTrue);
    expect(
      server.requests.any(
        (request) =>
            request.contains('HideFromResume') && request.contains('Hide=true'),
      ),
      isTrue,
    );
  });

  test('manual refresh pulls fresh data even with a TTL-fresh cache', () async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );

    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(_FakeCatalogDisk()),
    );
    addTearDown(catalog.dispose);
    await catalog.reload();
    expect(
      catalog.latestMovies.items.map((item) => item.name),
      contains('飞屋环游记'),
    );

    // 服务器改了数据,缓存仍在 TTL 内:手动刷新必须拿到新结果。
    for (final item in server.items) {
      if (item.id == 'movie-up') {
        item.name = '改名后的电影';
      }
    }
    final before = server.requests
        .where((request) => request.contains('IncludeItemTypes=Movie'))
        .length;
    await catalog.reloadHomeRows();
    final after = server.requests
        .where((request) => request.contains('IncludeItemTypes=Movie'))
        .length;
    expect(after, greaterThan(before), reason: '手动刷新绕过缓存立即重拉');
    expect(
      catalog.latestMovies.items.map((item) => item.name),
      contains('改名后的电影'),
    );
  });

  testWidgets('a failing home row turns into error after quiet retries', (
    tester,
  ) async {
    final server = FakeEmbyServer();
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
    await tester.pumpWidget(const SizedBox.shrink());

    server.latestMovieStatus = 500;
    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(_FakeCatalogDisk()),
    );
    addTearDown(catalog.dispose);
    var notifications = 0;
    catalog.addListener(() => notifications++);

    int movieRequests() => server.requests
        .where((request) => request.contains('IncludeItemTypes=Movie'))
        .length;

    // 首次失败:骨架屏 + 静默重试,不暴露 error。
    unawaited(catalog.reload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(movieRequests(), 1);
    expect(catalog.latestMovies.loading, isTrue);
    expect(catalog.latestMovies.error, isNull);
    expect(catalog.latestMovies.hidden, isFalse);
    expect(catalog.latestSeries.items, isNotEmpty, reason: '其它行不受影响');

    // 2s / 6s:第一、二次静默重试仍失败,继续骨架屏。
    for (final delay in CatalogController.quietRetryDelays.take(2)) {
      await tester.pump(delay);
      await tester.pump(const Duration(milliseconds: 50));
      expect(catalog.latestMovies.loading, isTrue);
      expect(catalog.latestMovies.error, isNull);
    }
    expect(movieRequests(), 3);

    // 20s:第三次重试失败,计划耗尽 → error,且不再安排自动重试。
    await tester.pump(CatalogController.quietRetryDelays.last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(movieRequests(), 4);
    expect(catalog.latestMovies.loading, isFalse);
    expect(catalog.latestMovies.hidden, isFalse);
    expect(catalog.latestMovies.error, isNotNull);
    expect(catalog.latestMovies.error!.statusCode, 500);
    final notifiedAtError = notifications;

    await tester.pump(const Duration(minutes: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(movieRequests(), 4, reason: '耗尽后不再自动重试');
    expect(notifications, notifiedAtError);

    // 手动重试从头开始节拍并恢复。
    server.latestMovieStatus = null;
    unawaited(catalog.reloadHomeRows());
    await tester.pump();
    expect(catalog.latestMovies.loading, isTrue);
    expect(catalog.latestMovies.error, isNull);
    await tester.pump(const Duration(milliseconds: 50));
    expect(catalog.latestMovies.loading, isFalse);
    expect(catalog.latestMovies.error, isNull);
    expect(
      catalog.latestMovies.items.map((item) => item.name),
      contains('飞屋环游记'),
    );
  });

  testWidgets('a row with cached content keeps it while retries fail', (
    tester,
  ) async {
    final server = FakeEmbyServer();
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
    await tester.pumpWidget(const SizedBox.shrink());

    final disk = _FakeCatalogDisk();
    final warm = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(disk),
    );
    addTearDown(warm.dispose);
    unawaited(warm.reload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(warm.latestMovies.items, isNotEmpty);

    server.latestMovieStatus = 500;
    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(disk),
    );
    addTearDown(catalog.dispose);
    unawaited(catalog.reload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    for (final delay in CatalogController.quietRetryDelays) {
      await tester.pump(delay);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(minutes: 1));
    await tester.pump(const Duration(milliseconds: 50));

    expect(catalog.latestMovies.items, isNotEmpty, reason: '缓存内容保留');
    expect(catalog.latestMovies.error, isNull, reason: '有内容时不切换为错误态');
    expect(catalog.latestMovies.loading, isFalse);
  });
}
