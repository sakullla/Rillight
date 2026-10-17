import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_selection_page.dart';
import 'package:rillight/auth/server_list_store.dart';

import 'server_ui_harness.dart';

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
    CupertinoTestApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        ...[
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        ui.GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => ui.AppUiTheme(
        data: AppUiTheme.of(context).brightness == Brightness.dark
            ? ui.AppUiTheme.dark()
            : ui.AppUiTheme.light(),
        child: ((context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ))(context, child),
      ),
      home: CupertinoPageScaffold(
        child: Builder(
          builder: (context) => ui.AppButton(
            onPressed: () =>
                showServerSelection(context, auth: auth, phone: true),
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
  testWidgets(
    'current server removal redirects and clears only its local login',
    (tester) async {
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
      await serverUiTap(tester, Key('server-more-${saved.id}'));
      await serverUiTap(tester, Key('server-action-remove-${saved.id}'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('server-remove-confirm')));
      await settle(tester);
      expect(auth.isLoggedIn, isFalse);
      expect(app.router.state.uri.path, AppRoutes.connect);
      expect(find.byType(ServerSelectionPage), findsNothing);
      expect(auth.savedServers, isEmpty);
      expect(await auth.credentials.read(saved.id), isNull);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('phone removal requires a separate confirmation', (tester) async {
    final auth = await _auth();
    addTearDown(auth.dispose);
    await _pump(tester, auth);
    await serverUiTap(tester, const Key('server-more-one'));
    await serverUiTap(tester, const Key('server-action-remove-one'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('server-remove-confirm')));
    await settle(tester);
    expect(auth.savedServers.map((s) => s.id), ['two']);
    expect(await auth.credentials.read('one'), isNull);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'search and deletion remain usable with large text and keyboard',
    (tester) async {
      final auth = await _auth();
      addTearDown(auth.dispose);
      await _pump(tester, auth, scale: 1.8);
      await tester.enterText(
        find.byKey(ServerSelectionPage.searchKey),
        'backup',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(find.byKey(const Key('server-more-one')), findsNothing);
      final remove = find.byKey(const Key('server-more-two'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await settle(tester);
      await serverUiTap(tester, const Key('server-action-remove-two'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('server-remove-cancel')));
      await settle(tester);
      expect(auth.savedServers, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  for (final width in [360.0, 412.0]) {
    testWidgets(
      'phone editor keeps its draft through child back with keyboard at $width',
      (tester) async {
        final auth = await _auth();
        addTearDown(auth.dispose);
        await _pump(tester, auth, scale: 1.8);
        tester.view.physicalSize = Size(width, 780);
        await tester.pump();
        await openServerEditor(tester, 'one');
        await tester.enterText(
          find.byKey(const Key('server-editor-name')),
          '仍然保留的草稿',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.resetViewInsets);
        await serverUiTap(tester, const Key('server-editor-add-line'));
        await tester.enterText(
          find.byKey(const Key('server-line-address')),
          'https://draft-only.test',
        );
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(
          tester
              .widget<ui.AppTextField>(
                find.byKey(const Key('server-editor-name')),
              )
              .controller!
              .text,
          '仍然保留的草稿',
        );
        expect(find.byKey(const Key('server-editor-save')), findsOneWidget);
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(auth.savedServers.first.displayName, _first.name);
        expect(auth.savedServers.first.lines, hasLength(1));
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

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
