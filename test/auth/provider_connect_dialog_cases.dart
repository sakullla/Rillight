import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/provider_connect_dialog.dart';
import 'package:rillight/auth/server_paste_draft.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/plex/plex_client.dart';

void main() {
  testWidgets(
    'Plex pasted name and every endpoint stay editable before authorization',
    (tester) async {
      final auth = AuthController.memory();
      addTearDown(auth.dispose);
      final draft = ServerPasteDraft()
        ..serviceType = MediaServerType.plex
        ..name = '我的 Plex'
        ..lines.addAll([
          'https://first.test/prefix',
          'https://second.test:32400',
        ]);
      await tester.pumpWidget(
        CupertinoTestApp(
          home: ProviderConnectDialog(auth: auth, initialDraft: draft),
        ),
      );
      expect(
        tester
            .widget<AppTextField>(
              find.byKey(const Key('provider-display-name')),
            )
            .controller
            ?.text,
        '我的 Plex',
      );
      expect(
        tester
            .widget<AppTextField>(find.byKey(const Key('provider-address')))
            .controller
            ?.text,
        draft.lines.first,
      );
      expect(
        tester
            .widget<AppTextField>(find.byKey(const Key('provider-extra-lines')))
            .controller
            ?.text,
        draft.lines.last,
      );
      await tester.enterText(
        find.byKey(const Key('provider-address')),
        'https://edited.test/prefix',
      );
      expect(
        tester
            .widget<AppTextField>(find.byKey(const Key('provider-address')))
            .controller
            ?.text,
        'https://edited.test/prefix',
      );
      expect(auth.savedServers, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(auth.savedServers, isEmpty);
    },
    tags: ['integration'],
  );

  testWidgets('selecting Child hides Owner resources before Home exchange', (
    tester,
  ) async {
    final auth = AuthController.memory();
    Widget app() => CupertinoTestApp(
      localizationsDelegates: [
        ...[
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        ui.GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProviderConnectDialog(auth: auth),
      builder: (context, child) => ui.AppUiTheme(
        data: AppUiTheme.of(context).brightness == Brightness.dark
            ? ui.AppUiTheme.dark()
            : ui.AppUiTheme.light(),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    await tester.pumpWidget(app());
    final controller =
        tester
                .widget<ListenableBuilder>(
                  find
                      .descendant(
                        of: find.byType(ProviderConnectDialog),
                        matching: find.byType(ListenableBuilder),
                      )
                      .first,
                )
                .listenable
            as ProviderConnectController;
    const child = HomeUser(id: '2', name: 'Child', requiresPin: true);
    controller.stage = ProviderConnectStage.resources;
    controller.users = const [
      HomeUser(id: '1', name: 'Owner', requiresPin: false),
      child,
    ];
    AuthorizedServerResource resource(String id, {String? homeUserId}) =>
        AuthorizedServerResource(
          serviceType: MediaServerType.plex,
          server: PublicServerInfo(id: id, serverName: id, version: 'test'),
          user: MediaUser(
            id: homeUserId ?? '1',
            name: homeUserId == null ? 'Owner' : 'Child',
          ),
          resourceCredentialRef: 'synthetic-$id',
          homeUserId: homeUserId,
          owned: id == 'owned',
          connections: [
            ServerConnection(
              Uri.parse('https://$id.invalid'),
              ServerConnectionKind.remote,
            ),
          ],
        );
    controller.resources = [resource('owned'), resource('shared')];
    final resourceButtons = find.byWidgetPredicate(
      (widget) =>
          widget is ui.AppButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'provider-resource-',
          ),
    );
    await tester.pumpWidget(app());
    await settle(tester);
    expect(resourceButtons, findsNWidgets(2));
    await tester.tap(find.byKey(const Key('provider-home-user')));
    await settle(tester);
    await tester.tap(find.text('Child').last);
    await settle(tester);
    // The controller still holds Owner results; the pending selection must
    // make both owned and shared connections unavailable immediately.
    expect(controller.resources, hasLength(2));
    expect(resourceButtons, findsNothing);
    expect(find.byKey(const Key('provider-home-pin')), findsOneWidget);
    // Only results carrying the newly authorized identity can reappear.
    controller.resources = [resource('shared', homeUserId: child.id)];
    await tester.pumpWidget(app());
    await settle(tester);
    expect(resourceButtons, findsOneWidget);
    expect(find.textContaining('shared · Child'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'Plex sort panel hides unsupported meanings and resets to date added',
    (tester) async {
      final plex = PlexClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'sort-panel',
          version: 'test',
        ),
      );
      CatalogSort? applied;
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
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: ui.AppButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  builder: (_) => AppModalFrame(
                    child: LibraryFilterPanel(
                      initial: const ShelfFilters(),
                      sort: CatalogSort.name,
                      capabilities: plex.capabilities,
                      onApply: (_, sort) => applied = sort,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.ensureVisible(
        find.byKey(const Key('catalog-grid-filter-section-sort')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('catalog-grid-filter-section-sort')),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('catalog-grid-filter-sort-DateLastContentAdded')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('catalog-grid-filter-sort-DateCreated')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('catalog-grid-filter-clear')));
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
      await tester.tap(find.byKey(const Key('catalog-grid-filter-apply')));
      await settle(tester);
      expect(applied, CatalogSort.dateCreated);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV back cancels the text editor and authorization without saving a server',
    (tester) async {
      final auth = AuthController.memory();
      await tester.pumpWidget(
        PresentationScope(
          environment: PresentationEnvironment.tv,
          child: CupertinoTestApp(
            localizationsDelegates: [
              ...[
                AppLocalizations.delegate,
                ...GlobalCupertinoLocalizations.delegates,
              ],
              ui.GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: ui.AppButton(
                  onPressed: () => showProviderConnect(context, auth),
                  child: const Text('open'),
                ),
              ),
            ),
            builder: (context, child) => ui.AppUiTheme(
              data: AppUiTheme.of(context).brightness == Brightness.dark
                  ? ui.AppUiTheme.dark()
                  : ui.AppUiTheme.light(),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('provider-username')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('tv-input-editor')),
        'private-name',
      );
      Navigator.of(tester.element(find.byKey(const Key('tv-input-editor'))))
          .pop();
      await settle(tester);
      await tester.tap(find.byKey(const Key('provider-cancel')));
      await settle(tester);
      expect(auth.savedServers, isEmpty);
      expect(find.byType(ProviderConnectDialog), findsNothing);
      expect(find.byKey(const Key('tv-input-editor')), findsNothing);
      expect(find.text('private-name'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('360dp dialog exposes all services without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory();
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
        home: ProviderConnectDialog(auth: auth),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('provider-type')));
    await settle(tester);
    await tester.tap(find.text('Plex').last);
    await settle(tester);
    expect(find.byKey(const Key('provider-authorize')), findsOneWidget);
    expect(find.byKey(const Key('provider-password')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('TV uses remote inputs instead of inline keyboard fields', (
    tester,
  ) async {
    final auth = AuthController.memory();
    await tester.pumpWidget(
      PresentationScope(
        environment: PresentationEnvironment.tv,
        child: CupertinoTestApp(
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProviderConnectDialog(auth: auth),
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(TvInput), findsNWidgets(4));
    expect(find.byType(ui.AppTextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
