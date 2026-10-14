import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';

const _first = SavedServer(
  id: 'one',
  name: '家里的影音库',
  username: 'alice',
  lines: [ServerLine(id: 'line-one', address: 'http://home.test:8096')],
);
const _second = SavedServer(
  id: 'two',
  name: '备用服务器',
  username: 'bob',
  lines: [ServerLine(id: 'line-two', address: 'https://backup.test')],
);

Future<AuthController> _auth() async {
  final auth = AuthController(
    client: EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'phone',
        deviceId: 'server-manager-test',
        version: '1',
      ),
    ),
    credentials: MemoryCredentialStore({
      'one': const StoredCredentials(
        accessToken: 'synthetic',
        userId: 'user',
        username: 'alice',
      ),
    }),
    servers: MemoryServerListStore(
      const ServerListSnapshot(servers: [_first, _second]),
    ),
  );
  await auth.restore();
  return auth;
}

Future<void> _pump(
  WidgetTester tester,
  AuthController auth, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        ...AppLocalizations.localizationsDelegates,
        ui.GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => ui.AppUiTheme(
        data: Theme.of(context).brightness == Brightness.dark
            ? ui.AppUiTheme.dark()
            : ui.AppUiTheme.light(),
        child: ((context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ))(context, child),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => ui.AppButton(
            onPressed: () => showPhoneServerManager(
              context,
              auth: auth,
              onSelect: (_, _) async {},
              onAddServer: () {},
            ),
            child: const Text('open-manager'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-manager'));
  await settle(tester);
}

void main() {
  testWidgets('current logged-in server deletion redirects and undo survives', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'delete-current-test',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    expect(auth.isLoggedIn, isTrue);
    final saved = auth.savedServers.single;
    final credentials = await auth.credentials.read(saved.id);
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    });
    app.router.go(AppRoutes.mine);
    await tester.pumpWidget(app);
    await settle(tester);
    await tester.tap(find.byKey(PhoneMinePage.lineKey));
    await settle(tester);
    await tester.tap(find.byKey(Key('phone-mine-server-delete-${saved.id}')));
    await settle(tester);
    await tester.tap(find.byKey(PhoneMinePage.serverDeleteConfirmKey));
    await settle(tester);
    expect(auth.isLoggedIn, isFalse);
    expect(app.router.state.uri.path, AppRoutes.connect);
    expect(find.byType(PhoneServerManager), findsNothing);
    expect(auth.savedServers, isEmpty);
    expect(await auth.credentials.read(saved.id), isNull);
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect(auth.savedServers.single.id, saved.id);
    expect(
      (await auth.credentials.read(saved.id))?.accessToken,
      credentials!.accessToken,
    );
    expect(auth.isLoggedIn, isFalse);
    expect((await auth.servers.load()).lastServerId, isNull);
    expect(app.router.state.uri.path, AppRoutes.connect);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('phone management deletes locally and offers a reachable undo', (
    tester,
  ) async {
    final auth = await _auth();
    addTearDown(auth.dispose);
    await _pump(tester, auth);
    await tester.tap(find.byKey(const Key('phone-mine-server-delete-one')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('phone-mine-server-delete-confirm')));
    await settle(tester);
    expect(auth.savedServers.map((s) => s.id), ['two']);
    expect(await auth.credentials.read('one'), isNull);
    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect(auth.savedServers.map((s) => s.id), contains('one'));
    expect((await auth.credentials.read('one'))?.accessToken, 'synthetic');
    expect(auth.isLoggedIn, isFalse);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'search and deletion remain usable with large text and keyboard',
    (tester) async {
      final auth = await _auth();
      addTearDown(auth.dispose);
      await _pump(tester, auth, scale: 1.8);
      await tester.enterText(
        find.byKey(PhoneServerManager.searchKey),
        'backup',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(
        find.byKey(const Key('phone-mine-server-delete-one')),
        findsNothing,
      );
      final remove = find.byKey(const Key('phone-mine-server-delete-two'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('phone-mine-server-delete-cancel')),
      );
      await settle(tester);
      expect(auth.savedServers, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  test(
    'local names and restored entries do not select a different startup server',
    () async {
      final auth = await _auth();
      addTearDown(auth.dispose);
      await auth.renameServer('one', '客厅');
      final renamed = auth.savedServers.firstWhere((s) => s.id == 'one');
      expect(renamed.displayName, '客厅');
      expect(renamed.name, _first.name);
      expect(SavedServer.fromJson(renamed.toJson()).displayName, '客厅');
      await auth.deleteServer('one');
      await auth.restoreSavedServer(renamed, null);
      expect((await auth.servers.load()).lastServerId, isNull);
    },
  );
}
