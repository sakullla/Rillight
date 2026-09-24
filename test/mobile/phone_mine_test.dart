import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-mine',
  version: '1',
);

void main() {
  setUp(PhoneHomeSectionController.debugResetApp);

  testWidgets('current identity stays visible and a new line reloads catalog', (
    tester,
  ) async {
    final lineA = FakeEmbyServer(
      serverName: '家庭影院',
      baseUrl: Uri.parse('http://line-a.test:8096'),
      items: [_movie('movie-a', '甲线电影')],
    );
    final lineB = FakeEmbyServer(
      serverId: lineA.serverId,
      serverName: '家庭影院',
      baseUrl: Uri.parse('http://line-b.test:8096'),
      items: [_movie('movie-b', '乙线电影')],
    );
    final auth = _auth([lineA, lineB]);
    addTearDown(auth.dispose);
    await _connect(tester, auth, lineA.baseUrl.toString());
    await _connect(tester, auth, lineB.baseUrl.toString());
    final catalog = CatalogController(auth: auth)
      ..cache.debugSetDiskStore(null);
    addTearDown(catalog.dispose);
    await tester.runAsync(catalog.reload);
    expect(catalog.latestMovies.items.map((item) => item.name), ['乙线电影']);

    await _pump(tester, auth: auth, catalog: catalog);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('家庭影院'), findsOneWidget);
    expect(find.text('line-b.test:8096'), findsOneWidget);
    expect(find.text('账户与服务器'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('我的'), findsWidgets);
    expect(
      tester.getTopLeft(find.byKey(PhoneMinePage.userKey)).dy,
      lessThan(tester.getTopLeft(find.byKey(PhoneMinePage.serverKey)).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(PhoneMinePage.currentLineKey)).dy,
      lessThan(tester.getTopLeft(find.text('退出登录')).dy),
    );
    expect(
      tester.getTopLeft(find.text('退出登录')).dy,
      lessThan(tester.getTopLeft(find.text('播放速度')).dy),
    );

    final target = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == lineA.baseUrl.toString(),
    );
    final before = _itemRequests(lineA);
    await _tap(tester, find.byKey(PhoneMinePage.lineKey));
    final option = find.byKey(PhoneMinePage.lineOptionKey(target.id));
    expect(tester.widget<ListTile>(option).selected, isFalse);
    await _tap(tester, option);
    await _until(
      tester,
      () => catalog.latestMovies.items.any((item) => item.name == '甲线电影'),
    );

    expect(auth.client.baseUrl, lineA.baseUrl);
    expect(_itemRequests(lineA), greaterThan(before));
    expect(catalog.latestMovies.items.map((item) => item.name), ['甲线电影']);
    await _scrollToTop(tester);
    expect(find.text('line-a.test:8096'), findsOneWidget);
    expect(find.text('line-b.test:8096'), findsNothing);
    await _tap(tester, find.byKey(PhoneMinePage.lineKey));
    expect(
      tester
          .widget<ListTile>(find.byKey(PhoneMinePage.lineOptionKey(target.id)))
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed line switch keeps the loaded line and explains why', (
    tester,
  ) async {
    final lineA = FakeEmbyServer(
      serverName: '家庭影院',
      baseUrl: Uri.parse('http://line-a.test:8096'),
      items: [_movie('movie-a', '甲线电影')],
    );
    final lineB = FakeEmbyServer(
      serverId: lineA.serverId,
      serverName: '家庭影院',
      baseUrl: Uri.parse('http://line-b.test:8096'),
      items: [_movie('movie-b', '乙线电影')],
    );
    final auth = _auth([lineA, lineB]);
    addTearDown(auth.dispose);
    await _connect(tester, auth, lineA.baseUrl.toString());
    await _connect(tester, auth, lineB.baseUrl.toString());
    final catalog = CatalogController(auth: auth)
      ..cache.debugSetDiskStore(null);
    addTearDown(catalog.dispose);
    await tester.runAsync(catalog.reload);
    lineA.publicInfoStatus = 500;
    lineA.publicInfoRawBody = 'upstream timeout';
    final target = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == lineA.baseUrl.toString(),
    );

    await _pump(tester, auth: auth, catalog: catalog);
    await _tap(tester, find.byKey(PhoneMinePage.lineKey));
    await _tap(tester, find.byKey(PhoneMinePage.lineOptionKey(target.id)));

    // 失败提示在头部下方:先滚回列表顶部。
    await _scrollToTop(tester);
    expect(find.text('HTTP 500: upstream timeout'), findsOneWidget);
    expect(auth.session, isNull);
    expect(
      auth.savedServers.single.activeLine?.address,
      lineB.baseUrl.toString(),
    );
    expect(catalog.latestMovies.items.map((item) => item.name), ['乙线电影']);
    expect(_itemRequests(lineA), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback rate merges and the next playback uses it', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final auth = _auth([server]);
    addTearDown(auth.dispose);
    await _connect(tester, auth, server.baseUrl.toString());
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        playbackRate: 1,
        diskCacheLimitMiB: 2048,
        hardwareDecoding: HardwareDecodingMode.off,
        hardwareDecoder: HardwareDecoderBackend.nvdec,
        danmakuServer: 'https://keep.example',
        danmakuAppId: 'app-keep',
        danmakuToken: 'tok-keep',
      ),
    );
    await _pump(tester, auth: auth, store: store);

    expect(find.text('解码后端'), findsNothing);
    expect(find.text('硬件解码'), findsNothing);
    // 磁盘缓冲上限已收进"我的-缓存"分组,只读当前值、不暴露桌面解码项。
    await _scrollTo(tester, find.text('磁盘缓冲上限'));
    expect(find.text('磁盘缓冲上限'), findsOneWidget);
    await _tap(tester, find.byKey(PhoneMinePage.rateKey(1.5)));

    final saved = await store.read();
    expect(saved.playbackRate, 1.5);
    expect(saved.volume, 40);
    expect(saved.diskCacheLimitMiB, 2048);
    expect(saved.hardwareDecoding, HardwareDecodingMode.off);
    expect(saved.hardwareDecoder, HardwareDecoderBackend.nvdec);
    expect(saved.danmakuServer, 'https://keep.example');
    expect(saved.danmakuAppId, 'app-keep');
    expect(saved.danmakuToken, 'tok-keep');

    final backend = FakeVideoBackend();
    final window = PlayerWindow();
    final controller = PlayerController(
      client: auth.client,
      itemId: 'movie-inception',
      backend: backend,
      window: window,
      settingsStore: store,
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      stoppedTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(
      () => tester.runAsync(() async {
        await controller.disposeAsync();
        controller.dispose();
        window.dispose();
        await backend.dispose();
      }),
    );
    await tester.runAsync(controller.start);
    expect(controller.playbackRate, 1.5);
    expect(backend.rate, 1.5);
    expect(backend.volume, 40);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disk cache limit switches from the mine cache group and merges',
    (tester) async {
      final server = FakeEmbyServer();
      final auth = _auth([server]);
      addTearDown(auth.dispose);
      await _connect(tester, auth, server.baseUrl.toString());
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          volume: 40,
          playbackRate: 1.5,
          danmakuAppId: 'app-keep',
        ),
      );
      await _pump(tester, auth: auth, store: store);

      // "关于"在列表最底部;滚到它时缓存分组已在视口/缓存区内。
      await _scrollTo(tester, find.text('关于'));
      expect(find.text('缓存'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      await _scrollTo(tester, find.byKey(PhoneMinePage.cacheLimitKey(2048)));
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(PhoneMinePage.cacheLimitKey(2048)))
            .selected,
        isTrue,
      );
      await _tap(tester, find.byKey(PhoneMinePage.cacheLimitKey(1024)));

      final saved = await store.read();
      expect(saved.diskCacheLimitMiB, 1024);
      expect(saved.volume, 40);
      expect(saved.playbackRate, 1.5);
      expect(saved.danmakuAppId, 'app-keep');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(PhoneMinePage.cacheLimitKey(1024)))
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom danmaku address can be filled and cleared to official', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final auth = _auth([server]);
    addTearDown(auth.dispose);
    await _connect(tester, auth, server.baseUrl.toString());
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        playbackRate: 1.25,
        danmakuAppId: 'app-keep',
        danmakuToken: 'tok-keep',
      ),
    );
    await _pump(tester, auth: auth, store: store);

    expect(find.text('留空使用官方源'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(PhoneMinePage.danmakuTokenKey))
          .obscureText,
      isTrue,
    );
    await _tap(tester, find.byKey(PhoneMinePage.tokenVisibilityKey));
    expect(
      tester
          .widget<TextField>(find.byKey(PhoneMinePage.danmakuTokenKey))
          .obscureText,
      isFalse,
    );
    expect(find.byTooltip('隐藏令牌'), findsOneWidget);

    await _enter(tester, PhoneMinePage.danmakuServerKey, 'https://dan.example');
    final custom = _CaptureDanmakuClient();
    final customDanmaku = DanmakuController(
      settingsStore: store,
      client: custom,
    );
    addTearDown(customDanmaku.dispose);
    await _until(
      tester,
      () => customDanmaku.customServerUrl == 'https://dan.example',
    );
    expect(customDanmaku.usesCustomSource, isTrue);
    await tester.runAsync(() => customDanmaku.search('示例'));
    expect(custom.source?.isCustom, isTrue);
    expect(custom.source?.baseUri.host, 'dan.example');

    await _enter(tester, PhoneMinePage.danmakuServerKey, '');
    final saved = await store.read();
    expect(saved.danmakuServer, '');
    expect(saved.danmakuAppId, 'app-keep');
    expect(saved.danmakuToken, 'tok-keep');
    expect(saved.volume, 40);
    expect(saved.playbackRate, 1.25);

    final official = _CaptureDanmakuClient();
    final officialDanmaku = DanmakuController(
      settingsStore: store,
      client: official,
    );
    addTearDown(officialDanmaku.dispose);
    await _until(
      tester,
      () =>
          officialDanmaku.hasOfficialCredentials &&
          !officialDanmaku.usesCustomSource,
    );
    await tester.runAsync(() => officialDanmaku.search('示例'));
    expect(official.source?.isCustom, isFalse);
    expect(official.source?.baseUri.host, 'api.dandanplay.net');
    expect(tester.takeException(), isNull);
  });

  testWidgets('home sections can be hidden, reordered and read back', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final auth = _auth([server]);
    addTearDown(auth.dispose);
    await _connect(tester, auth, server.baseUrl.toString());
    final catalog = CatalogController(auth: auth)
      ..cache.debugSetDiskStore(null);
    addTearDown(catalog.dispose);
    catalog.libraries = const [
      EmbyItem(
        id: 'view-movies',
        name: '电影',
        type: 'CollectionFolder',
        collectionType: 'movies',
      ),
    ];
    catalog.librariesLoading = false;
    final store = MemoryPhoneHomeSectionStore();
    final sections = PhoneHomeSectionController(store: store);
    addTearDown(sections.dispose);
    await _pump(tester, auth: auth, catalog: catalog, sections: sections);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(PhoneMinePage)),
    );
    expect(l10n.playerFit, '适应');
    expect(l10n.playerFill, '填充');

    final movies = PhoneHomeSectionId.latestMovies;
    final libraryLatest = PhoneHomeSectionId.libraryLatest('view-movies');
    await _scrollTo(
      tester,
      find.byKey(PhoneHomeSectionEditor.visibleKey(movies)),
    );
    expect(
      tester
          .widget<Switch>(find.byKey(PhoneHomeSectionEditor.visibleKey(movies)))
          .value,
      isTrue,
    );
    await _tap(tester, find.byKey(PhoneHomeSectionEditor.visibleKey(movies)));
    expect(sections.isHidden(movies), isTrue);

    await _scrollTo(
      tester,
      find.byKey(PhoneHomeSectionEditor.moveUpKey(libraryLatest)),
    );
    while (sections.orderedIds(catalog.libraries).indexOf(libraryLatest) >
        sections
            .orderedIds(catalog.libraries)
            .indexOf(PhoneHomeSectionId.resume)) {
      await _tap(
        tester,
        find.byKey(PhoneHomeSectionEditor.moveUpKey(libraryLatest)),
      );
    }
    expect(
      tester.getTopLeft(find.text('电影 · 最近添加')).dy,
      lessThan(tester.getTopLeft(find.text('继续观看')).dy),
    );

    final reopened = PhoneHomeSectionController(store: store);
    addTearDown(reopened.dispose);
    await reopened.load(auth.session!.server.id);
    expect(reopened.isHidden(movies), isTrue);
    expect(
      reopened.orderedIds(catalog.libraries).indexOf(libraryLatest),
      lessThan(
        reopened
            .orderedIds(catalog.libraries)
            .indexOf(PhoneHomeSectionId.resume),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

FakeEmbyItem _movie(String id, String name) {
  return FakeEmbyItem(
    id: id,
    name: name,
    type: 'Movie',
    parentId: 'view-movies',
  );
}

AuthController _auth(List<FakeEmbyServer> servers) {
  return AuthController.memory(
    client: EmbyClient(
      device: _device,
      dio: dioForFakeEmby(FakeEmbyAdapter(servers)),
    ),
  );
}

Future<void> _connect(
  WidgetTester tester,
  AuthController auth,
  String address,
) {
  return tester
      .runAsync(
        () => auth.connect(
          address: address,
          username: 'alice',
          password: 'correct-horse',
        ),
      )
      .then((_) {});
}

int _itemRequests(FakeEmbyServer server) {
  return server.requests.where((request) => request.contains('/Items')).length;
}

Future<void> _pump(
  WidgetTester tester, {
  required AuthController auth,
  PlayerSettingsStore? store,
  CatalogController? catalog,
  PhoneHomeSectionController? sections,
}) async {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final mine = PhoneMinePage(sections: sections);
  final page = catalog == null
      ? mine
      : CatalogScope(controller: catalog, child: mine);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: PlayerBindings(
          settingsStore: store ?? MemoryPlayerSettingsStore(),
        ),
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: page),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _mineScrollable(WidgetTester tester) {
  // 首个为 ListView 自身纵向 Scrollable;其后是 TextField 横向滚动条。
  return find
      .descendant(
        of: find.byKey(const PageStorageKey('mobile-mine-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
}

/// 向下滚动"我的"列表,直到 [finder] 出现(懒加载 build)。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 25 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_mineScrollable(tester), const Offset(0, -250));
    await _settle(tester);
  }
  expect(finder, findsWidgets);
}

/// 滚回列表顶部(头部信息在首屏之上时懒加载不可见)。
Future<void> _scrollToTop(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.drag(_mineScrollable(tester), const Offset(0, 400));
    await _settle(tester);
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _enter(WidgetTester tester, Key key, String value) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.enterText(finder, value);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  FocusManager.instance.primaryFocus?.unfocus();
  await _settle(tester);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 40 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
}

class _CaptureDanmakuClient extends DandanplayClient {
  DandanplaySource? source;

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    this.source = source;
    return [
      DanmakuAnime(
        animeId: 7,
        animeTitle: anime,
        episodes: const [DanmakuEpisode(episodeId: 8, episodeTitle: '1')],
      ),
    ];
  }
}
