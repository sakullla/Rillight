import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:dio/dio.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/plex/plex_client.dart';

// Promoted from the independent T6 desktop consumer review reproduction.
void main() {
  for (final override in [false, true]) {
    testWidgets(
      'desktop Plex filter uses actual source capabilities, override=$override',
      (tester) async {
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) => handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'MediaContainer': {
                      'Metadata': [],
                      'size': 0,
                      'totalSize': 0,
                    },
                  },
                ),
              ),
            ),
          );
        final client =
            PlexClient(
              device: const ClientDeviceInfo(
                clientName: 'test',
                deviceName: 'test',
                deviceId: 'test',
                version: 'test',
              ),
              dio: dio,
            )..attachSession(
              baseUrl: Uri.parse('http://fake.invalid'),
              accessToken: 'synthetic',
              userId: '1',
            );
        // Override case deliberately retains an Emby active auth client.
        final auth = AuthController.memory(client: override ? null : client);
        const page = CupertinoPageScaffold(
          child: ShelfGridPage(source: 'items', parentId: 'section:1'),
        );
        try {
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
              home: AuthScope(
                controller: auth,
                child: override
                    ? ShelfClientOverride(client: client, child: page)
                    : page,
              ),
              builder: (context, child) => ui.AppUiTheme(
                data: AppUiTheme.of(context).brightness == Brightness.dark
                    ? ui.AppUiTheme.dark()
                    : ui.AppUiTheme.light(),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          );
          await settle(tester);
          await tester.tap(find.byKey(gridFilterMenuKey));
          await settle(tester);
          await tester.tap(
            find.byKey(const Key('catalog-grid-filter-section-watch')),
          );
          await settle(tester);
          expect(
            find.byKey(const Key('catalog-grid-filter-watch-IsFavorite')),
            findsNothing,
          );
          for (final filter in ['IsPlayed', 'IsUnplayed', 'IsResumable']) {
            expect(
              find.byKey(Key('catalog-grid-filter-watch-$filter')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          auth.dispose();
          dio.close(force: true);
        }
      },
      tags: ['integration'],
    );
  }
}
