import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-server-management',
  version: '0.1.0',
);

SavedServer _saved(
  String id,
  String name,
  List<String> addresses, {
  String activeLineId = 'line-1',
}) {
  return SavedServer(
    id: id,
    name: name,
    username: 'alice',
    lines: [
      for (var i = 0; i < addresses.length; i++)
        ServerLine(id: 'line-${i + 1}', address: addresses[i]),
    ],
    activeLineId: activeLineId,
  );
}

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeEmbyServer second;

  setUp(() {
    server = FakeEmbyServer();
    second = FakeEmbyServer(
      serverId: 'server-id-2',
      serverName: '第二台',
      baseUrl: Uri.parse('http://emby-two.test:8096'),
    );
    adapter = FakeEmbyAdapter([server, second]);
  });

  AuthController controller({
    CredentialStore? credentials,
    ServerListStore? servers,
  }) {
    return AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: credentials ?? MemoryCredentialStore(),
      servers: servers ?? MemoryServerListStore(),
    );
  }

  test(
    'deleting a non-current server keeps the session, client and credentials',
    () async {
      final credentials = MemoryCredentialStore();
      final servers = MemoryServerListStore();
      final auth = controller(credentials: credentials, servers: servers);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: second.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;

      await auth.deleteServer(server.serverId);

      // 当前会话与播放(仍挂载的 client 线路)不变。
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session?.server.id, second.serverId);
      expect(auth.session?.accessToken, token);
      expect(auth.client.baseUrl, second.baseUrl);
      expect(
        await auth.client.getJson('/System/Info'),
        containsPair('ServerName', '第二台'),
      );
      // 列表只余当前服务器,被删服务器与本机凭据一并移除。
      expect(auth.savedServers.map((item) => item.id), [second.serverId]);
      expect(await credentials.read(server.serverId), isNull);
      expect((await credentials.read(second.serverId))?.accessToken, token);
      final snapshot = await servers.load();
      expect(snapshot.servers.single.id, second.serverId);
      expect(snapshot.lastServerId, second.serverId);
      auth.dispose();
    },
  );

  test(
    'deleting the current server signs out, drops credentials and cannot re-enter',
    () async {
      final credentials = MemoryCredentialStore();
      final servers = MemoryServerListStore();
      final auth = controller(credentials: credentials, servers: servers);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: second.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;

      await auth.deleteServer(second.serverId);

      // 会话结束、client 卸载:播放页面随之回到登录页。
      expect(auth.isLoggedIn, isFalse);
      expect(auth.session, isNull);
      expect(auth.prefill, isNull);
      expect(auth.client.baseUrl, isNull);
      expect(auth.client.accessToken, isNull);
      // 已存凭据被清除,不能凭其直接进入。
      expect(await credentials.read(second.serverId), isNull);
      expect(auth.savedServers.map((item) => item.id), [server.serverId]);
      final snapshot = await servers.load();
      expect(snapshot.lastServerId, isNull);

      // 同一份存储重启后不会自动进入被删服务器。
      final revived = controller(credentials: credentials, servers: servers);
      await revived.restore();
      expect(revived.isLoggedIn, isFalse);
      expect(revived.prefill, isNull);

      // 服务器端账号仍在,可重新登录。
      await revived.connect(
        address: second.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      expect(revived.isLoggedIn, isTrue);
      expect(revived.session?.server.id, second.serverId);
      expect(revived.session?.accessToken, isNot(token));
      auth.dispose();
      revived.dispose();
    },
  );

  test('deleting an unknown server id is a no-op', () async {
    final servers = MemoryServerListStore(
      const ServerListSnapshot(servers: [], lastServerId: null),
    );
    final auth = controller(servers: servers);
    await auth.deleteServer('missing');
    expect(auth.savedServers, isEmpty);
    expect(auth.isLoggedIn, isFalse);
    auth.dispose();
  });

  testWidgets(
    'switcher delete confirms first; cancel keeps the server untouched',
    (tester) async {
      final deleted = <String>[];
      final initial = [
        _saved('server-id-1', '家庭影院', ['http://emby.test:8096']),
        _saved('server-id-2', '第二台', [
          'http://emby-two.test:8096',
          'http://emby-wan.test:8096',
        ], activeLineId: 'line-2'),
      ];

      Future<void> pump(List<SavedServer> servers) {
        return tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: ServerSwitcherDialog(
                servers: servers,
                activeServerId: 'server-id-1',
                activeLineId: 'line-1',
                onSelect: (_, _) {},
                onAddServer: () {},
                onLogout: () {},
                onDelete: deleted.add,
                onChangePassword: () {},
                onAddLine: (_) {},
                onEditLine: (_, _) {},
                onDeleteLine: (_, _) {},
              ),
            ),
          ),
        );
      }

      await pump(initial);
      await tester.pumpAndSettle();
      expect(find.text('家庭影院'), findsOneWidget);
      expect(find.text('第二台'), findsOneWidget);

      // 取消确认:不删除任何内容。
      await tester.tap(
        find.byKey(ServerSwitcherDialog.deleteKey('server-id-2')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('第二台'), findsWidgets);
      await tester.tap(find.byKey(ServerSwitcherDialog.deleteCancelKey));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      expect(find.text('第二台'), findsOneWidget);

      // 确认删除:回调拿到被删服务器 id。
      await tester.tap(
        find.byKey(ServerSwitcherDialog.deleteKey('server-id-2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ServerSwitcherDialog.deleteConfirmKey));
      await tester.pumpAndSettle();
      expect(deleted, ['server-id-2']);

      // 删除后列表不再出现,搜索也找不到。
      final remaining = [
        _saved('server-id-1', '家庭影院', ['http://emby.test:8096']),
      ];
      await pump(remaining);
      await tester.pumpAndSettle();
      expect(find.text('家庭影院'), findsOneWidget);
      expect(find.text('第二台'), findsNothing);
      // 服务器很少时一眼可见,不再提供空搜索框。
      expect(find.byKey(ServerSwitcherDialog.searchField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switcher offers search only once the list grows long', (
    tester,
  ) async {
    final servers = [
      for (var i = 1; i <= 6; i++)
        _saved('server-id-$i', '服务器 $i', ['http://emby-$i.test:8096']),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ServerSwitcherDialog(
            servers: servers,
            activeServerId: 'server-id-1',
            activeLineId: 'line-1',
            onSelect: (_, _) {},
            onAddServer: () {},
            onLogout: () {},
            onDelete: (_) {},
            onChangePassword: () {},
            onAddLine: (_) {},
            onEditLine: (_, _) {},
            onDeleteLine: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(ServerSwitcherDialog.searchField),
      'emby-6',
    );
    await tester.pump();
    expect(find.text('服务器 1'), findsNothing);
    expect(find.text('服务器 6'), findsOneWidget);
    await tester.enterText(find.byKey(ServerSwitcherDialog.searchField), '无');
    await tester.pump();
    expect(find.text('暂无已保存的服务器'), findsOneWidget);
    // 筛选为空时搜索框仍保留,便于改词。
    expect(find.byKey(ServerSwitcherDialog.searchField), findsOneWidget);
  });

  testWidgets(
    'switcher panel paints an opaque surface above background content in both themes',
    (tester) async {
      Future<void> pump(ThemeData theme) {
        return tester.pumpWidget(
          MaterialApp(
            theme: theme,
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              // 模拟详情页背景:海报占位与简介露出在切换面板之外。
              body: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xFF29486B)),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('背景简介', key: Key('switcher-backdrop-overview')),
                  ),
                  Center(
                    child: ServerSwitcherDialog(
                      servers: [
                        _saved('server-id-1', '家庭影院', [
                          'http://emby.test:8096',
                        ]),
                      ],
                      activeServerId: 'server-id-1',
                      activeLineId: 'line-1',
                      onSelect: (_, _) {},
                      onAddServer: () {},
                      onLogout: () {},
                      onDelete: (_) {},
                      onChangePassword: () {},
                      onAddLine: (_) {},
                      onEditLine: (_, _) {},
                      onDeleteLine: (_, _) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await pump(theme);
        await tester.pumpAndSettle();
        final scheme = theme.colorScheme;

        // 面板底色来自 colorScheme 且完全不透明:背景海报/简介/播放控件
        // 被面板完全隔开,不会透到服务器名/地址/搜索/添加/退出的文字层。
        final panel = tester.widget<Material>(
          find.byKey(ServerSwitcherDialog.panelKey),
        );
        final panelColor = panel.color!;
        expect(panelColor, scheme.surface);
        expect(panelColor.a, 1.0);

        // 背景内容仍在面板之外可见,不与面板文字同层。
        final backdropRect = tester.getRect(
          find.byKey(const Key('switcher-backdrop-overview')),
        );
        final panelRect = tester.getRect(
          find.byKey(ServerSwitcherDialog.panelKey),
        );
        expect(backdropRect.overlaps(panelRect), isFalse);

        // 面板文字与底色满足 R12 的 3:1 对比要求。
        final nameContext = tester.element(find.text('家庭影院'));
        final nameColor = DefaultTextStyle.of(nameContext).style.color!;
        final lighter =
            nameColor.computeLuminance() > panelColor.computeLuminance()
            ? nameColor
            : panelColor;
        final darker = lighter == nameColor ? panelColor : nameColor;
        final contrast =
            (lighter.computeLuminance() + 0.05) /
            (darker.computeLuminance() + 0.05);
        expect(contrast, greaterThan(3));
      }
    },
  );
}
