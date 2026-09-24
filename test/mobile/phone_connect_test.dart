import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-connect',
  version: '1',
);

const _address = Key('android-connect-address');
const _username = Key('android-connect-username');
const _password = Key('android-connect-password');
const _submit = Key('android-connect-submit');
const _more = Key('android-connect-more');
const _path = Key('android-connect-path');
const _userAgent = Key('android-connect-user-agent');
const _addLine = Key('android-connect-add-line');

void main() {
  late FakeEmbyServer server;

  setUp(() {
    server = FakeEmbyServer();
  });

  Future<AuthController> pumpConnect(
    WidgetTester tester, {
    int generation = 0,
    AuthController? auth,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller =
        auth ??
        AuthController.memory(
          client: EmbyClient(
            device: _device,
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
    if (auth == null) {
      addTearDown(controller.dispose);
    }
    await tester.pumpWidget(_harness(controller, generation: generation));
    await tester.pumpAndSettle();
    return controller;
  }

  String textOf(WidgetTester tester, Key key) {
    return tester.widget<TextField>(find.byKey(key)).controller!.text;
  }

  Future<void> enterCredentials(
    WidgetTester tester, {
    required String address,
    required String username,
    required String password,
  }) async {
    await tester.enterText(find.byKey(_address), address);
    await tester.enterText(find.byKey(_username), username);
    await tester.enterText(find.byKey(_password), password);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('path, extra line and User-Agent stay under 更多 until expanded', (
    tester,
  ) async {
    final auth = await pumpConnect(tester);
    expect(find.byKey(_path), findsNothing);
    await tap(tester, find.byKey(_more));
    expect(find.byKey(_path), findsOneWidget);
    expect(find.byKey(_userAgent), findsOneWidget);
    expect(find.byKey(_addLine), findsOneWidget);

    await enterCredentials(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await tester.enterText(find.byKey(_path), '/emby');
    await tester.enterText(find.byKey(_userAgent), 'CustomUA/1.0');
    await tap(tester, find.byKey(_addLine));
    await tester.enterText(
      find.byKey(const Key('android-connect-extra-line-0')),
      'http://backup.test:8096',
    );
    await tap(tester, find.byKey(_submit));

    expect(auth.isLoggedIn, isTrue);
    expect(auth.savedServers.single.baseUrl, 'http://emby.test:8096/emby');
    expect(
      auth.savedServers.single.lines.map((line) => line.address),
      contains('http://backup.test:8096'),
    );
    expect(
      auth.savedServers.single.activeLine?.normalizedUserAgent,
      'CustomUA/1.0',
    );
    expect(server.lastUserAgent, 'CustomUA/1.0');
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('connection failure stays on the page and can be retried', (
    tester,
  ) async {
    final auth = await pumpConnect(tester);
    await enterCredentials(
      tester,
      address: 'ftp://files.test',
      username: 'alice',
      password: 'correct-horse',
    );
    await tap(tester, find.byKey(_submit));

    expect(auth.isLoggedIn, isFalse);
    expect(find.byType(AndroidConnectPage), findsOneWidget);
    expect(find.text('请输入有效的服务器地址'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('EmbyException'), findsNothing);

    await tester.enterText(find.byKey(_address), server.baseUrl.toString());
    await tester.enterText(find.byKey(_password), 'wrong');
    await tap(tester, find.byKey(_submit));

    expect(auth.isLoggedIn, isFalse);
    expect(find.byType(AndroidConnectPage), findsOneWidget);
    expect(find.text('HTTP 401: invalid credentials'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('请输入有效的服务器地址'), findsNothing);
    expect(textOf(tester, _password), 'wrong');

    await tester.enterText(find.byKey(_password), 'correct-horse');
    await tap(tester, find.byKey(_submit));

    expect(auth.isLoggedIn, isTrue);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('unsubmitted password is empty after the page is recreated', (
    tester,
  ) async {
    final auth = await pumpConnect(tester);
    await enterCredentials(
      tester,
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'not-submitted',
    );
    await tester.pumpWidget(_harness(auth));
    await tester.pump();

    expect(auth.connectDraft?.password, 'not-submitted');
    expect(textOf(tester, _password), 'not-submitted');
    expect(textOf(tester, _address), server.baseUrl.toString());

    await tester.pumpWidget(_harness(auth, generation: 1));
    await tester.pumpAndSettle();

    expect(find.byType(AndroidConnectPage), findsOneWidget);
    expect(textOf(tester, _password), isEmpty);
    expect(auth.connectDraft?.password, isEmpty);
    expect(textOf(tester, _address), server.baseUrl.toString());
    expect(textOf(tester, _username), 'alice');
    expect(await auth.credentials.read(server.serverId), isNull);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

Widget _harness(AuthController auth, {int generation = 0}) {
  return AuthScope(
    controller: auth,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AndroidConnectPage(key: ValueKey(generation)),
    ),
  );
}
