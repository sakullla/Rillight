import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-line-management',
  version: '0.1.0',
);

void main() {
  // ---------- controller: add / edit / delete lines ----------

  FakeEmbyServer line(String host) {
    return FakeEmbyServer(baseUrl: Uri.parse('http://$host:8096'));
  }

  test(
    'addLine appends an address-only line without changing the active line',
    () async {
      final lan = line('line-lan.test');
      final wan = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan.test:8096'),
      );
      final wan3 = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan3.test:8096'),
      );
      final servers = MemoryServerListStore();
      final auth = AuthController(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan, wan3])),
        ),
        credentials: MemoryCredentialStore(),
        servers: servers,
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'UA/1',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final activeBefore = auth.savedServers.single.activeLineId;

      final ok = await auth.addLine(lan.serverId, wan3.baseUrl.toString());

      expect(ok, isTrue);
      final saved = auth.savedServers.single;
      expect(saved.lines, hasLength(3));
      expect(
        saved.lines.map((l) => l.address),
        contains(wan3.baseUrl.toString()),
      );
      // 添加不改当前线路:浏览与播放继续走原地址,用户名与 UA 不变。
      expect(saved.activeLineId, activeBefore);
      expect(auth.client.baseUrl, wan.baseUrl);
      expect(auth.session?.username, 'alice');
      expect(auth.client.userAgent, 'UA/1');
      // 新线路只存地址,不携带 per-line UA。
      final encoded = saved.lines.last.toJson();
      expect(encoded.containsKey('userAgent'), isFalse);
      // 与登录相同的存储路径落盘。
      final snapshot = await servers.load();
      expect(snapshot.servers.single.lines, hasLength(3));
      expect(snapshot.servers.single.username, 'alice');
      expect(snapshot.servers.single.normalizedUserAgent, 'UA/1');
    },
  );

  test('addLine rejects invalid, duplicate or unknown targets', () async {
    final lan = line('line-invalid.test');
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://line-wan.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan])),
      ),
    );
    addTearDown(auth.dispose);
    await auth.connect(
      address: lan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await auth.connect(
      address: wan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );

    expect(await auth.addLine(lan.serverId, 'ftp://nope.test'), isFalse);
    expect(await auth.addLine(lan.serverId, '  '), isFalse);
    expect(await auth.addLine(lan.serverId, lan.baseUrl.toString()), isFalse);
    expect(await auth.addLine('missing', wan.baseUrl.toString()), isFalse);
    expect(auth.savedServers.single.lines, hasLength(2));
  });

  test(
    'updateLineAddress of a non-active line keeps the session mounted',
    () async {
      final lan = line('line-keep.test');
      final wan = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan.test:8096'),
      );
      final wan3 = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan3.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan, wan3])),
        ),
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final lanLine = auth.savedServers.single.lines.firstWhere(
        (l) => l.address == lan.baseUrl.toString(),
      );

      final ok = await auth.updateLineAddress(
        lan.serverId,
        lanLine.id,
        wan3.baseUrl.toString(),
      );

      expect(ok, isTrue);
      final saved = auth.savedServers.single;
      expect(saved.lines, hasLength(2));
      final updated = saved.lines.firstWhere((l) => l.id == lanLine.id);
      expect(updated.address, wan3.baseUrl.toString());
      // 非当前线路改址:会话仍挂在当前线路。
      expect(auth.client.baseUrl, wan.baseUrl);
      expect(saved.activeLineId, isNot(lanLine.id));
    },
  );

  test(
    'updating the active line address moves browsing and playback to it',
    () async {
      final lan = line('line-active.test');
      final wan = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan.test:8096'),
      );
      final wan3 = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://line-wan3.test:8096'),
      );
      final servers = MemoryServerListStore();
      final auth = AuthController(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan, wan3])),
        ),
        credentials: MemoryCredentialStore(),
        servers: servers,
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'UA/1',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;
      final wanLine = auth.savedServers.single.lines.firstWhere(
        (l) => l.address == wan.baseUrl.toString(),
      );

      final ok = await auth.updateLineAddress(
        lan.serverId,
        wanLine.id,
        wan3.baseUrl.toString(),
      );

      expect(ok, isTrue);
      // 会话用户名、token 与服务器 UA 都不变,只是地址换了。
      expect(auth.isLoggedIn, isTrue);
      expect(auth.client.baseUrl, wan3.baseUrl);
      expect(auth.session?.username, 'alice');
      expect(auth.session?.accessToken, token);
      expect(auth.client.userAgent, 'UA/1');
      await auth.client.getJson('/System/Info');
      expect(wan3.lastUserAgent, 'UA/1');
      final snapshot = await servers.load();
      expect(
        snapshot.servers.single.lines.map((l) => l.address),
        contains(wan3.baseUrl.toString()),
      );
    },
  );

  test('updateLineAddress rejects unknown lines and no-op addresses', () async {
    final lan = line('line-reject.test');
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://line-wan.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan])),
      ),
    );
    addTearDown(auth.dispose);
    await auth.connect(
      address: lan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final lanLine = auth.savedServers.single.lines.single;

    expect(
      await auth.updateLineAddress(
        lan.serverId,
        'missing-line',
        wan.baseUrl.toString(),
      ),
      isFalse,
    );
    expect(
      await auth.updateLineAddress(
        lan.serverId,
        lanLine.id,
        lan.baseUrl.toString(),
      ),
      isFalse,
    );
    expect(
      await auth.updateLineAddress(
        'missing',
        lanLine.id,
        wan.baseUrl.toString(),
      ),
      isFalse,
    );
    expect(
      await auth.updateLineAddress(lan.serverId, lanLine.id, 'ftp://x'),
      isFalse,
    );
    expect(
      auth.savedServers.single.lines.single.address,
      lan.baseUrl.toString(),
    );
  });

  test('deleting lines keeps the last line and persists it', () async {
    final lan = line('line-last.test');
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://line-wan.test:8096'),
    );
    final servers = MemoryServerListStore();
    final auth = AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan])),
      ),
      credentials: MemoryCredentialStore(),
      servers: servers,
    );
    addTearDown(auth.dispose);
    await auth.connect(
      address: lan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await auth.connect(
      address: wan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final lanLine = auth.savedServers.single.lines.firstWhere(
      (l) => l.address == lan.baseUrl.toString(),
    );

    await auth.deleteLine(lan.serverId, lanLine.id);
    expect(auth.savedServers.single.lines, hasLength(1));

    // 只剩一条时删除不执行。
    await auth.deleteLine(
      lan.serverId,
      auth.savedServers.single.lines.single.id,
    );
    expect(auth.savedServers.single.lines, hasLength(1));
    final snapshot = await servers.load();
    expect(snapshot.servers.single.lines, hasLength(1));
  });

  // ---------- line address dialog: address only, no UA field ----------

  testWidgets('line address dialog edits an address only', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            key: const Key('open-line-dialog'),
            onPressed: () async {
              result = await showLineAddressDialog(context);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-line-dialog')));
    await tester.pumpAndSettle();

    // 只有地址输入,没有 User-Agent 输入项。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);
    // 添加模式:地址为空时不可提交。
    expect(
      tester
          .widget<FilledButton>(find.byKey(LineAddressDialog.submitKey))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(LineAddressDialog.fieldKey),
      '  http://line-wan.test:8096  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(LineAddressDialog.submitKey));
    await tester.pumpAndSettle();
    expect(result, 'http://line-wan.test:8096');
  });

  testWidgets('line address dialog prefills and can cancel', (tester) async {
    String? result = 'untouched';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            key: const Key('open-line-dialog'),
            onPressed: () async {
              result = await showLineAddressDialog(
                context,
                initialAddress: 'http://line-lan.test:8096',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-line-dialog')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(LineAddressDialog.fieldKey))
          .controller!
          .text,
      'http://line-lan.test:8096',
    );
    expect(find.text('修改线路地址'), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);

    // 取消不改动任何内容。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  // ---------- desktop switcher ----------

  testWidgets('switcher offers add/edit/delete per line; the last line stays', (
    tester,
  ) async {
    final added = <String>[];
    final edited = <(String, ServerLine)>[];
    final deletedLines = <(String, ServerLine)>[];
    final selected = <(String, String)>[];

    SavedServer saved(String id, String name, List<String> addresses) {
      return SavedServer(
        id: id,
        name: name,
        username: 'alice',
        lines: [
          for (var i = 0; i < addresses.length; i++)
            ServerLine(id: 'line-${i + 1}', address: addresses[i]),
        ],
        activeLineId: 'line-1',
      );
    }

    // 改版前的旧 JSON:线路带 per-line UA,迁移后线路只剩地址。
    final legacy = SavedServer.fromJson(const {
      'id': 'server-id-legacy',
      'name': '旧数据',
      'username': 'alice',
      'activeLineId': 'line-2',
      'lines': [
        {
          'id': 'line-1',
          'address': 'http://legacy-lan.test:8096',
          'userAgent': 'OldUA/1',
        },
        {
          'id': 'line-2',
          'address': 'http://legacy-wan.test:8096',
          'userAgent': 'OldUA/2',
        },
      ],
    });
    expect(legacy.normalizedUserAgent, 'OldUA/2');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ServerSwitcherDialog(
            servers: [
              saved('server-id-1', '家庭影院', ['http://emby.test:8096']),
              legacy,
            ],
            activeServerId: 'server-id-1',
            activeLineId: 'line-1',
            onSelect: (serverId, lineId) => selected.add((serverId, lineId)),
            onAddServer: () {},
            onLogout: () {},
            onDelete: (_) {},
            onChangePassword: () {},
            onAddLine: added.add,
            onEditLine: (serverId, line) => edited.add((serverId, line)),
            onDeleteLine: (serverId, line) =>
                deletedLines.add((serverId, line)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 面板列表可滚动:先滚到目标再点击。
    final dialogScrollable = find
        .descendant(
          of: find.byType(ServerSwitcherDialog),
          matching: find.byType(Scrollable),
        )
        .first;
    Future<void> dialogTap(Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        120,
        scrollable: dialogScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    // 只剩一条线路的服务器:点击条目直接切换;不提供删除线路入口,
    // 但仍可添加线路与修改地址。
    await dialogTap(find.text('家庭影院'));
    expect(selected, [('server-id-1', 'line-1')]);
    expect(
      find.byKey(ServerSwitcherDialog.deleteLineKey('server-id-1', 'line-1')),
      findsNothing,
    );
    expect(
      find.byKey(ServerSwitcherDialog.addLineKey('server-id-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(ServerSwitcherDialog.editLineKey('server-id-1', 'line-1')),
      findsOneWidget,
    );

    // 改版前的线路仍可见:展开旧数据服务器。
    await dialogTap(find.text('旧数据'));
    expect(find.text('legacy-lan.test:8096'), findsOneWidget);
    expect(find.text('legacy-wan.test:8096'), findsOneWidget);

    // 旧线路可选。
    await dialogTap(
      find.byKey(
        ServerSwitcherDialog.lineOptionKey('server-id-legacy', 'line-1'),
      ),
    );
    expect(selected.last, ('server-id-legacy', 'line-1'));

    // 修改地址与删除线路入口回调正确的线路。
    final legacyLan = legacy.lines.first;
    await dialogTap(
      find.byKey(
        ServerSwitcherDialog.editLineKey('server-id-legacy', 'line-1'),
      ),
    );
    expect(edited.single, ('server-id-legacy', legacyLan));

    await dialogTap(
      find.byKey(
        ServerSwitcherDialog.deleteLineKey('server-id-legacy', 'line-1'),
      ),
    );
    expect(deletedLines.single, ('server-id-legacy', legacyLan));

    // 添加线路入口按服务器回调。
    await dialogTap(
      find.byKey(ServerSwitcherDialog.addLineKey('server-id-legacy')),
    );
    expect(added, ['server-id-legacy']);
    expect(tester.takeException(), isNull);
  });

  // ---------- phone mine sheet ----------

  testWidgets('phone mine sheet adds, edits and deletes lines', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lan = FakeEmbyServer(baseUrl: Uri.parse('http://mine-lan.test:8096'));
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://mine-wan.test:8096'),
    );
    final wan3 = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://mine-wan3.test:8096'),
    );
    final wan4 = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://mine-wan4.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan, wan3, wan4])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(() async {
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.savedServers.single.lines, hasLength(2));
    final catalog = CatalogController(auth: auth)
      ..cache.debugSetDiskStore(null);
    addTearDown(catalog.dispose);

    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(settingsStore: MemoryPlayerSettingsStore()),
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: CatalogScope(
                controller: catalog,
                child: const PhoneMinePage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> sheetTap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final serverId = auth.savedServers.single.id;
    await sheetTap(find.byKey(PhoneMinePage.lineKey));

    // 添加线路:只填地址,不改当前线路。
    await sheetTap(find.byKey(PhoneMinePage.lineAddKey(serverId)));
    expect(find.byKey(LineAddressDialog.fieldKey), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);
    await tester.enterText(
      find.byKey(LineAddressDialog.fieldKey),
      wan3.baseUrl.toString(),
    );
    await tester.pump();
    await tester.tap(find.byKey(LineAddressDialog.submitKey));
    await tester.pumpAndSettle();
    expect(
      auth.savedServers.single.lines.map((l) => l.address),
      contains(wan3.baseUrl.toString()),
    );
    expect(auth.client.baseUrl, wan.baseUrl);
    expect(find.text('mine-wan3.test:8096'), findsOneWidget);

    // 修改当前线路地址:仅地址变化,浏览与播放改走新地址。
    final wanLine = auth.savedServers.single.lines.firstWhere(
      (l) => l.address == wan.baseUrl.toString(),
    );
    await sheetTap(find.byKey(PhoneMinePage.lineEditKey(serverId, wanLine.id)));
    expect(
      tester
          .widget<TextField>(find.byKey(LineAddressDialog.fieldKey))
          .controller!
          .text,
      wan.baseUrl.toString(),
    );
    await tester.enterText(
      find.byKey(LineAddressDialog.fieldKey),
      wan4.baseUrl.toString(),
    );
    await tester.pump();
    await tester.tap(find.byKey(LineAddressDialog.submitKey));
    await tester.pumpAndSettle();
    expect(auth.client.baseUrl, wan4.baseUrl);
    expect(auth.session?.username, 'alice');

    // 删除线路:删到只剩一条后删除入口不可用。
    ServerLine lineByAddress(String address) {
      return auth.savedServers.single.lines.firstWhere(
        (l) => l.address == address,
      );
    }

    await sheetTap(
      find.byKey(
        PhoneMinePage.lineDeleteKey(
          serverId,
          lineByAddress(lan.baseUrl.toString()).id,
        ),
      ),
    );
    expect(auth.savedServers.single.lines, hasLength(2));
    await sheetTap(
      find.byKey(
        PhoneMinePage.lineDeleteKey(
          serverId,
          lineByAddress(wan3.baseUrl.toString()).id,
        ),
      ),
    );
    expect(auth.savedServers.single.lines, hasLength(1));
    final last = auth.savedServers.single.lines.single;
    expect(
      tester
          .widget<IconButton>(
            find.byKey(PhoneMinePage.lineDeleteKey(serverId, last.id)),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  // ---------- tv settings pane ----------

  testWidgets('tv settings pane adds and deletes lines', (tester) async {
    isolateImageCache();
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lan = FakeEmbyServer(baseUrl: Uri.parse('http://tv-lan.test:8096'));
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://tv-wan.test:8096'),
    );
    final wan3 = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://tv-wan3.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan, wan3])),
      ),
    );
    await tester.runAsync(() async {
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });

    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        createBackend: () => FakeVideoBackend(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    FocusNode navFocus(int index) => tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: find.byKey(ValueKey('tv-nav-$index')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    navFocus(3).requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    // 设置页是懒构建的 ListView:先滚动到目标再点击。
    final tvScrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey('tv-session')),
          matching: find.byType(Scrollable),
        )
        .first;
    Future<void> tvTap(Finder finder) async {
      // 目标可能在当前视口上方:先回到列表顶部再向下找。
      tester.state<ScrollableState>(tvScrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finder, 200, scrollable: tvScrollable);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final serverId = auth.savedServers.single.id;

    // 添加线路:只填地址,不改当前线路。
    await tvTap(find.byKey(ValueKey('tv-line-add-$serverId')));
    expect(find.byKey(LineAddressDialog.fieldKey), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);
    await tester.enterText(
      find.byKey(LineAddressDialog.fieldKey),
      wan3.baseUrl.toString(),
    );
    await tester.pump();
    await tester.tap(find.byKey(LineAddressDialog.submitKey));
    await tester.pumpAndSettle();
    expect(
      auth.savedServers.single.lines.map((l) => l.address),
      contains(wan3.baseUrl.toString()),
    );
    expect(auth.client.baseUrl, wan.baseUrl);

    // 删除线路:删到只剩一条后入口不可用,删除不执行。
    ServerLine lineByAddress(String address) {
      return auth.savedServers.single.lines.firstWhere(
        (l) => l.address == address,
      );
    }

    await tvTap(
      find.byKey(
        ValueKey(
          'tv-line-delete-$serverId-${lineByAddress(lan.baseUrl.toString()).id}',
        ),
      ),
    );
    expect(auth.savedServers.single.lines, hasLength(2));
    await tvTap(
      find.byKey(
        ValueKey(
          'tv-line-delete-$serverId-${lineByAddress(wan3.baseUrl.toString()).id}',
        ),
      ),
    );
    expect(auth.savedServers.single.lines, hasLength(1));
    final last = auth.savedServers.single.lines.single;
    await tvTap(find.byKey(ValueKey('tv-line-delete-$serverId-${last.id}')));
    expect(auth.savedServers.single.lines, hasLength(1));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'tv settings pane explains why a failed line switch kept the line',
    (tester) async {
      isolateImageCache();
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lan = FakeEmbyServer(
        baseUrl: Uri.parse('http://tv-fail-lan.test:8096'),
      );
      final wan = FakeEmbyServer(
        serverId: lan.serverId,
        serverName: lan.serverName,
        baseUrl: Uri.parse('http://tv-fail-wan.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([lan, wan])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(() async {
        await auth.connect(
          address: lan.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await auth.connect(
          address: wan.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      expect(auth.client.baseUrl, wan.baseUrl);

      final app = RillightApp(
        auth: auth,
        environment: PresentationEnvironment.tv,
        playerBindings: PlayerBindings(
          createBackend: () => FakeVideoBackend(),
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
          settingsStore: MemoryPlayerSettingsStore(),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      final navFocus = tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: find.byKey(const ValueKey('tv-nav-3')),
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!;
      navFocus.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final serverId = auth.savedServers.single.id;
      final lanLine = auth.savedServers.single.lines.firstWhere(
        (line) => line.address == lan.baseUrl.toString(),
      );
      lan.publicInfoStatus = 500;
      lan.publicInfoRawBody = 'upstream timeout';

      final tvScrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('tv-session')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(tvScrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      final lanOption = find.byKey(ValueKey('$serverId-${lanLine.id}'));
      await tester.scrollUntilVisible(lanOption, 200, scrollable: tvScrollable);
      await tester.pumpAndSettle();
      await tester.tap(lanOption);
      await tester.pumpAndSettle();

      // 原线路与会话保持,失败原因在设置面板内可见。
      expect(auth.lineSwitchFailure?.detail, 'HTTP 500: upstream timeout');
      expect(auth.client.baseUrl, wan.baseUrl);
      expect(auth.session?.server.activeLine?.address, wan.baseUrl.toString());
      expect(find.byKey(const Key('tv-line-switch-failure')), findsOneWidget);
      expect(find.textContaining('切换线路失败'), findsOneWidget);
      expect(find.textContaining('HTTP 500: upstream timeout'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
