import 'dart:typed_data';

import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-item-detail',
  version: '0.1.0',
);

const _series = 'series-friends';
const _season1 = 'season-friends-1';

/// StartIndex 大于 0 的分集窗口返回 500,用来验收继续加载失败。
class _FailingWindowServer extends FakeEmbyServer {
  bool failEpisodeWindowsAfterStart = false;

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (failEpisodeWindowsAfterStart &&
        options.uri.path.endsWith('/Items') &&
        options.uri.queryParameters['IncludeItemTypes'] == 'Episode') {
      final start =
          int.tryParse(options.uri.queryParameters['StartIndex'] ?? '') ?? 0;
      if (start > 0) {
        return ResponseBody.fromString(
          'episode-window-failed',
          500,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        );
      }
    }
    return super.handle(options, requestStream);
  }
}

class _SilentPlayerHost extends OverlayPlayerWindowHost {
  @override
  bool get embedsPlayerInCaller => false;
}

void main() {
  setUp(isolateImageCache);
  late _FailingWindowServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = _FailingWindowServer();
    adapter = FakeEmbyAdapter([server]);
  });

  Future<RillightApp> pumpApp(
    WidgetTester tester, {
    PlayerWindowHost? host,
    Size viewSize = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(auth.isLoggedIn, isTrue);
    final app = RillightApp(
      auth: auth,
      playerBindings: host == null
          ? const PlayerBindings()
          : PlayerBindings(windowHost: host),
    );
    return app;
  }

  Future<void> openItem(
    WidgetTester tester,
    RillightApp app,
    String itemId,
  ) async {
    app.router.go(AppRoutes.item(itemId));
    await tester.pumpWidget(app);
    await settle(tester);
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  /// 只泵 ItemDetailPage 本体(不带 app shell/路由),驱动其内联的
  /// 分集窗口化与继续加载。
  Future<void> pumpDetailOnly(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(auth.isLoggedIn, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.dark(),
        home: Scaffold(
          body: AuthScope(
            controller: auth,
            child: const ItemDetailPage(itemId: _series),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  testWidgets('episode card play and check keep the detail flow intact', (
    tester,
  ) async {
    final host = _SilentPlayerHost();
    final app = await pumpApp(tester, host: host);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final play = find.byKey(CatalogKeys.episodePlay(id));
    await tester.ensureVisible(play);
    await tester.pump();
    await tester.tap(play);
    await settle(tester);

    expect(app.router.state.uri.path, AppRoutes.item(_series));
    expect(host.current?.itemId, id);

    final toggle = find.byKey(CatalogKeys.episodePlayed(id));
    await tester.ensureVisible(toggle);
    await tester.pump();
    expect(tester.widget<IconButton>(toggle).tooltip, '标记已看');

    await tester.tap(toggle);
    await settle(tester);

    expect(
      server.requests.any(
        (request) =>
            request.contains('POST ') && request.contains('/PlayedItems/$id'),
      ),
      isTrue,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(CatalogKeys.episodePlayed(id)))
          .tooltip,
      '标记未看',
    );

    // 分集详情请求必须带 People 字段(fake server 无条件序列化 People,
    // 只有钉住请求侧的 Fields 才能防止详情链路退回不带 People 的请求)。
    server.requests.clear();
    await openItem(tester, app, 'episode-friends-s1e2');
    final detailRequests = server.requests
        .where((request) => request.contains('/Items/episode-friends-s1e2?'))
        .toList();
    expect(detailRequests, isNotEmpty);
    expect(
      detailRequests.every((request) => request.contains('People')),
      isTrue,
    );
  }, tags: ['integration']);

  testWidgets(
    'episode load-more failure keeps the window and retry appends without duplicates',
    (tester) async {
      server.failEpisodeWindowsAfterStart = true;
      server.setEpisodes(_series, [
        for (var i = 1; i <= 100; i++)
          FakeEpisode(
            id: 'bulk-e$i',
            name: 'Episode $i',
            seasonId: _season1,
            indexNumber: i,
          ),
      ]);
      await pumpDetailOnly(tester);

      final row = find.byKey(CatalogKeys.episodesRow);
      expect(_episodeCardIds(tester), hasLength(80));
      expect(_episodeCardIds(tester).first, 'bulk-e1');
      expect(_episodeCardIds(tester).last, 'bulk-e80');
      final more = find.byKey(CatalogKeys.episodesLoadMore);
      expect(more, findsOneWidget);
      expect(tester.widget(more), isA<OutlinedButton>());
      expect(
        find.descendant(of: more, matching: find.text('加载更多')),
        findsOneWidget,
      );

      // 失败路径:已载窗口不被污染,错误留在分集分区内且可重试。
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await settle(tester);

      expect(_episodeCardIds(tester), hasLength(80));
      expect(_episodeCardIds(tester).first, 'bulk-e1');
      expect(_episodeCardIds(tester).last, 'bulk-e80');
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('episode-window-failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('重试')),
        findsOneWidget,
      );
      expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      // 重试成功:追加下一窗且按 id 去重,分区内错误清空。
      server.failEpisodeWindowsAfterStart = false;
      final retry = find.descendant(of: row, matching: find.text('重试'));
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await settle(tester);

      final ids = _episodeCardIds(tester);
      expect(ids, hasLength(100));
      expect(ids.toSet().length, 100);
      expect(ids.first, 'bulk-e1');
      expect(ids.last, 'bulk-e100');
      expect(find.byKey(CatalogKeys.episodesLoadMore), findsNothing);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('episode-window-failed'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

/// 分集分区内各卡片的条目 id,按渲染顺序。
List<String> _episodeCardIds(WidgetTester tester) {
  final row = find.byKey(CatalogKeys.episodesRow);
  return [
    for (final card in tester.widgetList<EpisodeRow>(
      find.descendant(of: row, matching: find.byType(EpisodeRow)),
    ))
      card.item.id,
  ];
}
