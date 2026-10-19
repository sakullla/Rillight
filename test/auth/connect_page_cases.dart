import 'server_ui_harness.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import 'configured_source.dart';
import '../helpers/image_cache_fixture.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/app.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';

const _device = ClientDeviceInfo(
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

  testWidgets(
    'wrong password, successful login, logout, and saved server fill',
    (tester) async {
      final auth = controller();
      final app = RillightApp(auth: auth);
      await tester.pumpWidget(app);
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
      await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('用户名或密码错误'), findsOneWidget);
      expect(auth.isLoggedIn, isFalse);

      await tester.enterText(
        find.byKey(ConnectFormKeys.password),
        'correct-horse',
      );
      await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsNothing);
      expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
      expect(auth.isLoggedIn, isTrue);

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await _settle(tester);
      expect(find.byKey(const Key('server-manage-providers')), findsNothing);
      expect(find.text('服务与范围管理'), findsNothing);
      await openServerEditor(tester, auth.session!.server.id);
      await serverUiTap(tester, const Key('server-editor-logout'));
      await serverUiTap(tester, const Key('server-logout-confirm'));
      await _settle(tester);
      expect(auth.isLoggedIn, isFalse);
      // Saved servers remain available; a direct login link still supports prefill.
      app.router.go('/connect');
      await _settle(tester);

      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.text('灯川测试'), findsOneWidget);

      await tester.enterText(find.byKey(ConnectFormKeys.address), '');
      await _tapVisible(
        tester,
        find.byKey(
          Key('saved-server-${configuredSourceId(auth, server.serverId)}'),
        ),
      );
      await _settle(tester);

      expect(
        tester
            .widget<ui.AppTextField>(find.byKey(ConnectFormKeys.address))
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
      await auth.selectSavedServer(configuredSourceId(auth, server.serverId));
    });
    expect(auth.savedServers.single.lines, hasLength(2));

    final app = RillightApp(auth: auth);
    app.router.go('/connect');
    await tester.pumpWidget(app);
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
          .widget<ui.AppTextField>(find.byKey(ConnectFormKeys.address))
          .controller
          ?.text,
      wan.baseUrl.toString(),
    );

    await _tapVisible(tester, find.byKey(Key('saved-line-${lanLine.id}')));
    final lanTile = find.byKey(Key('saved-line-${lanLine.id}'));
    final tileFill = tester.widget<Container>(
      find.ancestor(of: lanTile, matching: find.byType(Container)).first,
    );
    final selection = ui.AppSelectionDecoration.of(
      ui.AppUiTheme.of(tester.element(lanTile)).colorScheme,
      radius: ui.AppRadii.md,
    );
    final tileDecoration = tileFill.decoration! as BoxDecoration;
    expect(tileDecoration.color, selection.color);
    expect(
      (tileDecoration.border! as Border).top.width,
      ui.AppSelectionDecoration.borderWidth,
    );
    expect(
      tester
          .widget<ui.AppTextField>(find.byKey(ConnectFormKeys.address))
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
    await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('HTTP 403: 服务器或访问防护拒绝了请求，请检查地址或线路后重试'), findsOneWidget);
    expect(find.textContaining('该线路已被禁用'), findsNothing);
    expect(find.text('连接失败'), findsNothing);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.client.baseUrl, isNull);
  }, tags: ['integration']);

  testWidgets('login saves the User-Agent at the server level', (tester) async {
    final auth = controller();
    final app = RillightApp(auth: auth);
    await tester.pumpWidget(app);
    await _settle(tester);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await _tapVisible(tester, find.byKey(ConnectFormKeys.more));
    await tester.enterText(
      find.byKey(ConnectFormKeys.userAgent),
      '  CustomUA/1.0  ',
    );
    await _tapVisible(tester, find.byKey(ConnectFormKeys.submit));
    await _settle(tester);

    expect(auth.isLoggedIn, isTrue);
    final saved = auth.savedServers.single;
    expect(saved.normalizedUserAgent, 'CustomUA/1.0');
    for (final line in saved.lines) {
      expect(line.toJson().containsKey('userAgent'), isFalse);
    }
    expect(auth.client.sessionHeaders['User-Agent'], 'CustomUA/1.0');

    await tester.tap(find.byKey(SessionActions.serverMenuKey));
    await _settle(tester);
    await openServerEditor(tester, auth.session!.server.id);
    await serverUiTap(tester, const Key('server-editor-logout'));
    await serverUiTap(tester, const Key('server-logout-confirm'));
    await _settle(tester);
    expect(auth.isLoggedIn, isFalse);
    app.router.go('/connect');
    await _settle(tester);

    // Selecting the saved server fills the server-level UA back into the form.
    await tester.enterText(find.byKey(ConnectFormKeys.address), '');
    await _tapVisible(
      tester,
      find.byKey(
        Key('saved-server-${configuredSourceId(auth, server.serverId)}'),
      ),
    );
    await _settle(tester);
    await _tapVisible(tester, find.byKey(ConnectFormKeys.more));
    expect(
      tester
          .widget<ui.AppTextField>(find.byKey(ConnectFormKeys.userAgent))
          .controller
          ?.text,
      'CustomUA/1.0',
    );
  }, tags: ['integration']);
}
