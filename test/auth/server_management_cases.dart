import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import 'configured_source.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';

import 'server_ui_harness.dart';
import '../helpers/cupertino_test_app.dart';

import 'package:rillight/auth/server_password_form.dart';

import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';

const _device = ClientDeviceInfo(
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

class _EditorFailingStore extends MemoryServerListStore {
  bool fail = false;
  @override
  Future<void> save(ServerListSnapshot value) async {
    if (fail) throw StateError('synthetic disk failure');
    await super.save(value);
  }
}

void main() {
  testWidgets(
    'entry password cooldown blocks both submit actions and expires; leaving cancels its timer',
    (tester) async {
      var now = DateTime(2026, 10, 18);
      final retryAt = now.add(const Duration(seconds: 2));
      final submitted = <String>[];
      Widget form(DateTime deadline) => CupertinoTestApp(
        home: CupertinoPageScaffold(
          child: ServerUnlockForm(
            retryAt: deadline,
            clock: () => now,
            error: '密码不正确。',
            onSubmit: submitted.add,
          ),
        ),
      );
      await tester.pumpWidget(form(retryAt));
      await tester.enterText(
        find.byKey(const Key('server-unlock-password')),
        'correct',
      );
      expect(find.text('密码不正确。'), findsOneWidget);
      expect(find.text('2 秒后可重试'), findsOneWidget);
      final submit = find.byKey(const Key('server-unlock-submit'));
      expect(tester.widget<AppButton>(submit).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submitted, isEmpty);
      now = retryAt;
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('2 秒后可重试'), findsNothing);
      expect(tester.widget<AppButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      expect(submitted, ['correct']);
      await tester.pumpWidget(form(now.add(const Duration(seconds: 30))));
      expect(tester.widget<AppButton>(submit).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
      expect(tester.takeException(), isNull);
    },
  );

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

  test('password and editor configuration commit together and preserve the old state on save failure', () async {
    final store = _EditorFailingStore();
    final auth = controller(servers: store);
    addTearDown(auth.dispose);
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final original = auth.session!.server, token = auth.session!.accessToken;
    await auth.serverAccess.register(original);
    Future<String> change() => auth.serverAccess.setPassword(
      original.id,
      'local',
      'local',
      persistReference: (reference) => auth.saveConfiguration(
        original.id,
        nickname: '新名字',
        iconId: 'home',
        userAgent: original.userAgent ?? '',
        lines: original.lines,
        protectionRef: reference,
      ),
    );
    store.fail = true;
    await expectLater(change(), throwsStateError);
    expect(auth.savedServers.single.protectionRef, isNull);
    expect(auth.savedServers.single.displayName, original.displayName);
    expect(auth.serverAccess.isProtected(original.id), isFalse);
    store.fail = false;
    await change();
    expect(auth.savedServers.single.displayName, '新名字');
    expect(auth.savedServers.single.iconId, 'home');
    expect(
      auth.savedServers.single.protectionRef,
      auth.serverAccess.protectionRef(original.id),
    );
    expect((await store.load()).servers.single.protectionRef, isNotNull);
    expect(auth.session!.accessToken, token);
    expect(auth.serverAccess.allows(original.id), isFalse);
  });

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

      await auth.deleteServer(configuredSourceId(auth, server.serverId));

      // 当前会话与播放(仍挂载的 client 线路)不变。
      expect(auth.isLoggedIn, isTrue);
      expect(
        auth.session?.server.id,
        configuredSourceId(auth, second.serverId),
      );
      expect(auth.session?.accessToken, token);
      expect(auth.client.baseUrl, second.baseUrl);
      expect(
        await (auth.client as EmbyClient).getJson('/System/Info'),
        containsPair('ServerName', '第二台'),
      );
      // 列表只余当前服务器,被删服务器与本机凭据一并移除。
      expect(auth.savedServers.map((item) => item.id), [
        configuredSourceId(auth, second.serverId),
      ]);
      expect(
        await credentials.read(configuredSourceId(auth, server.serverId)),
        isNull,
      );
      expect(
        (await credentials.read(configuredSourceId(auth, second.serverId)))
            ?.accessToken,
        token,
      );
      final snapshot = await servers.load();
      expect(
        snapshot.servers.single.id,
        configuredSourceId(auth, second.serverId),
      );
      expect(snapshot.lastServerId, configuredSourceId(auth, second.serverId));
      auth.dispose();
    },
  );

  test('deleting the current server signs out, drops credentials and cannot re-enter', () async {
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

    await auth.deleteServer(configuredSourceId(auth, second.serverId));

    // 会话结束、client 卸载:播放页面随之回到登录页。
    expect(auth.isLoggedIn, isFalse);
    expect(auth.session, isNull);
    expect(auth.prefill, isNull);
    expect(auth.client.baseUrl, isNull);
    expect(auth.client.accessToken, isNull);
    // 已存凭据被清除,不能凭其直接进入。
    expect(
      await credentials.read(configuredSourceId(auth, second.serverId)),
      isNull,
    );
    expect(auth.savedServers.map((item) => item.id), [
      configuredSourceId(auth, server.serverId),
    ]);
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
    expect(revived.session?.server.verifiedServerId, second.serverId);
    expect(revived.session?.accessToken, isNot(token));
    auth.dispose();
    revived.dispose();
  });

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
    'server removal requires confirmation and only removes its own credentials',
    (tester) async {
      final auth = controller(
        servers: MemoryServerListStore(
          ServerListSnapshot(
            servers: [
              _saved('one', '家庭影院', ['http://emby.test:8096']),
              _saved('two', '另一台', ['http://emby-two.test:8096']),
            ],
          ),
        ),
        credentials: MemoryCredentialStore({
          'two': const StoredCredentials(
            accessToken: 'secret',
            userId: 'u',
            username: 'alice',
          ),
        }),
      );
      addTearDown(auth.dispose);
      await auth.restore();
      await pumpServerSelection(tester, auth);
      await serverUiTap(tester, const Key('server-more-two'));
      await serverUiTap(tester, const Key('server-action-remove-two'));
      expect(find.textContaining('不会删除服务器上的内容'), findsOneWidget);
      await serverUiTap(tester, const Key('server-remove-cancel'));
      expect(auth.savedServers, hasLength(2));
      await serverUiTap(tester, const Key('server-more-two'));
      await serverUiTap(tester, const Key('server-action-remove-two'));
      await serverUiTap(tester, const Key('server-remove-confirm'));
      expect(auth.savedServers.single.id, 'one');
      expect(await auth.credentials.read('two'), isNull);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('search matches address and an empty search can be recovered', (
    tester,
  ) async {
    final auth = controller(
      servers: MemoryServerListStore(
        ServerListSnapshot(
          servers: [
            for (var i = 1; i <= 6; i++)
              _saved('s$i', '家庭影院', ['https://emby-$i.test']),
          ],
        ),
      ),
    );
    addTearDown(auth.dispose);
    await auth.restore();
    await pumpServerSelection(tester, auth);
    await tester.enterText(find.byKey(const Key('server-search')), 'emby-6');
    await tester.pump();
    expect(find.byKey(const Key('server-enter-s6')), findsOneWidget);
    expect(find.byKey(const Key('server-enter-s1')), findsNothing);
    await tester.enterText(find.byKey(const Key('server-search')), 'none');
    await tester.pump();
    expect(find.text('没有找到服务器'), findsOneWidget);
    await tester.tap(find.text('清除搜索'));
    await settle(tester);
    expect(find.byKey(const Key('server-enter-s1')), findsOneWidget);
  }, tags: ['integration']);

  testWidgets(
    'metadata draft cancels without writes and saves without replacing the session',
    (tester) async {
      final auth = controller();
      addTearDown(auth.dispose);
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      final id = auth.session!.server.id, client = auth.client;
      await pumpServerSelection(tester, auth);
      bool focusedWithin(Key key) {
        final targets = find.byKey(key).evaluate().toSet();
        var found = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          if (targets.contains(element)) found = true;
          return !found;
        });
        return found;
      }

      final linesKey = Key('server-lines-$id');
      for (var i = 0; i < 24 && !focusedWithin(linesKey); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedWithin(linesKey), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(const Key('server-line-auto')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(focusedWithin(Key('server-enter-$id')), isTrue);
      await openServerEditor(tester, id);
      expect(find.byKey(const Key('server-editor-user-agent')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('server-editor-name')),
        '取消的名字',
      );
      await serverUiTap(tester, const Key('server-flow-back'));
      expect(auth.savedServers.single.displayName, isNot('取消的名字'));
      await openServerEditor(tester, id);
      await tester.enterText(
        find.byKey(const Key('server-editor-name')),
        '我的影院',
      );
      await serverUiTap(tester, const Key('server-editor-save'));
      expect(auth.savedServers.single.displayName, '我的影院');
      expect(identical(client, auth.client), isTrue);
      await serverUiTap(tester, Key('server-enter-$id'));
      expect(auth.savedServers.single.lineSelection.isAutomatic, isTrue);
      expect(find.byKey(const Key('server-search')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'explicit paste chooses a group and keeps editable partial fields without writes',
    (tester) async {
      final auth = controller();
      addTearDown(auth.dispose);
      await auth.restore();
      await pumpServerSelection(tester, auth);
      await serverUiTap(tester, const Key('server-add'));
      await serverUiTap(tester, const Key('server-add-paste'));
      await tester.enterText(
        find.byKey(const Key('server-paste-text')),
        '名称：第一台\n地址：https://first.test\n用户：alice\n密码：private-one\n名称：第二台\n地址：https://second.test\n用户：bob',
      );
      await serverUiTap(tester, const Key('server-paste-parse'));
      expect(find.byKey(const Key('provider-username')), findsNothing);
      expect(find.byKey(const Key('server-paste-group-0')), findsOneWidget);
      await serverUiTap(tester, const Key('server-paste-group-1'));
      expect(
        tester
            .widget<ui.AppTextField>(find.byKey(const Key('provider-address')))
            .controller!
            .text,
        'https://second.test',
      );
      expect(
        tester
            .widget<ui.AppTextField>(find.byKey(const Key('provider-username')))
            .controller!
            .text,
        'bob',
      );
      expect(
        tester
            .widget<ui.AppTextField>(find.byKey(const Key('provider-password')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('provider-password')),
        'filled-later',
      );
      expect(auth.savedServers, isEmpty);
      await serverUiTap(tester, const Key('server-flow-back'));
      expect(auth.savedServers, isEmpty);
    },
    tags: ['integration'],
  );
}
