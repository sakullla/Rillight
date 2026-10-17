import '../../helpers/cupertino_test_app.dart';

import 'dart:convert';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_selection_page.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../../helpers/image_cache_fixture.dart';
import '../../emby/fake_emby_server.dart';
import 'backup_import_cases.dart';

// Backup bytes come from the same synthetic fixtures as the parser suite:
// TEST-NET addresses and test keys only, no real account or client key.

const _device = ClientDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'backup-import-flow',
  version: '0.1.0',
);

PickedAppFile _backupFile(String name, List<int> bytes) => PickedAppFile(
  fileName: name,
  length: bytes.length,
  read: (limit) async => Uint8List.fromList(bytes),
);

/// 可注入的假选择边界:按脚本返回文件、取消或抛出 provider 缺失。
class _StubPicker implements AppFilePicker {
  _StubPicker(Future<PickedAppFile?> Function() behavior)
    : _behavior = behavior;
  final Future<PickedAppFile?> Function() _behavior;
  int calls = 0;

  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) {
    calls++;
    expect(allowedExtensions, containsAll(['json', 'rpb']));
    return _behavior();
  }
}

Future<List<int>> _mixedHillsBackup() => buildHillsBackup([
  hillsServer(
    displayName: 'Synthetic A',
    serverUrl: 'http://192.0.2.10:8096',
    username: 'alice',
    password: 'pw-a',
    authenticateJson: jsonEncode(<String, Object?>{
      'AccessToken': 'token-a',
      'User': {'Id': 'user-a', 'Name': 'alice'},
    }),
  ),
  hillsServer(
    displayName: 'Acc B',
    serverUrl: 'http://192.0.2.10:8096',
    username: 'bob',
  ),
  hillsServer(
    displayName: 'Jellyfin C',
    serverUrl: 'http://192.0.2.11:8920',
    isJellyfin: true,
  ),
  hillsServer(
    displayName: 'Private D',
    serverUrl: 'http://192.0.2.12:8096',
    isPrivate: true,
  ),
  hillsServer(
    displayName: '',
    serverName: '',
    serverUrl: 'http://192.0.2.13:8096',
  ),
]);

Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
  } on FlutterError {
    // Logged-in pages schedule retry timers that never go idle.
  }
}

void main() {
  setUp(isolateImageCache);

  testWidgets(
    'empty desktop connect page imports a hills backup with per-item results',
    (tester) async {
      final auth = AuthController.memory();
      addTearDown(auth.dispose);
      final bytes = await _mixedHillsBackup();
      auth.backupImportKeys = hillsKeys();
      auth.backupImportPicker = _StubPicker(
        () async => _backupFile('hills.json', bytes),
      );

      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);
      expect(auth.savedServers, isEmpty);

      await tester.ensureVisible(find.byKey(ConnectFormKeys.importBackup));
      await _settle(tester);
      await tester.tap(find.byKey(ConnectFormKeys.importBackup));
      await _settle(tester);

      expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
      expect(find.byKey(BackupImportFlowKeys.loading), findsNothing);
      expect(_text(tester, BackupImportFlowKeys.added), '新增 3 台');
      expect(
        _text(tester, BackupImportFlowKeys.pendingLogin),
        '已带凭据 1 个 · 待登录 2 个',
      );
      expect(find.byKey(BackupImportFlowKeys.nonTarget), findsNothing);
      expect(_text(tester, BackupImportFlowKeys.failed), '失败 1 条');
      expect(
        _text(tester, BackupImportFlowKeys.privateSkipped),
        '私密区域未解锁，跳过 1 条',
      );

      final servers = auth.savedServers;
      expect(servers, hasLength(3));
      final a = servers.firstWhere((s) => s.username == 'alice');
      final b = servers.firstWhere((s) => s.username == 'bob');
      expect(a.lines.first.address, 'http://192.0.2.10:8096');
      expect(b.lines.first.address, 'http://192.0.2.10:8096');
      expect(a.id, isNot(b.id));
      expect((await auth.credentials.read(a.id))?.accessToken, 'token-a');
      expect(await auth.credentials.read(b.id), isNull);
      expect(auth.isLoggedIn, isFalse);
      expect(auth.failure, isNull);

      await tester.tap(find.byKey(BackupImportFlowKeys.close));
      await _settle(tester);
      expect(find.byKey(BackupImportFlowKeys.result), findsNothing);
    },
    tags: ['integration'],
  );

  testWidgets('re-import stays idempotent and same-address accounts coexist', (
    tester,
  ) async {
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    final first = await buildHillsBackup([
      hillsServer(
        displayName: 'Dup A',
        serverUrl: 'http://192.0.2.10:8096',
        username: 'alice',
      ),
    ]);
    final second = await buildHillsBackup([
      hillsServer(
        displayName: 'Dup A',
        serverUrl: 'http://192.0.2.10:8096',
        username: 'alice',
      ),
      hillsServer(
        displayName: 'Dup A',
        serverUrl: 'http://192.0.2.20:8096',
        username: 'alice',
      ),
      hillsServer(
        displayName: 'Acc B',
        serverUrl: 'http://192.0.2.10:8096',
        username: 'bob',
      ),
    ]);
    final queue = <PickedAppFile>[
      _backupFile('first.json', first),
      _backupFile('second.json', second),
      _backupFile('second.json', second),
    ];
    auth.backupImportKeys = hillsKeys();
    auth.backupImportPicker = _StubPicker(() async => queue.removeAt(0));

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    for (var round = 0; round < 3; round++) {
      await tester.ensureVisible(find.byKey(ConnectFormKeys.importBackup));
      await _settle(tester);
      await tester.tap(find.byKey(ConnectFormKeys.importBackup));
      await _settle(tester);
      expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
      await tester.tap(find.byKey(BackupImportFlowKeys.close));
      await _settle(tester);
    }

    // 同名不同地址、同址不同账号都保留为独立配置;重复不覆盖任何已有线路。
    expect(auth.savedServers, hasLength(3));
    expect(auth.savedServers.map((s) => s.lines.first.address).toSet(), {
      'http://192.0.2.10:8096',
      'http://192.0.2.20:8096',
    });
    expect(
      auth.savedServers
          .firstWhere((s) => s.lines.first.address == 'http://192.0.2.10:8096')
          .lines,
      hasLength(1),
    );
  }, tags: ['integration']);

  testWidgets('cancelling the picker changes nothing anywhere', (tester) async {
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    auth.backupImportPicker = _StubPicker(() async => null);

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await tester.ensureVisible(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);
    await tester.tap(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);

    expect(find.byKey(BackupImportFlowKeys.result), findsNothing);
    expect(find.byKey(BackupImportFlowKeys.failure), findsNothing);
    expect(auth.savedServers, isEmpty);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure, isNull);
  }, tags: ['integration']);

  testWidgets('a whole-file failure reports the reason and writes nothing', (
    tester,
  ) async {
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    final bytes = utf8.encode('not a backup at all');
    auth.backupImportPicker = _StubPicker(
      () async => _backupFile('broken.json', bytes),
    );

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await tester.ensureVisible(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);
    await tester.tap(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);

    expect(find.byKey(BackupImportFlowKeys.failure), findsOneWidget);
    expect(_text(tester, BackupImportFlowKeys.failureMessage), '无法识别的备份格式');
    expect(auth.savedServers, isEmpty);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure, isNull);

    await tester.tap(find.byKey(BackupImportFlowKeys.close));
    await _settle(tester);
    expect(find.byKey(BackupImportFlowKeys.failure), findsNothing);
  }, tags: ['integration']);

  testWidgets('a missing decryption key is reported instead of faked success', (
    tester,
  ) async {
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    final bytes = await buildHillsBackup([
      hillsServer(displayName: 'A', serverUrl: 'http://192.0.2.10:8096'),
    ]);
    // 缺省注入点:不携带任何客户端密钥。
    auth.backupImportPicker = _StubPicker(
      () async => _backupFile('hills.json', bytes),
    );

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await tester.ensureVisible(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);
    await tester.tap(find.byKey(ConnectFormKeys.importBackup));
    await _settle(tester);

    expect(find.byKey(BackupImportFlowKeys.failure), findsOneWidget);
    expect(
      _text(tester, BackupImportFlowKeys.failureMessage),
      '缺少解密密钥，未读取加密内容',
    );
    expect(auth.savedServers, isEmpty);
  }, tags: ['integration']);

  testWidgets('phone manager imports over the sheet and refreshes the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const first = SavedServer(
      id: 'one',
      name: '家里的影音库',
      username: 'alice',
      lines: [ServerLine(id: 'line-one', address: 'http://home.test:8096')],
    );
    const second = SavedServer(
      id: 'two',
      name: '备用服务器',
      username: 'bob',
      lines: [ServerLine(id: 'line-two', address: 'https://backup.test')],
    );
    final auth = AuthController(
      client: EmbyClient(device: _device),
      credentials: MemoryCredentialStore({
        'one': const StoredCredentials(
          accessToken: 'synthetic',
          userId: 'user',
          username: 'alice',
        ),
      }),
      servers: MemoryServerListStore(
        const ServerListSnapshot(servers: [first, second]),
      ),
    );
    addTearDown(auth.dispose);
    await auth.restore();
    final bytes = await buildHillsBackup([
      hillsServer(
        displayName: 'New C',
        serverUrl: 'http://192.0.2.10:8096',
        username: 'carol',
      ),
      // 与已有 one 同址同账号:重复,不覆盖原配置。
      hillsServer(
        displayName: '家里的影音库',
        serverUrl: 'http://home.test:8096',
        username: 'alice',
      ),
      hillsServer(
        displayName: 'Private D',
        serverUrl: 'http://192.0.2.12:8096',
        isPrivate: true,
      ),
    ]);
    auth.backupImportKeys = hillsKeys();
    auth.backupImportPicker = _StubPicker(
      () async => _backupFile('hills.json', bytes),
    );

    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: CupertinoPageScaffold(
          child: Builder(
            builder: (context) => AppButton(
              onPressed: () =>
                  showServerSelection(context, auth: auth, phone: true),
              child: const Text('open-manager'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-manager'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('server-add')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ServerSelectionPage.importKey));
    await tester.tap(find.byKey(ServerSelectionPage.importKey));
    await tester.pumpAndSettle();

    expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
    expect(_text(tester, BackupImportFlowKeys.added), '新增 1 台');
    expect(_text(tester, BackupImportFlowKeys.duplicate), '重复跳过 1 台');
    expect(
      _text(tester, BackupImportFlowKeys.privateSkipped),
      '私密区域未解锁，跳过 1 条',
    );

    await tester.tap(find.byKey(BackupImportFlowKeys.close));
    await tester.pumpAndSettle();

    // 底表仍在,列表刷新出新增服务器;已有配置未被覆盖。
    expect(find.byType(ServerSelectionPage), findsNothing);
    expect(auth.savedServers, hasLength(3));
    final one = auth.savedServers.firstWhere((s) => s.id == 'one');
    expect(one.lines.single.address, 'http://home.test:8096');
    expect(auth.isLoggedIn, isFalse);
  }, tags: ['integration']);

  testWidgets(
    'tv completes import with the remote and reports a missing provider',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthController.memory();
      addTearDown(auth.dispose);
      final bytes = await buildCommonConfig([
        commonEntry(
          type: 'emby',
          name: 'TV A',
          url: 'http://192.0.2.40:8096',
          authorization: authorization(),
        ),
        commonEntry(
          type: 'plex',
          name: 'TV Not Target',
          url: 'http://192.0.2.41:8920',
        ),
      ], selfKey: selfCarriedTestKey);
      auth.backupImportPicker = _StubPicker(
        () async => _backupFile('common.json', bytes),
      );

      await tester.pumpWidget(
        CupertinoTestApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: AuthScope(controller: auth, child: const TvConnectPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tv-connect-import')));
      await tester.pumpAndSettle();

      expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
      expect(_text(tester, BackupImportFlowKeys.added), '新增 1 台');
      expect(_text(tester, BackupImportFlowKeys.nonTarget), '不支持的服务类型 1 条');

      // 方向键不误触面板其它控件;Select(确认)关闭结果并回到连接页。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(BackupImportFlowKeys.result), findsNothing);
      expect(auth.savedServers.single.name, 'TV A');

      // 没有文件 provider 的电视如实报告,不把降级当成功。
      auth.backupImportPicker = _StubPicker(
        () async =>
            throw const AppFilePickerUnavailableException('no-provider'),
      );
      await tester.tap(find.byKey(const ValueKey('tv-connect-import')));
      await tester.pumpAndSettle();
      expect(find.byKey(BackupImportFlowKeys.failure), findsOneWidget);
      expect(find.text('此设备没有可用的文件选择器，无法选择备份文件'), findsOneWidget);
      // 返回键路径关闭失败面板。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(BackupImportFlowKeys.failure), findsNothing);
      expect(auth.savedServers, hasLength(1));
    },
    tags: ['integration'],
  );

  testWidgets('server switcher imports without touching the active session', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final bytes = await buildHillsBackup([
      hillsServer(
        displayName: 'New B',
        serverUrl: 'http://192.0.2.10:8096',
        username: 'bob',
      ),
      // 与当前登录服务器同址同账号:重复。
      hillsServer(
        displayName: '当前服务器',
        serverUrl: server.baseUrl.toString(),
        username: 'alice',
      ),
    ]);
    auth.backupImportKeys = hillsKeys();
    auth.backupImportPicker = _StubPicker(
      () async => _backupFile('hills.json', bytes),
    );

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);
    final tokenBefore = auth.session?.accessToken;
    final serverIdBefore = auth.session?.server.id;

    await tester.tap(find.byKey(SessionActions.serverMenuKey));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('server-add')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('server-add-import')));
    await tester.tap(find.byKey(const Key('server-add-import')));
    await _settle(tester);

    expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
    expect(_text(tester, BackupImportFlowKeys.added), '新增 1 台');
    expect(_text(tester, BackupImportFlowKeys.duplicate), '重复跳过 1 台');
    expect(find.byType(ServerSelectionPage), findsNothing);

    await tester.tap(find.byKey(BackupImportFlowKeys.close));
    await _settle(tester);

    // 活动会话、当前线路与已保存配置不受导入影响。
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session?.accessToken, tokenBefore);
    expect(auth.session?.server.id, serverIdBefore);
    expect(auth.savedServers, hasLength(2));
    expect(auth.client.baseUrl.toString(), server.baseUrl.toString());
  }, tags: ['integration']);
}

String? _text(WidgetTester tester, Key key) {
  final widget = tester.widget(find.byKey(key));
  if (widget is Text) return widget.data;
  return tester
      .widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      )
      .data;
}
