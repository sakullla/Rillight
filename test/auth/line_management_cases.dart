import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:rillight/auth/server_line_selector.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_management_widgets.dart';

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
        expect(find.textContaining('ms'), findsWidgets);
        // Discovery and speed test are secondary actions on the line page.
        for (final key in ['server-lines-discover', 'server-lines-speed']) {
          expect(
            tester.widget<ui.AppActionButton>(find.byKey(Key(key))).tier,
            ui.AppActionTier.secondary,
          );
        }
        expect(auth.savedServers.single.lines.single.latencyMs, isNotNull);
        expect(auth.savedServers.single.lines.single.checkFailureKind, isNull);
      },
      tags: ['integration'],
    );
  }
  test('refresh reads lines from the emby_ext_domains sidecar', () async {
    final remote = FakeEmbyServer();
    final sidecar = FakeEmbyServer(
      serverId: remote.serverId,
      baseUrl: remote.baseUrl.replace(port: 52143),
    );
    sidecar.extendedDomains = [
      {'name': '家里', 'url': 'http://line-home.test:8096'},
    ];
    final home = FakeEmbyServer(
      serverId: remote.serverId,
      serverName: remote.serverName,
      baseUrl: Uri.parse('http://line-home.test:8096'),
    );
    final wan = FakeEmbyServer(
      serverId: remote.serverId,
      serverName: remote.serverName,
      baseUrl: Uri.parse('http://line-wan.test:8096'),
    );
    final client = EmbyClient(
      device: _device,
      dio: dioForFakeEmby(_SameServerAdapter([remote, sidecar, home, wan])),
    );
    final auth = AuthController.memory(client: client);
    addTearDown(auth.dispose);
    await auth.connect(
      address: remote.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(
      auth.savedServers.single.lines.map((line) => line.nickname),
      contains('家里'),
      reason: 'login should read the sidecar before a manual refresh',
    );
    sidecar.extendedDomains = [
      {'name': '家里', 'url': 'http://line-home.test:8096'},
      {'name': '外网', 'url': 'http://line-wan.test:8096'},
    ];
    final added = await auth.discoverExtendedLines(
      auth.session!.server.id,
      force: true,
    );
    expect(added, 1);
    expect(
      auth.savedServers.single.lines.map((line) => line.nickname),
      containsAll(['家里', '外网']),
    );
  });

  testWidgets(
    'refresh discovers emby_ext_domains lines and speed test shows latency',
    (tester) async {
      final remote = FakeEmbyServer();
      final sidecar = FakeEmbyServer(
        serverId: remote.serverId,
        baseUrl: remote.baseUrl.replace(port: 52143),
      );
      final home = FakeEmbyServer(
        serverId: remote.serverId,
        serverName: remote.serverName,
        baseUrl: Uri.parse('http://line-home.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(_SameServerAdapter([remote, sidecar, home])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(
        () => auth.connect(
          address: remote.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      sidecar.extendedDomains = [
        {'name': '家里', 'url': 'http://line-home.test:8096'},
      ];
      final id = auth.session!.server.id;
      await pumpServerSelection(tester, auth);
      await serverUiTap(tester, Key('server-lines-$id'));
      expect(find.byKey(const Key('server-lines-discover')), findsOneWidget);
      expect(find.byKey(const Key('server-lines-speed')), findsOneWidget);
      await serverUiTap(tester, const Key('server-lines-discover'));
      expect(find.text('家里'), findsWidgets);
      expect(find.text('已加入 1 条线路'), findsOneWidget);
      expect(
        auth.savedServers.single.lines.map((line) => line.nickname),
        contains('家里'),
      );
      await serverUiTap(tester, const Key('server-lines-speed'));
      final current = auth.savedServers.single.lines.firstWhere(
        (line) => line.nickname != '家里',
      );
      expect(current.latencyMs, isNotNull);
      expect(find.textContaining('ms'), findsWidgets);
    },
    tags: ['integration'],
  );

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
        // The frame alone titles the step; the fields card has no heading.
        expect(find.text('添加线路'), findsOneWidget);
        expect(find.text('保存服务器后生效'), findsOneWidget);
        final cancel = find.byKey(const Key('server-line-cancel'));
        final done = find.byKey(const Key('server-line-done'));
        expect(
          tester.widget<ui.AppActionButton>(cancel).tier,
          ui.AppActionTier.tertiary,
        );
        expect(
          tester.widget<ui.AppActionButton>(done).tier,
          ui.AppActionTier.primary,
        );
        final field = tester.getRect(
          find.byKey(const Key('server-line-address')),
        );
        final cancelRect = tester.getRect(cancel);
        final doneRect = tester.getRect(done);
        expect(cancelRect.top, closeTo(doneRect.top, 1));
        expect(cancelRect.right, lessThanOrEqualTo(doneRect.left));
        if (phone) {
          // Phone: the two actions share the whole row equally.
          expect(cancelRect.width, closeTo(doneRect.width, 1));
          expect(
            cancelRect.width + doneRect.width,
            greaterThan(field.width * .9),
          );
        } else {
          // Desktop: trailing, content-wide, never stretched across the panel.
          expect(doneRect.right, closeTo(field.right, 24));
          expect(cancelRect.width + doneRect.width, lessThan(field.width * .6));
        }

        // Cancel leaves the draft untouched and returns to the editor.
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          wan.baseUrl.toString(),
        );
        await serverUiTap(tester, const Key('server-line-cancel'));
        expect(find.byKey(const Key('server-line-address')), findsNothing);
        expect(find.byKey(const Key('server-editor-add-line')), findsOneWidget);
        expect(find.text('draft-wan.test:8096'), findsNothing);
        expect(auth.savedServers.single.lines, hasLength(1));

        // Invalid and duplicate addresses are reported under the address
        // field, and the form stays open.
        await serverUiTap(tester, const Key('server-editor-add-line'));
        Finder addressError(String text) => find.descendant(
          of: find.byKey(const Key('server-line-address')),
          matching: find.text(text),
        );
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          'ftp://draft-invalid.test',
        );
        await serverUiTap(tester, const Key('server-line-done'));
        expect(addressError('请输入有效的服务器地址'), findsOneWidget);
        expect(find.byKey(const Key('server-line-done')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          lan.baseUrl.toString(),
        );
        await tester.pump();
        expect(addressError('请输入有效的服务器地址'), findsNothing);
        await serverUiTap(tester, const Key('server-line-done'));
        expect(addressError('这个地址已在线路列表中'), findsOneWidget);
        expect(find.byKey(const Key('server-line-done')), findsOneWidget);
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
      // Cancel and done keep their own width at the trailing edge.
      final addressRect = tester.getRect(
        find.byKey(const Key('server-line-address')),
      );
      final cancelRect = tester.getRect(
        find.byKey(const Key('server-line-cancel')),
      );
      final doneRect = tester.getRect(
        find.byKey(const Key('server-line-done')),
      );
      expect(
        cancelRect.width + doneRect.width,
        lessThan(addressRect.width / 2),
      );
      expect(doneRect.right, closeTo(addressRect.right, 2));
      // A duplicate address is reported under the address and keeps the form.
      await tvEdit(
        tester,
        const Key('server-line-address'),
        wan.baseUrl.toString(),
      );
      await tvPress(tester, const Key('server-line-done'));
      final error = find.byKey(const Key('server-line-address-error'));
      expect(tester.widget<Text>(error).data, '这个地址已在线路列表中');
      expect(
        tester.getTopLeft(error).dy,
        greaterThan(
          tester.getBottomLeft(find.byKey(const Key('server-line-address'))).dy,
        ),
      );
      expect(find.byKey(const Key('server-line-done')), findsOneWidget);
      await tvEdit(
        tester,
        const Key('server-line-address'),
        wan3.baseUrl.toString(),
      );
      expect(error, findsNothing);
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

  testWidgets('narrow phone keeps the whole line label readable', (
    tester,
  ) async {
    // 线路摘要曾被 22 字符预算从中间截断成 "capture-mirror.t…:8096"。
    // 现在不截断:主机:端口单行放不下时先去掉端口,再折成两行;
    // 完整安全地址由 tooltip 提供。
    final remote = FakeEmbyServer();
    final relay = FakeEmbyServer(
      serverId: remote.serverId,
      baseUrl: Uri.parse('http://capture-relay-tunnel-node.example.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(_SameServerAdapter([remote, relay])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: remote.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    // 再加一条长地址线路,并选为当前,复现手机列表里的长文案。
    await tester.runAsync(
      () => auth.addLine(
        auth.savedServers.single.id,
        'http://capture-relay-tunnel-node.example.test:8096',
      ),
    );
    final relayLine = auth.savedServers.single.lines.last;
    await tester.runAsync(
      () => auth.selectLine(
        auth.savedServers.single.id,
        LineSelection.fixed(relayLine.id),
      ),
    );
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpServerSelection(tester, auth, phone: true, dark: true);
    final id = auth.savedServers.single.id;
    final chip = find.byKey(Key('server-lines-$id'));
    final label = find.descendant(
      of: find.descendant(of: chip, matching: find.byType(Flexible)),
      matching: find.byType(Text),
    );
    expect(label, findsOneWidget);
    final labelWidget = tester.widget<Text>(label);
    // 不在中间插省略号:要么是完整的主机:端口,要么是去掉端口的完整主机名。
    expect(labelWidget.data, isNot(contains('…')));
    expect(
      labelWidget.data,
      anyOf(
        'capture-relay-tunnel-node.example.test:8096',
        'capture-relay-tunnel-node.example.test',
      ),
    );
    // 360 宽放不下整串地址:去掉端口后折行,不出现单行截断。
    expect(labelWidget.data, 'capture-relay-tunnel-node.example.test');
    expect(labelWidget.maxLines, 2);
    // 完整的安全地址同时是悬停 tooltip 和语义 tooltip。
    const full = 'http://capture-relay-tunnel-node.example.test:8096';
    expect(
      find.descendant(
        of: chip,
        matching: find.byWidgetPredicate(
          (w) => w is ui.AppTooltip && w.message == full,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chip,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.tooltip == full,
        ),
      ),
      findsOneWidget,
    );
    // 芯片横向撑满内容列,拿到的是整行的可变宽度。
    final chipWidth = tester.getSize(chip).width;
    final cardWidth = tester.getSize(find.byKey(Key('server-enter-$id'))).width;
    expect(
      chipWidth,
      greaterThan(cardWidth - 100),
      reason: '芯片($chipWidth)没有撑满卡片($cardWidth)的内容列',
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  for (final (width, expected) in [
    (1200.0, 'capture-mirror.test:8096'),
    // 测试字体每个字符等宽于字号,412 宽放不下主机:端口,先去掉端口。
    (412.0, 'capture-mirror.test'),
  ]) {
    testWidgets('an unnamed line shows its full host at ${width.toInt()}', (
      tester,
    ) async {
      // 无昵称线路显示完整主机名(含非默认端口),不再按字符预算截断。
      final remote = FakeEmbyServer(
        baseUrl: Uri.parse('http://capture-mirror.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(_SameServerAdapter([remote])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(
        () => auth.connect(
          address: remote.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpServerSelection(tester, auth, phone: width < 600);
      final id = auth.savedServers.single.id;
      final chip = find.byKey(Key('server-lines-$id'));
      expect(
        find.descendant(of: chip, matching: find.text(expected)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: chip, matching: find.textContaining('…')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);
  }

  test('line host labels keep the whole host and drop only default ports', () {
    ServerLine line(String address, [String? nickname]) =>
        ServerLine(id: 'l', address: address, nickname: nickname);
    expect(
      serverLineHostLabel(line('http://capture-mirror.test:8096')),
      'capture-mirror.test:8096',
    );
    expect(
      serverLineHostLabel(
        line('http://capture-mirror.test:8096'),
        withPort: false,
      ),
      'capture-mirror.test',
    );
    expect(
      serverLineHostLabel(
        line('https://a.very-long-relay-subdomain.media.example.test'),
      ),
      'a.very-long-relay-subdomain.media.example.test',
    );
    expect(serverLineHostLabel(line('https://emby.test:443')), 'emby.test');
    expect(serverLineHostLabel(line('http://emby.test:80')), 'emby.test');
    expect(serverLineHostLabel(line('http://[::1]:8096')), '[::1]:8096');
    expect(serverLineLabel(line('http://x.test:8096', '家里')), '家里');
    expect(
      serverLineLabel(line('http://x.test:8096', '家里'), withPort: false),
      '家里',
    );
  });

  testWidgets('a named line keeps its nickname next to the mode', (
    tester,
  ) async {
    // 收窄主机名不能误伤用户自己起的昵称。
    final remote = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(_SameServerAdapter([remote])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: remote.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final serverId = auth.savedServers.single.id;
    await tester.runAsync(
      () => auth.saveConfiguration(
        serverId,
        nickname: auth.sources.server(serverId).displayName,
        userAgent: auth.sources.server(serverId).userAgent ?? '',
        lines: [
          auth.savedServers.single.lines.first.copyWith(nickname: '家庭直连'),
        ],
      ),
    );
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpServerSelection(tester, auth, phone: true, dark: true);
    expect(find.text('自动选择 · 家庭直连'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  // ---------- editor line rows: current/auto marker and latency ----------

  /// 同一台服务器的两条线路;当前线路带测速延迟,备用线路没有测速数据。
  Future<(AuthController, String, String, String)> editorLines(
    WidgetTester tester, {
    required bool automatic,
  }) async {
    final lan = FakeEmbyServer(
      baseUrl: Uri.parse('http://editor-lan.test:8096'),
    );
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://editor-wan.test:8096'),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(_SameServerAdapter([lan, wan])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(() async {
      for (final remote in [lan, wan]) {
        await auth.connect(
          address: remote.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      }
    });
    final saved = auth.savedServers.single;
    final activeId = saved.activeLineId!;
    final standbyId = saved.lines.firstWhere((l) => l.id != activeId).id;
    await tester.runAsync(
      () => auth.saveConfiguration(
        saved.id,
        nickname: saved.displayName,
        userAgent: saved.userAgent ?? '',
        lines: [
          for (final line in saved.lines)
            line.id == activeId ? line.copyWith(latencyMs: 42) : line,
        ],
        lineSelection: automatic
            ? const LineSelection.auto()
            : LineSelection.fixed(activeId),
      ),
    );
    expect(auth.savedServers.single.activeLineId, activeId);
    expect(auth.savedServers.single.lineSelection.isAutomatic, automatic);
    return (auth, saved.id, activeId, standbyId);
  }

  // 窄屏手机上「自动选择 · 42 ms」放不进地址同一行时,地址与标记分两行,
  // 地址不能被挤成零宽,也不能溢出。
  for (final (phone, automatic, scale) in [
    (false, true, 1.0),
    (true, false, 1.0),
    (true, true, 1.0),
    (true, true, 1.3),
    (true, true, 2.0),
  ]) {
    testWidgets(
      'server editor line rows show current marker and latency on ${phone ? "phone 360" : "desktop"} (${automatic ? "auto" : "fixed"}, text x$scale)',
      (tester) async {
        tester.view.physicalSize = Size(phone ? 360 : 1200, phone ? 800 : 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final (auth, id, activeId, standbyId) = await editorLines(
          tester,
          automatic: automatic,
        );
        final activeAddress = serverSafeAddress(
          auth.savedServers.single.lines
              .firstWhere((line) => line.id == activeId)
              .address,
        );
        await pumpServerSelection(tester, auth, phone: phone, scale: scale);
        await openServerEditor(tester, id);
        expect(tester.takeException(), isNull);
        final activeRow = find.byKey(Key('server-editor-line-$activeId'));
        await tester.ensureVisible(activeRow);
        await settle(tester);
        Finder inRow(String lineId, Finder matching) => find.descendant(
          of: find.byKey(Key('server-editor-line-$lineId')),
          matching: matching,
        );
        expect(inRow(activeId, find.text('当前')), findsOneWidget);
        final status = automatic ? '自动选择 · 42 ms' : '42 ms';
        final address = inRow(activeId, find.text(activeAddress));
        expect(address, findsOneWidget);
        // 地址不能被状态标记挤成零宽。
        expect(tester.getSize(address).width, greaterThan(60));
        final sameLine = inRow(activeId, find.text(' · $status'));
        final ownLine = inRow(activeId, find.text(status));
        if (phone || !tester.any(sameLine)) {
          // 放不下时(测试字体下 360dp 手机必然如此)地址独占一行,
          // 标记另起一行。
          expect(sameLine, findsNothing);
          expect(ownLine, findsOneWidget);
          expect(
            tester.getTopLeft(ownLine).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(address).dy),
          );
        } else {
          // 放得下时地址与标记同行。
          expect(ownLine, findsNothing);
          expect(
            tester.getCenter(sameLine).dy,
            closeTo(tester.getCenter(address).dy, 1),
          );
        }
        expect(inRow(standbyId, find.text('当前')), findsNothing);
        expect(inRow(standbyId, find.textContaining('自动选择')), findsNothing);
        expect(inRow(standbyId, find.textContaining('ms')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  testWidgets(
    'TV server header counts servers and editor lines show current and latency',
    (tester) async {
      isolateImageCache();
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (auth, id, activeId, standbyId) = await editorLines(
        tester,
        automatic: true,
      );
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
      final header = find.byKey(const Key('tv-frame-header'));
      expect(
        find.descendant(of: header, matching: find.text('服务器')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('1 台服务器')),
        findsOneWidget,
      );
      await tvOpenEditor(tester, id);
      expect(
        tester
            .widget<Text>(
              find.byKey(Key('server-editor-line-status-$activeId')),
            )
            .data,
        '当前 · 自动选择 · 42 ms',
      );
      expect(
        find.byKey(Key('server-editor-line-status-$standbyId')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'discover on another Emby does not enter it or ask to open it first',
    (tester) async {
      final current = FakeEmbyServer(
        serverId: 'discover-current',
        baseUrl: Uri.parse('http://discover-current.test:8096'),
      );
      final other = FakeEmbyServer(
        serverId: 'discover-other',
        serverName: '其他服务器',
        baseUrl: Uri.parse('http://discover-other.test:8096'),
      );
      final sidecar = FakeEmbyServer(
        serverId: other.serverId,
        serverName: other.serverName,
        baseUrl: other.baseUrl.replace(port: 52143),
      );
      final home = FakeEmbyServer(
        serverId: other.serverId,
        serverName: other.serverName,
        baseUrl: Uri.parse('http://discover-home.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(
            _SameServerAdapter([current, other, sidecar, home]),
          ),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(() async {
        await auth.connect(
          address: other.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await auth.connect(
          address: current.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      final currentId = auth.session!.server.id;
      final token = auth.session!.accessToken;
      final otherId = auth.savedServers
          .firstWhere(
            (server) => server.lines.any(
              (line) => line.address == other.baseUrl.toString(),
            ),
          )
          .id;
      await pumpServerSelection(tester, auth);
      await serverUiTap(tester, Key('server-lines-$otherId'));
      ServerLineSelectorState page() => tester.state<ServerLineSelectorState>(
        find.byType(ServerLineSelector),
      );

      await serverUiTap(tester, const Key('server-lines-discover'));
      expect(find.text('没有发现新线路'), findsOneWidget);
      expect(find.text('请先进入这台 Emby 服务器，再刷新发现线路'), findsNothing);
      expect(auth.session!.server.id, currentId);
      expect(auth.client.baseUrl, current.baseUrl);
      expect(page().error, isNull);

      sidecar.extendedDomains = [
        {'name': '家里', 'url': home.baseUrl.toString()},
      ];
      await serverUiTap(tester, const Key('server-lines-discover'));
      expect(find.text('已加入 1 条线路'), findsOneWidget);
      expect(find.text('家里'), findsWidgets);
      expect(find.text('请先进入这台 Emby 服务器，再刷新发现线路'), findsNothing);
      expect(auth.session!.server.id, currentId);
      expect(auth.session!.accessToken, token);
      expect(auth.client.baseUrl, current.baseUrl);

      other.expireAuthenticatedRequests = true;
      sidecar.expireAuthenticatedRequests = true;
      await serverUiTap(tester, const Key('server-lines-discover'));
      expect(find.text('请重新登录'), findsOneWidget);
      expect(find.text('请先进入这台 Emby 服务器，再刷新发现线路'), findsNothing);
      expect(page().error, isNull);
      expect(auth.session!.server.id, currentId);
      expect(auth.client.baseUrl, current.baseUrl);

      other.expireAuthenticatedRequests = false;
      sidecar.expireAuthenticatedRequests = false;
      await auth.credentials.delete(otherId);
      await serverUiTap(tester, const Key('server-lines-discover'));
      expect(find.text('请重新登录'), findsOneWidget);
      expect(find.text('没有发现新线路'), findsNothing);
      expect(find.text('请先进入这台 Emby 服务器，再刷新发现线路'), findsNothing);
      expect(auth.session!.server.id, currentId);
      expect(auth.session!.accessToken, token);
      expect(auth.client.baseUrl, current.baseUrl);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'speed test keeps a row failure off the page and keeps the other rows',
    (tester) async {
      final live = FakeEmbyServer(
        serverId: 'row-server',
        baseUrl: Uri.parse('http://row-live.test:8096'),
      );
      final offline = FakeEmbyServer(
        serverId: live.serverId,
        serverName: live.serverName,
        baseUrl: Uri.parse('http://row-offline.test:8096'),
      );
      final foreign = FakeEmbyServer(
        serverId: live.serverId,
        serverName: live.serverName,
        baseUrl: Uri.parse('http://row-foreign.test:8096'),
      );
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(_SameServerAdapter([live, offline, foreign])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(() async {
        await auth.connect(
          address: live.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        final id = auth.session!.server.id;
        await auth.addLine(id, offline.baseUrl.toString());
        await auth.addLine(id, foreign.baseUrl.toString());
      });
      final base = auth.client.baseUrl;
      final token = auth.session!.accessToken;
      offline.publicInfoStatus = 503;
      foreign.serverId = 'row-other-server';
      await pumpServerSelection(tester, auth);
      await serverUiTap(
        tester,
        Key('server-lines-${auth.savedServers.single.id}'),
      );
      await serverUiTap(tester, const Key('server-lines-speed'));
      expect(find.textContaining('连接正常'), findsWidgets);
      expect(find.textContaining('连接失败，可重试或换线'), findsWidgets);
      expect(find.textContaining('这个地址属于另一台服务器'), findsWidgets);
      expect(find.text('未保存，请检查输入或连接后重试。'), findsNothing);
      expect(
        tester.state<ServerLineSelectorState>(find.byType(ServerLineSelector)).error,
        isNull,
      );
      final lines = auth.savedServers.single.lines;
      expect(
        lines
            .firstWhere((line) => line.address == live.baseUrl.toString())
            .latencyMs,
        isNotNull,
      );
      expect(
        lines
            .firstWhere((line) => line.address == offline.baseUrl.toString())
            .checkFailureKind,
        isNotNull,
      );
      expect(
        lines
            .firstWhere((line) => line.address == foreign.baseUrl.toString())
            .checkStatus,
        'identityMismatch',
      );
      expect(auth.client.baseUrl, base);
      expect(auth.session!.accessToken, token);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'speed test shows a finished line before a slower line completes',
    (tester) async {
      final fast = FakeEmbyServer(
        serverId: 'pace-server',
        baseUrl: Uri.parse('http://speed-fast.test:8096'),
      );
      final slow = FakeEmbyServer(
        serverId: fast.serverId,
        serverName: fast.serverName,
        baseUrl: Uri.parse('http://speed-slow.test:8096'),
      );
      final gate = _PublicInfoGate([fast, slow]);
      final auth = AuthController.memory(
        client: EmbyClient(device: _device, dio: dioForFakeEmby(gate)),
      );
      addTearDown(auth.dispose);
      addTearDown(() {
        if (!gate.gate.isCompleted) gate.gate.complete();
      });
      await tester.runAsync(() async {
        await auth.connect(
          address: fast.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await auth.addLine(auth.session!.server.id, slow.baseUrl.toString());
      });
      final base = auth.client.baseUrl;
      await pumpServerSelection(tester, auth);
      await serverUiTap(
        tester,
        Key('server-lines-${auth.savedServers.single.id}'),
      );
      gate.holdHost = slow.baseUrl.host;
      await tester.ensureVisible(find.byKey(const Key('server-lines-speed')));
      await tester.tap(find.byKey(const Key('server-lines-speed')));
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (gate.started.contains(fast.baseUrl.host) &&
            gate.started.contains(slow.baseUrl.host)) {
          break;
        }
      }
      expect(gate.started, containsAll([fast.baseUrl.host, slow.baseUrl.host]));
      for (var frame = 0; frame < 20; frame++) {
        final fastLine = auth.sources
            .server(auth.savedServers.single.id)
            .lines
            .firstWhere((line) => line.address == fast.baseUrl.toString());
        if (fastLine.latencyMs != null) break;
        await tester.pump(const Duration(milliseconds: 20));
      }
      final lines = auth.sources
          .server(auth.savedServers.single.id)
          .lines;
      expect(
        lines
            .firstWhere((line) => line.address == fast.baseUrl.toString())
            .latencyMs,
        isNotNull,
      );
      expect(
        lines
            .firstWhere((line) => line.address == slow.baseUrl.toString())
            .latencyMs,
        isNull,
      );
      await tester.pump();
      expect(find.textContaining('正在检查'), findsWidgets);
      expect(find.textContaining('ms'), findsWidgets);
      expect(
        tester.state<ServerLineSelectorState>(find.byType(ServerLineSelector)).error,
        isNull,
      );
      expect(auth.client.baseUrl, base);
      gate.gate.complete();
      await tester.pump();
      await settle(tester);
      expect(
        auth.savedServers.single.lines
            .firstWhere((line) => line.address == slow.baseUrl.toString())
            .latencyMs,
        isNotNull,
      );
      expect(auth.client.baseUrl, base);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('leaving the line page stops an in-flight check', (tester) async {
    final remote = FakeEmbyServer(
      baseUrl: Uri.parse('http://speed-leave.test:8096'),
    );
    final gate = _PublicInfoGate([remote]);
    final auth = AuthController.memory(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(gate)),
    );
    addTearDown(auth.dispose);
    addTearDown(() {
      if (!gate.gate.isCompleted) gate.gate.complete();
    });
    await tester.runAsync(
      () => auth.connect(
        address: remote.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final id = auth.session!.server.id;
    final lineId = auth.session!.server.activeLineId!;
    final token = auth.session!.accessToken;
    await pumpServerSelection(tester, auth);
    await serverUiTap(tester, Key('server-lines-$id'));
    gate.holdHost = remote.baseUrl.host;
    await tester.ensureVisible(find.byKey(Key('server-line-check-$lineId')));
    await tester.tap(find.byKey(Key('server-line-check-$lineId')));
    await tester.pump();
    for (
      var frame = 0;
      frame < 20 && !gate.started.contains(remote.baseUrl.host);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(gate.started, contains(remote.baseUrl.host));
    await tester.tap(find.byKey(const Key('server-flow-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    gate.gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final line = auth.savedServers.single.lines.single;
    expect(line.latencyMs, isNull);
    expect(line.checkedAt, isNull);
    expect(auth.session!.server.id, id);
    expect(auth.session!.accessToken, token);
    expect(auth.client.baseUrl, remote.baseUrl);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  test(
    'domain probes run together and keep addresses that answer',
    () async {
      final remote = FakeEmbyServer(
        baseUrl: Uri.parse('http://domains.test:8096'),
      );
      final sidecar = FakeEmbyServer(
        serverId: remote.serverId,
        baseUrl: remote.baseUrl.replace(port: 52143),
      );
      sidecar.extendedDomains = [
        {'name': '外网', 'url': 'http://line-wan.test:8096'},
      ];
      sidecar.issuedTokens.add('token-domains');
      final gate = _DomainProbeGate([remote, sidecar]);
      addTearDown(() {
        if (!gate.gate.isCompleted) gate.gate.complete();
      });
      final client = EmbyClient(
        device: _device,
        dio: dioForFakeEmby(gate),
      );
      client.attachSession(
        baseUrl: remote.baseUrl,
        accessToken: 'token-domains',
        userId: 'user-alice',
      );
      final pending = client.loadExtendedServerDomains();
      try {
        await gate.both.future;
        expect(gate.domainStarts, greaterThanOrEqualTo(2));
        gate.failHeld = true;
        gate.gate.complete();
        final domains = await pending;
        expect(
          domains.map((domain) => domain.url.toString()),
          ['http://line-wan.test:8096'],
        );
        expect(domains.single.name, '外网');
      } finally {
        if (!gate.gate.isCompleted) gate.gate.complete();
        await pending;
      }
    },
  );

  test('non-Emby discovery does not probe, but saved lines can be checked', () async {
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    host.listen((request) async {
      paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/System/Info/Public')) {
        request.response.write(
          jsonEncode({
            'Id': 'jelly-1',
            'ServerName': 'Jellyfin',
            'Version': '10.9.0',
          }),
        );
      } else if (request.uri.path.endsWith('/Users/Me')) {
        request.response.write(
          jsonEncode({'Id': 'user-jelly', 'Name': 'alice'}),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    addTearDown(() => host.close(force: true));
    final backing = MemoryServerListStore();
    final credentials = MemoryCredentialStore();
    final auth = AuthController(
      client: EmbyClient(device: _device),
      credentials: credentials,
      servers: backing,
    );
    addTearDown(auth.dispose);
    const id = 'jelly-1';
    await backing.save(
      ServerListSnapshot(
        servers: [
          SavedServer(
            id: id,
            name: 'Jellyfin',
            username: 'alice',
            serviceType: MediaServerType.jellyfin,
            activeLineId: 'line-jelly',
            lines: [
              ServerLine(
                id: 'line-jelly',
                address: 'http://127.0.0.1:${host.port}',
              ),
            ],
          ),
        ],
        lastServerId: id,
      ),
    );
    await credentials.write(
      id,
      const StoredCredentials(
        serviceType: MediaServerType.jellyfin,
        accessToken: 'jelly-token',
        userId: 'user-jelly',
        username: 'alice',
      ),
    );
    await auth.sources.load();
    await auth.reloadSavedServers();
    expect(await auth.discoverExtendedLines(id, force: true), 0);
    expect(paths, isEmpty);
    expect(auth.session, isNull);
    final checked = await auth.sources.check(id, lineId: 'line-jelly');
    expect(checked.status.name, 'available');
    expect(checked.latencyMs, isNotNull);
    expect(paths, containsAll(['/System/Info/Public', '/Users/Me']));
    expect(
      paths.where((path) => path.contains('ServerDomains')),
      isEmpty,
    );
    expect(auth.session, isNull);
  });

  test('a cancelled check is not saved and leaves the session client', () async {
    final remote = FakeEmbyServer(
      baseUrl: Uri.parse('http://cancel-line.test:8096'),
    );
    final gate = _PublicInfoGate([remote]);
    addTearDown(() {
      if (!gate.gate.isCompleted) gate.gate.complete();
    });
    final auth = AuthController.memory(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(gate)),
    );
    addTearDown(auth.dispose);
    await auth.connect(
      address: remote.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final id = auth.session!.server.id;
    final lineId = auth.session!.server.activeLineId!;
    final token = auth.session!.accessToken;
    final sessionClient = auth.client;
    gate.holdHost = remote.baseUrl.host;
    final pending = auth.sources.check(id, lineId: lineId);
    await gate.startedAll.future;
    auth.sources.cancelChecks(id);
    gate.gate.complete();
    await expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Check superseded',
        ),
      ),
    );
    final line = auth.savedServers.single.lines.single;
    expect(line.latencyMs, isNull);
    expect(line.checkedAt, isNull);
    expect(auth.client, same(sessionClient));
    expect(auth.client.baseUrl, remote.baseUrl);
    expect(auth.session!.accessToken, token);
    expect(auth.client.hasSession, isTrue);
  });
}

class _PublicInfoGate extends _SameServerAdapter {
  _PublicInfoGate(super.endpoints);
  String? holdHost;
  final gate = Completer<void>();
  final started = <String>[];
  final startedAll = Completer<void>();
  var waitingFor = 1;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    final isPublic = options.uri.path.endsWith('/System/Info/Public');
    if (holdHost != null && isPublic) {
      started.add(options.uri.host);
      if (started.toSet().length >= waitingFor && !startedAll.isCompleted) {
        startedAll.complete();
      }
    }
    if (holdHost != null && isPublic && options.uri.host == holdHost) {
      await gate.future;
    }
    return super.fetch(options, stream, cancelled);
  }
}

class _DomainProbeGate extends _SameServerAdapter {
  _DomainProbeGate(super.endpoints);
  final gate = Completer<void>();
  final both = Completer<void>();
  var domainStarts = 0;
  var failHeld = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    final domains = options.uri.path.endsWith('/System/Ext/ServerDomains');
    final held = domains && options.uri.port != 52143;
    if (domains) {
      domainStarts++;
      if (domainStarts >= 2 && !both.isCompleted) both.complete();
    }
    if (held) {
      await gate.future;
      if (failHeld) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
    }
    return super.fetch(options, stream, cancelled);
  }
}
