import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-change-password',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  AuthController controller() {
    final auth = AuthController.memory(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
    );
    addTearDown(auth.dispose);
    return auth;
  }

  Future<AuthController> connected(WidgetTester? tester) async {
    final auth = controller();
    Future<void> connect() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    }

    // widget 测试里网络 future 必须在 runAsync 的真实异步区内创建并等待。
    if (tester == null) {
      await connect();
    } else {
      await tester.runAsync(connect);
    }
    expect(auth.isLoggedIn, isTrue);
    return auth;
  }

  test(
    'empty current password is submitted as-is and the new password is stored',
    () async {
      final auth = await connected(null);

      final changed = await auth.changePassword(
        currentPassword: '',
        newPassword: 'new-horse',
      );

      expect(changed, isTrue);
      expect(server.requests, contains('POST /emby/Users/user-alice/Password'));
      final body = server.changePasswordRequests.single;
      expect(body['Id'], 'user-alice');
      // 旧密码留空:请求不带 CurrentPw,由服务器裁决。
      expect(body.containsKey('CurrentPw'), isFalse);
      expect(body['NewPw'], 'new-horse');
      // 成功后本机凭据为新密码,会话保持。
      final stored = await auth.credentials.read(server.serverId);
      expect(stored?.password, 'new-horse');
      expect(stored?.accessToken, auth.session?.accessToken);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.passwordChangeFailure, isNull);
      // 服务器端密码已被替换。
      expect(server.effectivePassword('user-alice'), 'new-horse');
    },
  );

  test(
    'server rejection keeps the old password and the signed-in session',
    () async {
      final auth = await connected(null);
      server.changePasswordStatus = 400;
      server.changePasswordMessage = '密码策略不满足';

      final changed = await auth.changePassword(
        currentPassword: 'correct-horse',
        newPassword: 'new-horse',
      );

      expect(changed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.passwordChangeFailure?.statusCode, 400);
      expect(auth.passwordChangeFailure?.detail, 'HTTP 400: 密码策略不满足');
      // 本机仍保存旧密码,服务器端密码未变。
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'correct-horse',
      );
      expect(server.effectivePassword('user-alice'), 'correct-horse');
      // 会话仍可用。
      final info = await auth.client.getJson('/System/Info');
      expect(info['ServerName'], server.serverName);
    },
  );

  test(
    'a wrong current password is rejected by the server, not the client',
    () async {
      final auth = await connected(null);

      final changed = await auth.changePassword(
        currentPassword: 'wrong-horse',
        newPassword: 'new-horse',
      );

      expect(changed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.passwordChangeFailure?.statusCode, 400);
      expect(auth.passwordChangeFailure?.detail, 'HTTP 400: 旧密码不正确');
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'correct-horse',
      );
    },
  );

  test(
    'a revoked session returns to the connect form and the new password enters',
    () async {
      server.revokeSessionOnChangePassword = true;
      final auth = await connected(null);

      final changed = await auth.changePassword(
        currentPassword: '',
        newPassword: 'new-horse',
      );

      // 改密本身成功;服务器吊销了当前会话,回到登录页并预选当前服务器。
      expect(changed, isTrue);
      expect(auth.isLoggedIn, isFalse);
      expect(auth.prefill?.id, server.serverId);
      expect(auth.failure?.kind, EmbyFailureKind.sessionExpired);
      // 本机已保存新密码。
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'new-horse',
      );

      // 旧密码不再有效。
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      expect(auth.isLoggedIn, isFalse);
      expect(auth.failure?.kind, EmbyFailureKind.invalidCredentials);

      // 新密码可重新进入。
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'new-horse',
      );
      expect(auth.isLoggedIn, isTrue);
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'new-horse',
      );
    },
  );

  testWidgets(
    'dialog submits with an empty current password and closes on success',
    (tester) async {
      final auth = await connected(tester);
      await _pumpDialog(tester, auth);

      // 旧密码留空不阻断:只填新密码与确认即可提交。
      await tester.enterText(
        find.byKey(ChangePasswordDialog.newPasswordField),
        'new-horse',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(ChangePasswordDialog.confirmField),
        'new-horse',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(ChangePasswordDialog.submitKey))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(ChangePasswordDialog.submitKey));
      await _pumpUntilGone(tester, find.byType(AlertDialog));

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        server.changePasswordRequests.single.containsKey('CurrentPw'),
        isFalse,
      );
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'new-horse',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dialog keeps inputs and shows the reason on rejection', (
    tester,
  ) async {
    server.changePasswordStatus = 400;
    server.changePasswordMessage = '密码策略不满足';
    final auth = await connected(tester);
    await _pumpDialog(tester, auth);

    await tester.enterText(
      find.byKey(ChangePasswordDialog.currentPasswordField),
      'correct-horse',
    );
    await tester.enterText(
      find.byKey(ChangePasswordDialog.newPasswordField),
      'new-horse',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(ChangePasswordDialog.confirmField),
      'new-horse',
    );
    await tester.pump();
    await tester.tap(find.byKey(ChangePasswordDialog.submitKey));
    await _pumpUntilFound(tester, find.byKey(ChangePasswordDialog.failureKey));

    // 失败:对话框保留,显示服务器给的原因。
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('密码策略不满足'), findsOneWidget);
    expect(
      (await auth.credentials.read(server.serverId))?.password,
      'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog blocks a mismatched confirmation without a request', (
    tester,
  ) async {
    final auth = await connected(tester);
    await _pumpDialog(tester, auth);

    await tester.enterText(
      find.byKey(ChangePasswordDialog.newPasswordField),
      'new-horse',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(ChangePasswordDialog.confirmField),
      'other-horse',
    );
    await tester.pump();

    expect(find.text('两次输入的新密码不一致'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(ChangePasswordDialog.submitKey))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(ChangePasswordDialog.submitKey));
    await tester.pump();
    expect(server.changePasswordRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop switcher exposes the change-password entry', (
    tester,
  ) async {
    var requested = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('open-switcher'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => ServerSwitcherDialog(
                    servers: [
                      SavedServer(
                        id: 'server-id-1',
                        name: '家庭影院',
                        username: 'alice',
                        lines: const [
                          ServerLine(
                            id: 'line-1',
                            address: 'http://emby.test:8096',
                          ),
                        ],
                        activeLineId: 'line-1',
                      ),
                    ],
                    activeServerId: 'server-id-1',
                    activeLineId: 'line-1',
                    onSelect: (_, _) {},
                    onAddServer: () {},
                    onLogout: () {},
                    onDelete: (_) {},
                    onAddLine: (_) {},
                    onEditLine: (_, _) {},
                    onDeleteLine: (_, _) {},
                    // 宿主(session_actions)在回调里先收起切换面板。
                    onChangePassword: () {
                      requested = true;
                      Navigator.of(dialogContext).pop();
                    },
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-switcher')));
    await tester.pumpAndSettle();
    expect(find.byType(ServerSwitcherDialog), findsOneWidget);
    expect(find.text('修改密码'), findsOneWidget);

    await tester.tap(find.byKey(ServerSwitcherDialog.changePasswordKey));
    await tester.pumpAndSettle();

    expect(requested, isTrue);
    // 宿主接管弹改密对话框,切换面板关闭。
    expect(find.byType(ServerSwitcherDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone mine page opens the change-password dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await connected(tester);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(settingsStore: MemoryPlayerSettingsStore()),
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const PhoneMinePage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final entry = find.byKey(PhoneMinePage.changePasswordKey);
    await tester.ensureVisible(entry);
    await tester.pump();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ChangePasswordDialog), findsOneWidget);
    expect(
      find.byKey(ChangePasswordDialog.currentPasswordField),
      findsOneWidget,
    );
    expect(find.byKey(ChangePasswordDialog.newPasswordField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tv dialog focuses password inputs and activates cancel with the remote',
    (tester) async {
      final auth = await connected(tester);
      await _pumpTvDialog(tester, auth);

      expect(
        find.descendant(
          of: find.byType(ChangePasswordDialog),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(ChangePasswordDialog),
          matching: find.byType(FilledButton),
        ),
        findsNothing,
      );
      expect(_focusedPasswordKey(), ChangePasswordDialog.currentPasswordField);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.newPasswordField);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.confirmField);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.cancelKey);
      expect(
        tester
            .widget<TvAction>(find.byKey(ChangePasswordDialog.cancelKey))
            .onPressed,
        isNotNull,
      );

      await _key(tester, LogicalKeyboardKey.select);
      expect(find.byType(AlertDialog), findsNothing);
      expect(server.changePasswordRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tv dialog activates submit with the remote after the new passwords match',
    (tester) async {
      final auth = await connected(tester);
      await _pumpTvDialog(tester, auth);

      expect(_focusedPasswordKey(), ChangePasswordDialog.currentPasswordField);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.newPasswordField);
      await _editFocused(tester, 'new-horse');
      expect(_focusedPasswordKey(), ChangePasswordDialog.newPasswordField);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.confirmField);
      await _editFocused(tester, 'new-horse');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.cancelKey);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedPasswordKey(), ChangePasswordDialog.submitKey);
      expect(
        tester
            .widget<TvAction>(find.byKey(ChangePasswordDialog.submitKey))
            .onPressed,
        isNotNull,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _pumpUntilGone(tester, find.byType(AlertDialog));

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        server.changePasswordRequests.single.containsKey('CurrentPw'),
        isFalse,
      );
      expect(
        (await auth.credentials.read(server.serverId))?.password,
        'new-horse',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Key? _focusedPasswordKey() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final input = context.findAncestorWidgetOfExactType<TvInput>();
  if (input != null) return input.key;
  return context.findAncestorWidgetOfExactType<TvAction>()?.key;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _editFocused(WidgetTester tester, String text) async {
  await _key(tester, LogicalKeyboardKey.select);
  expect(find.byKey(const Key('tv-input-editor')), findsOneWidget);
  await tester.enterText(find.byKey(const Key('tv-input-editor')), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<void> _pumpTvDialog(WidgetTester tester, AuthController auth) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    PresentationScope(
      environment: PresentationEnvironment.tv,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('open-change-password'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ChangePasswordDialog(auth: auth),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-change-password')));
  await tester.pumpAndSettle();
}

Future<void> _pumpDialog(WidgetTester tester, AuthController auth) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open-change-password'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ChangePasswordDialog(auth: auth),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-change-password')));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20 && finder.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsNothing);
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}
