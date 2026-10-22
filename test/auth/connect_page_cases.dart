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
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_management_widgets.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/auth/provider_login_form.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:flutter/services.dart';

import '../helpers/cupertino_test_app.dart';

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

  testWidgets(
    'wide connect hero panel is a solid surface without brand gradients',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = controller();
      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);

      final panel = find.byKey(const ValueKey('connect-hero-panel'));
      expect(panel, findsOneWidget);
      final scheme = AppUiTheme.of(tester.element(panel)).colorScheme;
      final box =
          tester.widget<DecoratedBox>(panel).decoration as BoxDecoration;
      expect(box.gradient, isNull);
      expect(box.color, scheme.surfaceContainerLow);
      // 整页没有残留的 primary/secondary 装饰渐变。
      final opaque = {
        scheme.primary.withValues(alpha: 1),
        scheme.secondary.withValues(alpha: 1),
      };
      for (final decorated in tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      )) {
        final decoration = decorated.decoration;
        if (decoration is! BoxDecoration) continue;
        final colors = decoration.gradient?.colors ?? const <Color>[];
        expect(
          colors.where((color) => opaque.contains(color.withValues(alpha: 1))),
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
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
    // 线路默认折叠:卡片只显示当前线路,点「2 条线路」才展开。
    final savedId = auth.savedServers.single.id;
    expect(find.byKey(Key('saved-line-${lanLine.id}')), findsNothing);
    expect(find.byKey(Key('saved-line-${wanLine.id}')), findsNothing);
    final toggle = find.byKey(ConnectFormKeys.savedServerLines(savedId));
    expect(
      find.descendant(of: toggle, matching: find.text('2 条线路')),
      findsOneWidget,
    );
    bool? expanded() => tester
        .widget<Semantics>(
          find.ancestor(of: toggle, matching: find.byType(Semantics)).first,
        )
        .properties
        .expanded;
    expect(expanded(), isFalse);
    await _tapVisible(tester, toggle);
    expect(expanded(), isTrue);
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
    expect(
      tester
          .widget<ui.AppActionButton>(find.byKey(ConnectFormKeys.addLine))
          .tier,
      ui.AppActionTier.secondary,
    );
    expect(
      tester
          .widget<ui.AppActionButton>(find.byKey(ConnectFormKeys.deleteLine))
          .tier,
      ui.AppActionTier.tertiary,
    );
  }, tags: ['integration']);

  Future<AuthController> savedServers(WidgetTester tester, int count) async {
    final auth = controller();
    for (var i = 0; i < count; i++) {
      adapter.add(
        FakeEmbyServer(
          serverId: 'server-$i',
          serverName: '服务器 $i',
          baseUrl: Uri.parse('http://emby-$i.test:8096'),
        ),
      );
    }
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        await auth.connect(
          address: 'http://emby-$i.test:8096',
          username: 'alice',
          password: 'correct-horse',
        );
      }
      if (count > 0) await auth.logout();
    });
    expect(auth.savedServers, hasLength(count));
    return auth;
  }

  testWidgets(
    'desktop login has one primary action and no empty saved-server block',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = await savedServers(tester, 0);
      await tester.pumpWidget(RillightApp(auth: auth));
      await _settle(tester);

      expect(find.text('已保存的服务器'), findsNothing);
      expect(find.text('暂无已保存的服务器'), findsNothing);
      expect(find.byKey(ConnectFormKeys.addServer), findsNothing);
      expect(
        tester
            .widget<ui.AppActionButton>(
              find.byKey(ConnectFormKeys.importBackup),
            )
            .tier,
        ui.AppActionTier.secondary,
      );
      final filled = tester
          .widgetList<ui.AppButton>(find.byType(ui.AppButton))
          .where((button) => button.variant == ui.AppButtonVariant.filled);
      expect(filled, hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(ConnectFormKeys.submit),
          matching: find.byType(ui.AppButton),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ui.AppButton>(find.byKey(ConnectFormKeys.submit)).variant,
        ui.AppButtonVariant.filled,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'desktop saved servers are compact cards with grouped secondary entries',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = await savedServers(tester, 2);
      final app = RillightApp(auth: auth);
      app.router.go('/connect');
      await tester.pumpWidget(app);
      await _settle(tester);

      expect(find.text('已保存的服务器'), findsOneWidget);
      for (final key in [
        ConnectFormKeys.importBackup,
        ConnectFormKeys.addServer,
      ]) {
        expect(
          tester.widget<ui.AppActionButton>(find.byKey(key)).tier,
          ui.AppActionTier.secondary,
        );
      }
      final group = find.ancestor(
        of: find.byKey(ConnectFormKeys.importBackup),
        matching: find.byType(Wrap),
      );
      expect(
        find.descendant(
          of: group.first,
          matching: find.byKey(ConnectFormKeys.addServer),
        ),
        findsOneWidget,
      );
      for (final saved in auth.savedServers) {
        final card = find.byKey(Key('saved-server-${saved.id}'));
        expect(card, findsOneWidget);
        expect(
          find.descendant(
            of: card,
            matching: find.text(
              'alice · ${serverLineLabel(saved.activeLine!)}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(ConnectFormKeys.savedServerLines(saved.id)),
          findsNothing,
        );
      }
      final filled = tester
          .widgetList<ui.AppButton>(find.byType(ui.AppButton))
          .where((button) => button.variant == ui.AppButtonVariant.filled);
      expect(filled, hasLength(1));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  Widget host(AuthController auth, Widget page) => AuthScope(
    controller: auth,
    child: CupertinoTestApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...ui.GlobalCupertinoLocalizations.delegates,
      ],
      home: page,
    ),
  );

  testWidgets(
    'phone saved servers are at most three stacked cards beside one secondary group',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      final auth = await savedServers(tester, 4);
      await tester.pumpWidget(host(auth, const AndroidConnectPage()));
      await _settle(tester);

      final cards = [
        for (final saved in auth.savedServers)
          find.byKey(Key('phone-saved-server-${saved.id}')),
      ];
      expect(cards.where((card) => card.evaluate().isNotEmpty), hasLength(3));
      expect(cards.last, findsNothing);
      // 竖排:同一左缘,依次向下。
      final rects = [for (final card in cards.take(3)) tester.getRect(card)];
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].left, rects[0].left);
        expect(rects[i].top, greaterThan(rects[i - 1].bottom - 1));
      }
      const manage = Key('phone-connect-manage-servers');
      const import = Key('android-connect-import');
      for (final key in [manage, import]) {
        expect(
          tester.widget<ui.AppActionButton>(find.byKey(key)).tier,
          ui.AppActionTier.secondary,
        );
      }
      final group = find
          .ancestor(of: find.byKey(import), matching: find.byType(Wrap))
          .first;
      expect(
        find.descendant(of: group, matching: find.byKey(manage)),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(manage)).top,
        greaterThan(rects.last.top),
      );

      const submit = Key('android-connect-submit');
      for (final insets in [0.0, 300.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.view.viewInsets = FakeViewPadding(bottom: insets);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(submit),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await _settle(tester);
        final rect = tester.getRect(find.byKey(submit));
        expect(rect.bottom, lessThanOrEqualTo(760 - insets));
        expect(find.byKey(submit).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
    tags: ['integration'],
  );

  testWidgets('phone login without saved servers keeps only backup import', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await savedServers(tester, 0);
    await tester.pumpWidget(host(auth, const AndroidConnectPage()));
    await _settle(tester);

    expect(find.text('已保存的服务器'), findsNothing);
    expect(find.byKey(const Key('phone-connect-manage-servers')), findsNothing);
    expect(
      tester
          .widget<ui.AppActionButton>(
            find.byKey(const Key('android-connect-import')),
          )
          .tier,
      ui.AppActionTier.secondary,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'TV left column lists three focusable servers, grouped entries, then appearance',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = await savedServers(tester, 4);
      await tester.pumpWidget(host(auth, const TvConnectPage()));
      await _settle(tester);

      final cards = [
        for (final saved in auth.savedServers)
          find.byKey(Key('tv-saved-server-${saved.id}')),
      ];
      expect(cards.where((card) => card.evaluate().isNotEmpty), hasLength(3));
      for (final card in cards.take(3)) {
        expect(
          find.descendant(of: card, matching: find.byType(Focus)),
          findsWidgets,
        );
      }
      const all = Key('tv-connect-servers');
      const import = ValueKey('tv-connect-import');
      expect(find.byKey(all), findsOneWidget);
      expect(find.text('全部服务器 · 4'), findsOneWidget);
      final group = find
          .ancestor(of: find.byKey(import), matching: find.byType(Wrap))
          .first;
      for (final key in [all, const Key('tv-lan-assist')]) {
        expect(
          find.descendant(of: group, matching: find.byKey(key)),
          findsOneWidget,
        );
      }
      expect(
        tester.getRect(find.byKey(const Key('tv-lan-assist'))).right,
        lessThan(
          tester.getRect(find.byKey(const Key('tv-connect-submit'))).left,
        ),
      );
      final lastCard = tester.getRect(cards[2]);
      expect(tester.getRect(find.byKey(all)).top, greaterThan(lastCard.top));
      final appearance = find.byKey(const Key('tv-appearance-system'));
      await tester.scrollUntilVisible(
        appearance,
        120,
        scrollable: find
            .ancestor(of: find.byKey(import), matching: find.byType(Scrollable))
            .first,
      );
      await _settle(tester);
      expect(
        tester.getRect(appearance).top,
        greaterThan(tester.getRect(find.byKey(import)).bottom),
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('TV saved server card enters that server', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await savedServers(tester, 2);
    final target = auth.savedServers.first;
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
    );
    app.router.go('/connect');
    await tester.pumpWidget(app);
    await _settle(tester);
    final card = find.byKey(Key('tv-saved-server-${target.id}'));
    expect(card, findsOneWidget);

    await tester.tap(card);
    for (var i = 0; i < 40 && !auth.isLoggedIn; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session!.server.id, target.id);
    expect(tester.takeException(), isNull);
    // 已登录首页的重试计时器在卸载后跑完,避免残留 Timer。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }, tags: ['integration']);

  testWidgets('TV login D-pad moves from cards to the entry group and form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await savedServers(tester, 4);
    await tester.pumpWidget(host(auth, const TvConnectPage()));
    await _settle(tester);

    bool focusedIn(Finder target) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      final element = target.evaluate().single;
      if (focused == element) return true;
      var found = false;
      focused.visitAncestorElements((ancestor) {
        found = ancestor == element;
        return !found;
      });
      return found;
    }

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await _settle(tester);
      // ignore: avoid_print
    }

    final cards = [
      for (final saved in auth.savedServers.take(3))
        find.byKey(Key('tv-saved-server-${saved.id}')),
    ];
    const all = Key('tv-connect-servers');
    const import = ValueKey('tv-connect-import');
    const assist = Key('tv-lan-assist');
    expect(focusedIn(find.byKey(const Key('tv-connect-address'))), isTrue);

    Focus.of(
      tester.element(
        find.descendant(of: cards.first, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await _settle(tester);
    expect(focusedIn(cards.first), isTrue);
    await press(LogicalKeyboardKey.arrowDown);
    expect(focusedIn(cards[1]), isTrue);
    await press(LogicalKeyboardKey.arrowDown);
    expect(focusedIn(cards[2]), isTrue);
    // 按「下」进入次级入口组(落在离卡片中心最近的一颗),不跳到右栏。
    await press(LogicalKeyboardKey.arrowDown);
    final group = find
        .ancestor(of: find.byKey(import), matching: find.byType(Wrap))
        .first;
    expect(focusedIn(group), isTrue);
    for (var i = 0; i < 2 && !focusedIn(find.byKey(all)); i++) {
      await press(LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedIn(find.byKey(all)), isTrue);
    await press(LogicalKeyboardKey.arrowRight);
    expect(focusedIn(find.byKey(import)), isTrue);
    // 右栏表单与左栏次级入口组之间左右可达;手机辅助与导入同行时在右侧,
    // 换行时在导入下方。
    final form = find.ancestor(
      of: find.byKey(const Key('tv-connect-submit')),
      matching: find.byType(ProviderLoginForm),
    );
    final leftColumn = find
        .ancestor(of: find.byKey(import), matching: find.byType(ListView))
        .first;
    final wrapped =
        tester.getRect(find.byKey(assist)).top >=
        tester.getRect(find.byKey(import)).bottom;
    await press(LogicalKeyboardKey.arrowRight);
    if (wrapped) {
      expect(focusedIn(form), isTrue);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(focusedIn(find.byKey(import)), isTrue);
      await press(LogicalKeyboardKey.arrowDown);
      expect(focusedIn(find.byKey(assist)), isTrue);
    } else {
      expect(focusedIn(find.byKey(assist)), isTrue);
      await press(LogicalKeyboardKey.arrowRight);
      expect(focusedIn(form), isTrue);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(focusedIn(leftColumn), isTrue);
    }
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('TV login without saved servers renders no server section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await savedServers(tester, 0);
    await tester.pumpWidget(host(auth, const TvConnectPage()));
    await _settle(tester);

    expect(find.text('已保存的服务器'), findsNothing);
    expect(find.byKey(const Key('tv-connect-servers')), findsNothing);
    expect(find.byKey(const ValueKey('tv-connect-import')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
