import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import '../helpers/image_cache_fixture.dart';
import '../emby/fake_emby_server.dart';
import 'tv_server_test_helpers.dart';

import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/tv_server_selection_page.dart';
import 'package:rillight/auth/tv_server_editor_page.dart';
import 'package:rillight/auth/tv_line_selection_page.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

Future<AuthController> setupTv(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final a = FakeEmbyServer(
    serverId: 'tv-a',
    baseUrl: Uri.parse('http://tv-a.test:8096'),
  );
  final b = FakeEmbyServer(
    serverId: 'tv-b',
    baseUrl: Uri.parse('http://tv-b.test:8096'),
  );
  final auth = AuthController.memory(
    client: EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'TV',
        deviceId: 'tv-management',
        version: '1',
      ),
      dio: dioForFakeEmby(FakeEmbyAdapter([a, b])),
    ),
  );
  await tester.runAsync(() async {
    for (final server in [a, b]) {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    }
    await auth.switchTo(auth.savedServers.first.id);
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
    auth.dispose();
  });
  await tester.pumpWidget(app);
  await settle(tester);
  await tvPress(tester, const Key('tv-nav-user'));
  expect(find.byType(TvServerSelectionPage), findsOneWidget);
  return auth;
}

void main() {
  setUp(isolateImageCache);
  testWidgets(
    'TV home entry exposes separate D-pad body line and more targets',
    (tester) async {
      final auth = await setupTv(tester);
      final id = auth.savedServers.first.id;
      final body = tvTarget(tester, Key('server-enter-$id'));
      body.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(tvTarget(tester, Key('server-lines-$id')).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.byType(TvLineSelectionPage), findsOneWidget);
      expect(tvTarget(tester, const Key('server-line-auto')).hasFocus, isTrue);
      await tvBack(tester);
      expect(tvTarget(tester, Key('server-lines-$id')).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(tvTarget(tester, Key('server-more-$id')).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      await tvPress(tester, const Key('server-more-edit'));
      expect(find.byType(TvServerEditorPage), findsOneWidget);
      await tvBack(tester);
      expect(tvTarget(tester, Key('server-more-$id')).hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'TV editor keeps cancelled drafts and saves name with remote keyboard',
    (tester) async {
      final auth = await setupTv(tester);
      final id = auth.savedServers.first.id;
      final old = auth.savedServers.first.displayName;
      await tvOpenEditor(tester, id);
      await tvEdit(tester, const Key('server-editor-name'), '客厅影院');
      await tvPress(tester, const Key('server-editor-password'));
      await tvBack(tester);
      expect(find.text('客厅影院'), findsOneWidget);
      await tvBack(tester);
      expect(auth.sources.server(id).displayName, old);
      await tvOpenEditor(tester, id);
      await tvEdit(tester, const Key('server-editor-name'), '电视影院');
      await tvPress(tester, const Key('server-editor-save'));
      expect(auth.sources.server(id).displayName, '电视影院');
      expect(auth.session?.server.id, id);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('TV remote sorts and removes only after local confirmation', (
    tester,
  ) async {
    final auth = await setupTv(tester);
    final id = auth.savedServers.last.id;
    final current = auth.session!.server.id;
    await tvPress(tester, Key('server-more-$id'));
    await tvPress(tester, const Key('server-more-up'));
    expect(auth.savedServers.first.id, id);
    expect(tvTarget(tester, Key('server-more-$id')).hasFocus, isTrue);
    await tvPress(tester, Key('server-more-$id'));
    await tvPress(tester, const Key('server-more-remove'));
    await tvBack(tester);
    expect(auth.savedServers, hasLength(2));
    await tvPress(tester, Key('server-more-$id'));
    await tvPress(tester, const Key('server-more-remove'));
    await tvPress(tester, const Key('server-remove-confirm'));
    expect(auth.savedServers, hasLength(1));
    expect(auth.session!.server.id, current);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'TV locked management requires password without entering or switching server',
    (tester) async {
      final auth = await setupTv(tester);
      final id = auth.savedServers.last.id;
      final current = auth.session!.server.id;
      await tester.runAsync(() async {
        await auth.serverAccess.setPassword(
          id,
          'entry',
          'entry',
          persistReference: (ref) =>
              auth.sources.persistProtectionReference(id, ref),
        );
        await auth.refreshServers();
      });
      await settle(tester);
      await tvOpenEditor(tester, id);
      expect(find.byKey(const Key('server-unlock-password')), findsOneWidget);
      await tvEdit(tester, const Key('server-unlock-password'), 'entry');
      await tester.runAsync(() async {
        await tvPress(tester, const Key('server-unlock-submit'));
        for (
          var i = 0;
          i < 300 && find.byType(TvServerEditorPage).evaluate().isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await settle(tester);
      expect(find.byType(TvServerEditorPage), findsOneWidget);
      expect(auth.serverAccess.allows(id), isFalse);
      expect(auth.session!.server.id, current);
      await tvBack(tester);
      expect(tvTarget(tester, Key('server-more-$id')).hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('TV search clears and add provider flow cancels with Back', (
    tester,
  ) async {
    final auth = await setupTv(tester);
    await tvEdit(tester, const Key('server-search'), '没有这台服务器');
    expect(find.text('没有找到服务器'), findsOneWidget);
    await tvPress(tester, const Key('server-search-clear'));
    expect(
      find.byKey(Key('server-enter-${auth.savedServers.first.id}')),
      findsOneWidget,
    );
    await tvPress(tester, const Key('server-add'));
    expect(find.text('Jellyfin'), findsWidgets);
    expect(find.text('Plex'), findsWidgets);
    await tvPress(tester, const Key('provider-type-jellyfin'));
    expect(find.byKey(const Key('provider-authorize')), findsOneWidget);
    await tvPress(tester, const Key('provider-type-plex'));
    expect(find.byKey(const Key('provider-authorize')), findsOneWidget);
    await tvPress(tester, const Key('provider-type-emby'));
    expect(find.byKey(const Key('provider-password-submit')), findsOneWidget);
    await tvBack(tester);
    expect(auth.savedServers, hasLength(2));
    expect(tvTarget(tester, const Key('server-add')).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'TV password mismatch stays in draft and cancel preserves access',
    (tester) async {
      final auth = await setupTv(tester);
      final id = auth.savedServers.first.id;
      await tvOpenEditor(tester, id);
      await tvPress(tester, const Key('server-editor-password'));
      expect(
        tvTarget(tester, const Key('server-password-new')).hasFocus,
        isTrue,
      );
      await tvEdit(tester, const Key('server-password-new'), 'first');
      await tvEdit(tester, const Key('server-password-confirm'), 'second');
      await tvPress(tester, const Key('server-password-done'));
      expect(find.text('两次密码不一致'), findsOneWidget);
      expect(auth.serverAccess.isProtected(id), isFalse);
      await tvBack(tester);
      expect(
        tvTarget(tester, const Key('server-editor-password')).hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('TV server body enters content directly and closes selection', (
    tester,
  ) async {
    final auth = await setupTv(tester);
    final id = auth.savedServers.last.id;
    await tvPress(tester, Key('server-enter-$id'));
    expect(auth.session!.server.id, id);
    expect(find.byType(TvServerSelectionPage), findsNothing);
    expect(find.byKey(const Key('tv-nav-user')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets(
    'TV removing current server returns to a valid connection entry',
    (tester) async {
      final auth = await setupTv(tester);
      final id = auth.session!.server.id;
      await tvPress(tester, Key('server-more-$id'));
      await tvPress(tester, const Key('server-more-remove'));
      await tvPress(tester, const Key('server-remove-cancel'));
      expect(auth.session!.server.id, id);
      await tvPress(tester, Key('server-more-$id'));
      await tvPress(tester, const Key('server-more-remove'));
      await tvPress(tester, const Key('server-remove-confirm'));
      expect(auth.savedServers.any((s) => s.id == id), isFalse);
      expect(find.byKey(const Key('tv-connect-servers')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
