import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/settings/settings_action.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/window_chrome.dart';
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

  testWidgets('successful login leaves the connect page', (tester) async {
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
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byKey(ConnectFormKeys.submit), findsNothing);
    expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
    expect(auth.isLoggedIn, isTrue);
  });

  testWidgets('password field can reveal the typed value', (tester) async {
    await tester.pumpWidget(RillightApp(auth: controller()));
    await _settle(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(ConnectFormKeys.password))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.byKey(ConnectFormKeys.passwordVisibility));
    await _settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(ConnectFormKeys.password))
          .obscureText,
      isFalse,
    );
  });

  testWidgets('session icon button matches the title bar icon constraints', (
    tester,
  ) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);
    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    final session = tester.widget<IconButton>(
      find.byKey(SessionActions.serverMenuKey),
    );
    expect(session.constraints, kTitleBarIconConstraints);
    expect(session.visualDensity, VisualDensity.compact);
    final settings = tester.widget<IconButton>(
      find.byKey(SettingsAction.actionKey),
    );
    expect(session.constraints, settings.constraints);
    expect(session.visualDensity, settings.visualDensity);
    expect(session.iconSize, settings.iconSize);
    expect(
      tester.getSize(find.byKey(SessionActions.serverMenuKey)),
      tester.getSize(find.byKey(SettingsAction.actionKey)),
    );
  });

  testWidgets('wrong password stays on connect and shows AppErrorView', (
    tester,
  ) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

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
  });

  testWidgets('certificate error stays on connect and shows AppErrorView', (
    tester,
  ) async {
    adapter.certificateError = true;
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(
      find.text('HandshakeException: CERTIFICATE_VERIFY_FAILED'),
      findsOneWidget,
    );
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('forbidden server body is shown unwrapped', (tester) async {
    server.publicInfoStatus = 403;
    server.publicInfoRawBody = '该客户端/设备已被服务端禁用';
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('HTTP 403: 该客户端/设备已被服务端禁用'), findsOneWidget);
    expect(find.text('连接失败'), findsNothing);
    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('unreachable address shows a visible reason', (tester) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: 'http://emby.invalid:8096',
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('Connection refused'), findsOneWidget);
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
  });

  testWidgets(
    'saved server fills the address and logout requires login again',
    (tester) async {
      final auth = controller();
      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);

      await _enter(
        tester,
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await tester.tap(find.byKey(ConnectFormKeys.submit));
      await _settle(tester);

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
  );

  testWidgets('401 returns to connect with session expired reason', (
    tester,
  ) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);
    expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);

    server.expireAuthenticatedRequests = true;
    await tester.runAsync(() async {
      await expectLater(
        auth.client.getJson('/System/Info'),
        throwsA(isA<Object>()),
      );
    });
    await _settle(tester);

    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('会话已失效，请重新登录'), findsOneWidget);
    expect(find.byType(SessionActions), findsNothing);
  });

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
  });

  testWidgets(
    'line User-Agent field is sent and does not replace product name',
    (tester) async {
      final auth = controller();
      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);

      await _enter(
        tester,
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await _expandMore(tester);
      await tester.enterText(
        find.byKey(ConnectFormKeys.userAgent),
        'CustomUA/1.0',
      );
      await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));

      expect(auth.isLoggedIn, isTrue);
      expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
      expect(find.text('CustomUA/1.0'), findsNothing);
      expect(server.lastUserAgent, 'CustomUA/1.0');
      expect(auth.client.sessionHeaders['User-Agent'], 'CustomUA/1.0');
    },
  );

  testWidgets('path under 更多 is composed into the saved line address', (
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
    await tester.enterText(find.byKey(ConnectFormKeys.path), '/emby');
    await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));

    expect(auth.isLoggedIn, isTrue);
    expect(auth.savedServers.single.baseUrl, 'http://emby.test:8096/emby');
  });

  testWidgets('addLine is enabled on a new server form', (tester) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);
    await _expandMore(tester);
    final add = tester.widget<TextButton>(find.byKey(ConnectFormKeys.addLine));
    expect(add.onPressed, isNotNull);
    await tester.tap(find.byKey(ConnectFormKeys.addLine));
    await tester.pump();
    expect(find.byKey(ConnectFormKeys.extraLine(0)), findsOneWidget);
  });

  testWidgets('addLine under 更多 adds a second line for the saved server', (
    tester,
  ) async {
    final wan = FakeEmbyServer(
      serverId: server.serverId,
      serverName: server.serverName,
      baseUrl: Uri.parse('http://emby-wan.test:8096'),
    );
    adapter.add(wan);
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await _settle(tester);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await _settle(tester);
    await tester.tap(find.byKey(SessionActions.serverMenuKey));
    await _settle(tester);
    await tester.tap(find.text('退出登录'));
    await _settle(tester);

    await _tapVisible(
      tester,
      find.byKey(Key('saved-server-${server.serverId}')),
    );
    await _expandMore(tester);
    await _tapVisible(tester, find.byKey(ConnectFormKeys.addLine));
    await _settle(tester);
    await tester.enterText(
      find.byKey(ConnectFormKeys.extraLine(0)),
      wan.baseUrl.toString(),
    );
    await tester.enterText(
      find.byKey(ConnectFormKeys.password),
      'correct-horse',
    );
    await tester.pump();
    await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));

    expect(auth.isLoggedIn, isTrue);
    expect(auth.savedServers.single.lines, hasLength(2));
    expect(
      auth.savedServers.single.lines.map((line) => line.address),
      containsAll(<String>[server.baseUrl.toString(), wan.baseUrl.toString()]),
    );
  });
}
