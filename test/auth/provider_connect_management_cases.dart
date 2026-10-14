import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import '../helpers/region_access_fixture.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_management.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';

void main() {
  testWidgets(
    'private management adds and removes lines then logs out and deletes only its source',
    (tester) async {
      const device = ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'private-management',
        version: 'test',
      );
      final primary = FakeEmbyServer();
      final secondary = FakeEmbyServer(
        baseUrl: Uri.parse('http://line-two.test'),
      );
      final third = FakeEmbyServer(
        baseUrl: Uri.parse('http://line-three.test'),
      );
      final adapter = FakeEmbyAdapter([primary, secondary, third]);
      EmbyClient client() =>
          EmbyClient(device: device, dio: dioForFakeEmby(adapter));
      final credentials = MemoryCredentialStore();
      final auth = AuthController(
        regionAccess: TestRegionAccessController(),
        client: client(),
        credentials: credentials,
        servers: MemoryServerListStore(),
        providerClientFactory: (_) => client(),
      );
      late String id;
      await tester.runAsync(() async {
        await auth.setPrivatePin('1234', '1234');
        await auth.regionAccess.unlock('1234');
        final login = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
          region: AccessRegion.private,
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
      });
      await tester.pumpWidget(
        CupertinoTestApp(
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SourceManagement(auth: auth, region: AccessRegion.private),
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await settle(tester);
      Future<void> reveal(Finder finder) async {
        final scroll = find.byType(Scrollable).first;
        tester.state<ScrollableState>(scroll).position.jumpTo(0);
        await settle(tester);
        await tester.scrollUntilVisible(finder, 150, scrollable: scroll);
        await settle(tester);
      }

      await reveal(find.byKey(Key('source-add-line-$id')));
      await tester.tap(find.byKey(Key('source-add-line-$id')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('source-text-value')),
        secondary.baseUrl.toString(),
      );
      await tester.tap(find.widgetWithText(ui.AppButton, '保存'));
      await settle(tester);
      var source = auth.sources.project(AccessRegion.private).single;
      expect(source.lines, hasLength(2));
      expect(auth.session, isNull);
      final added = source.lines.last.id;
      await reveal(find.byKey(Key('source-edit-line-$id-$added')));
      await tester.tap(find.byKey(Key('source-edit-line-$id-$added')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('source-text-value')),
        third.baseUrl.toString(),
      );
      await tester.tap(find.widgetWithText(ui.AppButton, '保存'));
      await settle(tester);
      expect(
        auth.sources.project(AccessRegion.private).single.lines.last.address,
        third.baseUrl.toString(),
      );
      expect(auth.session, isNull);

      await reveal(find.byKey(Key('source-delete-line-$id-$added')));
      await tester.tap(find.byKey(Key('source-delete-line-$id-$added')));
      await settle(tester);
      final l = AppLocalizations.of(
        tester.element(find.byType(SourceManagement)),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ui.AppDialog),
          matching: find.ancestor(
            of: find.text(l.deleteLine),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ui.AppButton &&
                  widget.variant == ui.AppButtonVariant.filled,
            ),
          ),
        ),
      );
      await settle(tester);
      source = auth.sources.project(AccessRegion.private).single;
      expect(source.lines, hasLength(1));
      await reveal(find.byKey(Key('source-logout-$id')));
      await tester.tap(find.byKey(Key('source-logout-$id')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ui.AppDialog),
          matching: find.ancestor(
            of: find.text(l.logout),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ui.AppButton &&
                  widget.variant == ui.AppButtonVariant.filled,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(await credentials.read(id), isNull);
      expect(auth.sources.project(AccessRegion.private), hasLength(1));
      await reveal(find.byKey(Key('source-delete-$id')));
      await tester.tap(find.byKey(Key('source-delete-$id')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ui.AppDialog),
          matching: find.ancestor(
            of: find.text(l.deleteServer),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ui.AppButton &&
                  widget.variant == ui.AppButtonVariant.filled,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(auth.sources.project(AccessRegion.private), isEmpty);
      expect(auth.savedServers, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
