import '../mobile/tv_server_test_helpers.dart';

import 'package:rillight/app/tv_widgets.dart';

import '../helpers/cupertino_test_app.dart';

import 'package:dio/dio.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import 'configured_source.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';

import 'server_ui_harness.dart';

import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

// These endpoints represent one server, so they share its issued tokens.
class _SameServerAdapter extends FakeEmbyAdapter {
  _SameServerAdapter(this.endpoints) : super(endpoints);
  final List<FakeEmbyServer> endpoints;
  bool offline = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) {
    if (offline) {
      return Future.error(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
    }
    for (final server in endpoints) {
      server.issuedTokens.addAll(
        endpoints
            .where((s) => s.serverId == server.serverId)
            .expand((s) => s.issuedTokens)
            .toList(),
      );
    }
    return super.fetch(options, stream, cancelled);
  }
}

const _device = ClientDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-line-management',
  version: '0.1.0',
);

void main() {
  for (final failure in [
    'certificate',
    'forbidden',
    'sessionExpired',
    'unreachable',
    'unknown',
  ]) {
    testWidgets(
      'manual line check presents and retains $failure then clears it on recovery',
      (tester) async {
        final remote = FakeEmbyServer();
        final adapter = _SameServerAdapter([remote]);
        final auth = AuthController.memory(
          client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
        );
        addTearDown(auth.dispose);
        await tester.runAsync(
          () => auth.connect(
            address: remote.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final id = auth.session!.server.id,
            lineId = auth.session!.server.activeLineId!;
        await pumpServerSelection(tester, auth);
        await serverUiTap(tester, Key('server-lines-$id'));
        adapter.certificateError = failure == 'certificate';
        adapter.offline = failure == 'unreachable';
        remote.publicInfoStatus = switch (failure) {
          'forbidden' => 403,
          'sessionExpired' => 401,
          'unknown' => 503,
          _ => null,
        };
        await serverUiTap(tester, Key('server-line-check-$lineId'));
        final label = switch (failure) {
          'certificate' => '服务器证书校验失败，请检查服务器配置。',
          'forbidden' => '当前账号无权访问，请检查共享权限或重新授权。',
          'sessionExpired' => '请重新登录',
          'unreachable' => '无法连接服务器',
          _ => '连接失败，可重试或换线',
        };
        expect(find.textContaining(label), findsWidgets);
        expect(find.textContaining('检查于'), findsWidgets);
        final stored = auth.savedServers.single.lines.single;
        expect(ServerLine.fromJson(stored.toJson()).checkFailureKind, failure);
        expect(auth.session!.server.id, id);
        await serverUiTap(tester, const Key('server-flow-back'));
        await serverUiTap(tester, Key('server-lines-$id'));
        expect(find.textContaining(label), findsWidgets);
        adapter.certificateError = false;
        adapter.offline = false;
        remote.publicInfoStatus = null;
        await serverUiTap(tester, Key('server-line-check-$lineId'));
        expect(find.textContaining(label), findsNothing);
        expect(find.textContaining('连接正常'), findsWidgets);
        expect(auth.savedServers.single.lines.single.checkFailureKind, isNull);
      },
      tags: ['integration'],
    );
  }
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
          dio: dioForFakeEmby(_SameServerAdapter([lan, wan, wan3])),
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

      final ok = await auth.addLine(
        configuredSourceId(auth, lan.serverId),
        wan3.baseUrl.toString(),
      );

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
        dio: dioForFakeEmby(_SameServerAdapter([lan, wan])),
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

    expect(
      await auth.addLine(
        configuredSourceId(auth, lan.serverId),
        'ftp://nope.test',
      ),
      isFalse,
    );
    expect(
      await auth.addLine(configuredSourceId(auth, lan.serverId), '  '),
      isFalse,
    );
    expect(
      await auth.addLine(
        configuredSourceId(auth, lan.serverId),
        lan.baseUrl.toString(),
      ),
      isFalse,
    );
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
          dio: dioForFakeEmby(_SameServerAdapter([lan, wan, wan3])),
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
        configuredSourceId(auth, lan.serverId),
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
          dio: dioForFakeEmby(_SameServerAdapter([lan, wan, wan3])),
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
        configuredSourceId(auth, lan.serverId),
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
      await (auth.client as EmbyClient).getJson('/System/Info');
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
        dio: dioForFakeEmby(_SameServerAdapter([lan, wan])),
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
        configuredSourceId(auth, lan.serverId),
        'missing-line',
        wan.baseUrl.toString(),
      ),
      isFalse,
    );
    expect(
      await auth.updateLineAddress(
        configuredSourceId(auth, lan.serverId),
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
      await auth.updateLineAddress(
        configuredSourceId(auth, lan.serverId),
        lanLine.id,
        'ftp://x',
      ),
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
        dio: dioForFakeEmby(_SameServerAdapter([lan, wan])),
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

    await auth.deleteLine(configuredSourceId(auth, lan.serverId), lanLine.id);
    expect(auth.savedServers.single.lines, hasLength(1));

    // 只剩一条时删除不执行。
    await auth.deleteLine(
      configuredSourceId(auth, lan.serverId),
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
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => ui.AppButton(
            key: const Key('open-line-dialog'),
            onPressed: () async {
              result = await showLineAddressDialog(context);
            },
            child: const Text('open'),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-line-dialog')));
    await settle(tester);

    // 只有地址输入,没有 User-Agent 输入项。
    expect(find.byType(ui.AppTextField), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);
    // 添加模式:地址为空时不可提交。
    expect(
      tester
          .widget<ui.AppButton>(find.byKey(LineAddressDialog.submitKey))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(LineAddressDialog.fieldKey),
      '  http://line-wan.test:8096  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(LineAddressDialog.submitKey));
    await settle(tester);
    expect(result, 'http://line-wan.test:8096');
  });

  testWidgets('line address dialog prefills and can cancel', (tester) async {
    String? result = 'untouched';
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => ui.AppButton(
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
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-line-dialog')));
    await settle(tester);
    expect(
      tester
          .widget<ui.AppTextField>(find.byKey(LineAddressDialog.fieldKey))
          .controller!
          .text,
      'http://line-lan.test:8096',
    );
    expect(find.text('修改线路地址'), findsOneWidget);
    expect(find.text('User-Agent'), findsNothing);

    // 取消不改动任何内容。
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(result, isNull);
  });

  for (final phone in [false, true]) {
    testWidgets(
      'concentrated line draft validates then saves on ${phone ? "phone" : "desktop"}',
      (tester) async {
        tester.view.physicalSize = Size(phone ? 360 : 1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final lan = FakeEmbyServer();
        final wan = FakeEmbyServer(
          serverId: lan.serverId,
          baseUrl: Uri.parse('http://draft-wan.test:8096'),
        );
        final moved = FakeEmbyServer(
          serverId: lan.serverId,
          baseUrl: Uri.parse('http://draft-moved.test:8096'),
        );
        final auth = AuthController.memory(
          client: EmbyClient(
            device: _device,
            dio: dioForFakeEmby(_SameServerAdapter([lan, wan, moved])),
          ),
        );
        addTearDown(auth.dispose);
        await tester.runAsync(
          () => auth.connect(
            address: lan.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final id = auth.session!.server.id;
        await pumpServerSelection(tester, auth, phone: phone);
        await openServerEditor(tester, id);
        await serverUiTap(tester, const Key('server-editor-add-line'));
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          lan.baseUrl.toString(),
        );
        await serverUiTap(tester, const Key('server-line-done'));
        expect(find.text('请填写服务器名称和有效地址；线路地址不能重复。'), findsOneWidget);
        expect(auth.savedServers.single.lines, hasLength(1));
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          wan.baseUrl.toString(),
        );
        await tester.enterText(find.byKey(const Key('server-line-name')), '外网');
        await serverUiTap(tester, const Key('server-line-done'));
        expect(auth.savedServers.single.lines, hasLength(1));
        await serverUiTap(tester, const Key('server-editor-save'));
        expect(auth.savedServers.single.lines, hasLength(2));
        expect(auth.savedServers.single.lines.last.nickname, '外网');
        expect(auth.client.baseUrl, lan.baseUrl);
        await serverUiTap(tester, Key('server-lines-$id'));
        expect(find.byKey(const Key('server-line-auto')), findsOneWidget);
        expect(find.byKey(const Key('server-editor-add-line')), findsNothing);
        await serverUiTap(tester, const Key('server-line-auto'));
        expect(auth.savedServers.single.lineSelection.isAutomatic, isTrue);

        // Existing current-line edits stay drafts until impact confirmation.
        await serverUiTap(tester, const Key('server-flow-back'));
        final activeId = auth.savedServers.single.activeLineId!;
        Future<void> editCurrent() async {
          await openServerEditor(tester, id);
          await serverUiTap(tester, Key('server-editor-line-$activeId'));
          await tester.enterText(
            find.byKey(const Key('server-line-address')),
            moved.baseUrl.toString(),
          );
          await serverUiTap(tester, const Key('server-line-done'));
          await serverUiTap(tester, const Key('server-editor-save'));
        }

        await editCurrent();
        expect(find.byKey(const Key('server-impact-confirm')), findsOneWidget);
        expect(auth.client.baseUrl, lan.baseUrl);
        await serverUiTap(tester, const Key('server-flow-back'));
        expect(find.text(moved.baseUrl.toString()), findsOneWidget);
        await serverUiTap(tester, const Key('server-flow-back'));
        expect(
          auth.savedServers.single.activeLine!.address,
          lan.baseUrl.toString(),
        );

        await editCurrent();
        moved.publicInfoStatus = 503;
        await serverUiTap(tester, const Key('server-impact-confirm'));
        expect(auth.client.baseUrl, lan.baseUrl);
        expect(find.text(moved.baseUrl.toString()), findsOneWidget);
        expect(find.byKey(const Key('server-editor-save')), findsOneWidget);
        moved.publicInfoStatus = null;
        await serverUiTap(tester, const Key('server-editor-save'));
        await serverUiTap(tester, const Key('server-impact-confirm'));
        expect(auth.client.baseUrl, moved.baseUrl);
        expect(auth.savedServers.single.activeLineId, activeId);

        // Removing a standby line is draft-only; after save the final line's
        // menu cannot remove it (desktop keyboard and phone share this control).
        await openServerEditor(tester, id);
        final standbyId = auth.savedServers.single.lines
            .firstWhere((l) => l.id != activeId)
            .id;
        await serverUiTap(tester, Key('server-editor-line-more-$standbyId'));
        await tester.tap(find.text('移除这条线路'));
        await settle(tester);
        expect(auth.savedServers.single.lines, hasLength(2));
        expect(find.byKey(Key('server-editor-line-$standbyId')), findsNothing);
        await serverUiTap(tester, const Key('server-editor-save'));
        expect(auth.savedServers.single.lines, hasLength(1));
        expect(auth.client.baseUrl, moved.baseUrl);
        await openServerEditor(tester, id);
        expect(
          tester
              .widget<AppMenuButton<String>>(
                find.byKey(Key('server-editor-line-more-$activeId')),
              )
              .onSelected,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  // ---------- tv settings pane ----------

  testWidgets(
    'TV centralized editor adds and deletes draft lines with remote',
    (tester) async {
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
          dio: dioForFakeEmby(_SameServerAdapter([lan, wan, wan3])),
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
      await settle(tester);

      final serverId = auth.savedServers.single.id;
      await tvPress(tester, const Key('tv-nav-user'));
      await tvOpenEditor(tester, serverId);
      await tvPress(tester, const Key('server-editor-add-line'));
      await tvEdit(
        tester,
        const Key('server-line-address'),
        wan3.baseUrl.toString(),
      );
      await tvPress(tester, const Key('server-line-done'));
      // A draft cannot change the running connection before Save.
      expect(auth.savedServers.single.lines, hasLength(2));
      await tvPress(tester, const Key('server-editor-save'));
      expect(
        auth.savedServers.single.lines.map((l) => l.address),
        contains(wan3.baseUrl.toString()),
      );
      expect(auth.client.baseUrl, wan.baseUrl);
      ServerLine lineByAddress(String address) => auth.savedServers.single.lines
          .firstWhere((l) => l.address == address);
      final addedId = lineByAddress(wan3.baseUrl.toString()).id;
      final beforeOrder = auth.savedServers.single.lines
          .map((l) => l.id)
          .toList();
      await tvOpenEditor(tester, serverId);
      await tvPress(tester, Key('server-editor-line-more-$addedId'));
      await tvPress(tester, const Key('server-line-up'));
      expect(
        auth.savedServers.single.lines.map((l) => l.id).toList(),
        beforeOrder,
      );
      await tvPress(tester, const Key('server-editor-save'));
      expect(auth.savedServers.single.lines[1].id, addedId);
      expect(auth.client.baseUrl, wan.baseUrl);
      await tvOpenEditor(tester, serverId);
      for (final address in [lan.baseUrl.toString(), wan3.baseUrl.toString()]) {
        await tvPress(
          tester,
          Key('server-editor-line-more-${lineByAddress(address).id}'),
        );
        await tvPress(tester, const Key('server-line-remove'));
      }
      expect(auth.savedServers.single.lines, hasLength(3));
      await tvPress(tester, const Key('server-editor-save'));
      expect(auth.savedServers.single.lines, hasLength(1));
      await tvOpenEditor(tester, serverId);
      final last = auth.savedServers.single.lines.single;
      expect(
        tester
            .widget<TvAction>(
              find.byKey(Key('server-editor-line-more-${last.id}')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('TV line page explains failure and keeps the running line', (
    tester,
  ) async {
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
        dio: dioForFakeEmby(_SameServerAdapter([lan, wan])),
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
    await settle(tester);

    await tvPress(tester, const Key('tv-nav-user'));
    final serverId = auth.savedServers.single.id;
    final lanLine = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == lan.baseUrl.toString(),
    );
    lan.publicInfoStatus = 500;
    lan.publicInfoRawBody = 'upstream timeout';

    await tvPress(tester, Key('server-lines-$serverId'));
    await tvPress(tester, Key('server-line-choice-${lanLine.id}'));
    // Failed preflight never changes the current configuration or session.
    expect(auth.client.baseUrl, wan.baseUrl);
    expect(auth.session?.server.activeLine?.address, wan.baseUrl.toString());
    expect(find.textContaining('连接失败，原连接已保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
