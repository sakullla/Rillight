import 'dart:async';

import '../helpers/image_cache_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-ui',
  version: '0.1.0',
);

Future<void> _enter(
  WidgetTester tester, {
  required String address,
  required String username,
  required String password,
}) async {
  await tester.enterText(find.byKey(ConnectFormKeys.address), address);
  await tester.enterText(find.byKey(ConnectFormKeys.username), username);
  await tester.enterText(find.byKey(ConnectFormKeys.password), password);
}

Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  } on FlutterError {
    // Logged-in home rows schedule retry timers that never go idle.
  }
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _expandMore(WidgetTester tester) async {
  expect(find.byKey(ConnectFormKeys.userAgent), findsNothing);
  expect(find.byKey(ConnectFormKeys.path), findsNothing);
  await _tapVisible(tester, find.byKey(ConnectFormKeys.more));
  expect(find.byKey(ConnectFormKeys.userAgent), findsOneWidget);
  expect(find.byKey(ConnectFormKeys.path), findsOneWidget);
}

void main() {
  setUp(isolateImageCache);
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  AuthController controller({
    CredentialStore? credentials,
    ServerListStore? servers,
    Duration timeout = const Duration(seconds: 5),
  }) {
    return AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(adapter, timeout: timeout),
      ),
      credentials: credentials ?? MemoryCredentialStore(),
      servers: servers ?? MemoryServerListStore(),
    );
  }

  for (final savedServer in [false, true]) {
    testWidgets(
      'HTML 403 preserves the complete draft through retry and route recreation (saved=$savedServer)',
      (tester) async {
        final auth = controller();
        if (savedServer) {
          await tester.runAsync(() async {
            await auth.connect(
              address: server.baseUrl.toString(),
              username: 'alice',
              password: 'correct-horse',
            );
            await auth.logout();
            await auth.selectSavedServer(server.serverId);
          });
        }
        var app = RillightApp(auth: auth);
        await tester.pumpWidget(app);
        await _settle(tester);
        await _enter(
          tester,
          address: 'http://emby.test:8096',
          username: 'alice',
          password: 'draft-password',
        );
        await _expandMore(tester);
        await tester.enterText(find.byKey(ConnectFormKeys.path), '/emby');
        await tester.enterText(
          find.byKey(ConnectFormKeys.userAgent),
          'DraftUA/1',
        );
        await _tapVisible(tester, find.byKey(ConnectFormKeys.addLine));
        await tester.enterText(
          find.byKey(ConnectFormKeys.extraLine(0)),
          'http://backup.test:8096',
        );
        final html =
            '<!DOCTYPE html><html><body>${'blocked ' * 500}</body></html>';
        if (savedServer) {
          server.authenticationStatus = 403;
          server.authenticationRawBody = html;
        } else {
          server.publicInfoStatus = 403;
          server.publicInfoRawBody = html;
        }
        await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
        expect(auth.isLoggedIn, isFalse);
        expect(auth.failure?.detail, 'HTTP 403');
        expect(find.textContaining('<html>'), findsNothing);
        expect(find.text('重试'), findsOneWidget);
        final errorView = find.byType(AppErrorView);
        expect(tester.getSize(errorView).height, lessThan(100));
        final draftState = tester.state(find.byType(ConnectPage));
        app.router.refresh();
        await _settle(tester);
        expect(tester.state(find.byType(ConnectPage)), same(draftState));

        // Replace the route tree while retaining this connection flow.
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        app = RillightApp(auth: auth);
        await tester.pumpWidget(app);
        await _settle(tester);
        final expected = <Key, String>{
          ConnectFormKeys.address: 'http://emby.test:8096',
          ConnectFormKeys.username: 'alice',
          ConnectFormKeys.password: 'draft-password',
          ConnectFormKeys.path: '/emby',
          ConnectFormKeys.userAgent: 'DraftUA/1',
          ConnectFormKeys.extraLine(0): 'http://backup.test:8096',
        };
        for (final entry in expected.entries) {
          expect(
            tester.widget<TextField>(find.byKey(entry.key)).controller!.text,
            entry.value,
          );
        }
        await tester.enterText(
          find.byKey(ConnectFormKeys.password),
          'correct-horse',
        );
        await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
        expect(auth.isLoggedIn, isFalse);
        expect(await auth.credentials.read(server.serverId), isNull);
        server.publicInfoStatus = null;
        server.authenticationStatus = null;
        await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
        expect(auth.isLoggedIn, isTrue);
        expect(auth.savedServers.single.baseUrl, 'http://emby.test:8096/emby');
        expect(
          auth.savedServers.single.lines.map((line) => line.address),
          contains('http://backup.test:8096'),
        );
        expect(server.lastUserAgent, 'DraftUA/1');
        expect(auth.connectDraft, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        auth.dispose();
      },
      tags: ['integration'],
    );
  }

  for (final edit in ['replace', 'clear', 'new server']) {
    testWidgets('late saved password cannot replace a changed draft ($edit)', (
      tester,
    ) async {
      final credentials = _DelayedCredentials();
      final saved = SavedServer(
        id: server.serverId,
        name: 'saved',
        username: 'alice',
        lines: [ServerLine(id: 'line', address: server.baseUrl.toString())],
        activeLineId: 'line',
      );
      final auth = controller(
        credentials: credentials,
        servers: MemoryServerListStore(ServerListSnapshot(servers: [saved])),
      );
      await auth.restore();
      await auth.selectSavedServer(saved.id);
      final app = RillightApp(auth: auth);
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.enterText(
        find.byKey(ConnectFormKeys.password),
        'new-password',
      );
      if (edit == 'clear') {
        await tester.enterText(find.byKey(ConnectFormKeys.password), '');
      } else if (edit == 'new server') {
        await _tapVisible(tester, find.byKey(ConnectFormKeys.addServer));
      }
      credentials.pending.complete(
        const StoredCredentials(
          accessToken: '',
          userId: '',
          username: 'alice',
          password: 'old-password',
        ),
      );
      await _settle(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(ConnectFormKeys.password))
            .controller!
            .text,
        edit == 'replace' ? 'new-password' : '',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
    }, tags: ['integration']);
  }

  testWidgets('leaving add-server flow releases its password draft', (
    tester,
  ) async {
    final auth = controller();
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final app = RillightApp(auth: auth);
    app.router.go('/connect?add=1');
    await tester.pumpWidget(app);
    await _settle(tester);
    await tester.enterText(
      find.byKey(ConnectFormKeys.password),
      'temporary-password',
    );
    expect(auth.connectDraft?.password, 'temporary-password');
    app.router.go('/');
    await _settle(tester);
    expect(auth.connectDraft, isNull);
    app.router.go('/connect?add=1');
    await _settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(ConnectFormKeys.password))
          .controller!
          .text,
      '',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    app.router.dispose();
    auth.dispose();
  }, tags: ['integration']);

  testWidgets(
    'wrong password, successful login, logout, and saved server fill',
    (tester) async {
      final auth = controller();
      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);

      expect(find.text(kProductName), findsWidgets);
      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.byKey(ConnectFormKeys.userAgent), findsNothing);
      expect(find.byKey(ConnectFormKeys.path), findsNothing);
      expect(find.text('User-Agent'), findsNothing);

      await _enter(
        tester,
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'wrong',
      );
      await tester.tap(find.byKey(ConnectFormKeys.submit));
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('HTTP 401: invalid credentials'), findsOneWidget);
      expect(auth.isLoggedIn, isFalse);

      await tester.enterText(
        find.byKey(ConnectFormKeys.password),
        'correct-horse',
      );
      await tester.tap(find.byKey(ConnectFormKeys.submit));
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsNothing);
      expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
      expect(auth.isLoggedIn, isTrue);

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await _settle(tester);
      await tester.tap(find.text('退出登录'));
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.text('灯川测试'), findsOneWidget);

      await tester.enterText(find.byKey(ConnectFormKeys.address), '');
      await _tapVisible(
        tester,
        find.byKey(Key('saved-server-${server.serverId}')),
      );
      await _settle(tester);

      expect(
        tester
            .widget<TextField>(find.byKey(ConnectFormKeys.address))
            .controller
            ?.text,
        server.baseUrl.toString(),
      );
      expect(auth.isLoggedIn, isFalse);
    },
    tags: ['integration'],
  );

  testWidgets('two lines can be selected and a failed line stays on connect', (
    tester,
  ) async {
    final wan = FakeEmbyServer(
      serverId: server.serverId,
      serverName: server.serverName,
      baseUrl: Uri.parse('http://emby-wan.test:8096'),
    );
    adapter.add(wan);
    final auth = controller();
    await tester.runAsync(() async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.logout();
      await auth.selectSavedServer(server.serverId);
    });
    expect(auth.savedServers.single.lines, hasLength(2));

    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    final lanLine = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == server.baseUrl.toString(),
    );
    final wanLine = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == wan.baseUrl.toString(),
    );
    expect(find.byKey(Key('saved-line-${lanLine.id}')), findsOneWidget);
    expect(find.byKey(Key('saved-line-${wanLine.id}')), findsOneWidget);
    await _tapVisible(tester, find.byKey(Key('saved-line-${wanLine.id}')));
    expect(
      tester
          .widget<TextField>(find.byKey(ConnectFormKeys.address))
          .controller
          ?.text,
      wan.baseUrl.toString(),
    );

    await _tapVisible(tester, find.byKey(Key('saved-line-${lanLine.id}')));
    final lanTile = find.byKey(Key('saved-line-${lanLine.id}'));
    final tileFill = tester.widget<Material>(
      find.ancestor(of: lanTile, matching: find.byType(Material)).first,
    );
    expect(tileFill.color?.a, closeTo(0.35, 0.01));
    expect(
      tester
          .widget<TextField>(find.byKey(ConnectFormKeys.address))
          .controller
          ?.text,
      server.baseUrl.toString(),
    );

    server.publicInfoStatus = 403;
    server.publicInfoRawBody = '该线路已被禁用';
    await tester.enterText(
      find.byKey(ConnectFormKeys.password),
      'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('HTTP 403: 该线路已被禁用'), findsOneWidget);
    expect(find.text('连接失败'), findsNothing);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.client.baseUrl, isNull);
  }, tags: ['integration']);

  testWidgets('path and User-Agent under 更多 are composed into the saved line', (
    tester,
  ) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: 'http://emby.test:8096',
      username: 'alice',
      password: 'correct-horse',
    );
    await _expandMore(tester);
    await tester.enterText(
      find.byKey(ConnectFormKeys.userAgent),
      'CustomUA/1.0',
    );
    await tester.enterText(find.byKey(ConnectFormKeys.path), '/emby');
    await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));

    expect(auth.isLoggedIn, isTrue);
    expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
    expect(find.text('CustomUA/1.0'), findsNothing);
    expect(server.lastUserAgent, 'CustomUA/1.0');
    expect(auth.client.sessionHeaders['User-Agent'], 'CustomUA/1.0');
    expect(auth.savedServers.single.baseUrl, 'http://emby.test:8096/emby');
  }, tags: ['integration']);
}

class _DelayedCredentials extends MemoryCredentialStore {
  final pending = Completer<StoredCredentials?>();

  @override
  Future<StoredCredentials?> read(String serverId) => pending.future;
}
