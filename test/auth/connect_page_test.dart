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
    await tester.pumpAndSettle();

    expect(find.text(kProductName), findsWidgets);
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await tester.pumpAndSettle();

    expect(find.byKey(ConnectFormKeys.submit), findsNothing);
    expect(find.text('已连接 灯川测试'), findsOneWidget);
    expect(auth.isLoggedIn, isTrue);
  });

  testWidgets('wrong password stays on connect and shows AppErrorView', (
    tester,
  ) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'wrong',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await tester.pumpAndSettle();

    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('用户名或密码错误'), findsOneWidget);
    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('certificate error stays on connect and shows AppErrorView', (
    tester,
  ) async {
    adapter.certificateError = true;
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('证书错误，无法建立安全连接'), findsOneWidget);
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('unreachable address shows a visible reason', (tester) async {
    final auth = controller();
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    await _enter(
      tester,
      address: 'http://emby.invalid:8096',
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('无法连接服务器'), findsOneWidget);
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
  });

  testWidgets(
    'saved server fills the address and logout requires login again',
    (tester) async {
      final auth = controller();
      await tester.pumpWidget(RillightApp(auth: auth));
      await tester.pumpAndSettle();

      await _enter(
        tester,
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await tester.tap(find.byKey(ConnectFormKeys.submit));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('切换服务器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();

      expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
      expect(find.text('灯川测试'), findsOneWidget);

      await tester.enterText(find.byKey(ConnectFormKeys.address), '');
      await tester.tap(find.byKey(Key('saved-server-${server.serverId}')));
      await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    await _enter(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.tap(find.byKey(ConnectFormKeys.submit));
    await tester.pumpAndSettle();
    expect(find.text('已连接 灯川测试'), findsOneWidget);

    server.expireAuthenticatedRequests = true;
    await tester.runAsync(() async {
      await expectLater(
        auth.client.getJson('/System/Info'),
        throwsA(isA<Object>()),
      );
    });
    await tester.pumpAndSettle();

    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('会话已失效，请重新登录'), findsOneWidget);
    expect(find.byType(SessionActions), findsOneWidget);
  });
}
