import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import '../helpers/server_access_fixture.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';
import 'server_ui_harness.dart';

void main() {
  testWidgets(
    'protected server editor changes lines and signs out only that account without entering its content',
    (tester) async {
      const device = ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'server-management',
        version: 'test',
      );
      final primary = FakeEmbyServer();
      final secondary = FakeEmbyServer(
        baseUrl: Uri.parse('http://line-two.test'),
      );
      final third = FakeEmbyServer(
        baseUrl: Uri.parse('http://line-three.test'),
      );
      final other = FakeEmbyServer(
        serverId: 'other-server',
        baseUrl: Uri.parse('http://other.test'),
      );
      final adapter = FakeEmbyAdapter([primary, secondary, third, other]);
      EmbyClient client() =>
          EmbyClient(device: device, dio: dioForFakeEmby(adapter));
      final credentials = MemoryCredentialStore();
      final auth = AuthController(
        serverAccess: TestServerAccessController(),
        client: client(),
        credentials: credentials,
        servers: MemoryServerListStore(),
        providerClientFactory: (_) => client(),
      );
      late String id, otherId;
      await tester.runAsync(() async {
        await auth.connect(
          address: other.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        otherId = auth.session!.server.id;
        final login = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
        );
        await login.password(
          primary.baseUrl.toString(),
          'alice',
          'correct-horse',
        );
        expect(login.failure, isNull);
        id = login.sourceId!;
        await login.finish();
        login.dispose();
        await auth.switchTo(otherId);
        await auth.serverAccess.setPassword(
          id,
          '1234',
          '1234',
          persistReference: (ref) =>
              auth.sources.persistProtectionReference(id, ref),
        );
      });
      secondary.issuedTokens.addAll(primary.issuedTokens);
      third.issuedTokens.addAll(primary.issuedTokens);
      addTearDown(auth.dispose);
      await pumpServerSelection(tester, auth);
      Future<void> edit() async {
        await openServerEditor(tester, id);
        await tester.enterText(
          find.byKey(const Key('server-unlock-password')),
          '1234',
        );
        await serverUiTap(tester, const Key('server-unlock-submit'));
        expect(auth.serverAccess.allows(id), isFalse);
        expect(auth.session!.server.id, otherId);
      }

      await edit();
      await serverUiTap(tester, const Key('server-editor-add-line'));
      await tester.enterText(
        find.byKey(const Key('server-line-address')),
        secondary.baseUrl.toString(),
      );
      await serverUiTap(tester, const Key('server-line-done'));
      expect(auth.sources.server(id).lines, hasLength(1));
      await serverUiTap(tester, const Key('server-editor-save'));
      var source = auth.sources.server(id);
      expect(source.lines, hasLength(2));
      final added = source.lines.last.id;
      await edit();
      await serverUiTap(tester, Key('server-editor-line-$added'));
      await tester.enterText(
        find.byKey(const Key('server-line-address')),
        third.baseUrl.toString(),
      );
      await serverUiTap(tester, const Key('server-line-done'));
      await serverUiTap(tester, const Key('server-editor-save'));
      expect(
        auth.sources.server(id).lines.last.address,
        third.baseUrl.toString(),
      );
      expect(auth.session!.server.id, otherId);
      await edit();
      await serverUiTap(tester, Key('server-editor-line-more-$added'));
      await tester.tap(find.text('移除这条线路'));
      await settle(tester);
      expect(auth.sources.server(id).lines, hasLength(2));
      await serverUiTap(tester, const Key('server-editor-save'));
      source = auth.sources.server(id);
      expect(source.lines, hasLength(1));
      await edit();
      await serverUiTap(tester, const Key('server-editor-logout'));
      await serverUiTap(tester, const Key('server-logout-confirm'));
      expect(await credentials.read(id), isNull);
      expect(await credentials.read(otherId), isNotNull);
      expect(auth.sources.project(), hasLength(2));
      expect(auth.session!.server.id, otherId);
      await tester.tap(find.text('open-servers'));
      await settle(tester);
      await serverUiTap(tester, Key('server-more-$id'));
      await serverUiTap(tester, Key('server-action-remove-$id'));
      // Removing a configuration has a distinct explicit confirmation.
      await serverUiTap(tester, const Key('server-remove-confirm'));
      expect(auth.sources.project().map((s) => s.id), [otherId]);
      expect(auth.savedServers.map((s) => s.id), [otherId]);
      expect(auth.session!.server.id, otherId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
