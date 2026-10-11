import 'package:rillight/auth/source_management.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/provider_connect_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/plex/plex_client.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';

import '../helpers/image_cache_fixture.dart';
import '../plex/fake_plex.dart';

class _RealHttp extends HttpOverrides {}

final _clients = <Dio>[];

Dio _dio() {
  final dio = Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()),
    );
  _clients.add(dio);
  return dio;
}

void main() {
  setUp(isolateImageCache);
  testWidgets(
    'selected Plex Home authorization survives real app login redirect',
    (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const device = ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'phone',
        deviceId: 'test-device',
        version: 'test',
      );
      final fake = FakePlex()
        ..imageBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
      final credentials = MemoryCredentialStore();
      final cloud = CloudCredentialStore(credentials);
      late AuthController auth;
      final accountDio = _dio();
      await tester.runAsync(() async {
        await fake.start();
        final plex = PlexAuthentication(
          device: device,
          dio: accountDio,
          accountUrl: fake.url,
          homeUrl: fake.url,
          readCredential: cloud.readCredential,
          writeCredential: cloud.writeCredential,
          deleteCredential: cloud.deleteCredential,
        );
        auth = AuthController(
          client: PlexClient(device: device, dio: _dio()),
          credentials: credentials,
          servers: MemoryServerListStore(),
          plexAuthentication: plex,
          providerClientFactory: (_) => PlexClient(device: device, dio: _dio()),
        );
        final login = ProviderConnectController(auth: auth)
          ..reset(MediaServerType.plex);
        try {
          fake.authorized = true;
          await login.authorize('');
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (login.stage != ProviderConnectStage.resources &&
              login.failure == null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(login.failure, isNull);
          final resource = login.resources.single;
          await login.selectResource(resource, resource.connections.first);
          await login.finish();
          expect(auth.session?.userId, '1');
        } finally {
          login.dispose();
        }
      });
      final oldClient = auth.client;
      final oldSource = await tester.runAsync(
        () => auth.sources.ensureSession(auth.session!.server.id),
      );
      final oldPermit = auth.sources.permit(
        oldSource!.account,
        sessionOnly: true,
      );
      expect(oldPermit.isValid, isTrue);
      expect(oldClient.accessToken, 'owner-resource');
      final homeGate = Completer<void>();
      accountDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            if (request.uri.path.endsWith('/api/home/users')) {
              await homeGate.future;
            }
            handler.next(request);
          },
        ),
      );
      final app = RillightApp(
        auth: auth,
        environment: PresentationEnvironment.phone,
        playerBindings: PlayerBindings(
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
          settingsStore: MemoryPlayerSettingsStore(),
        ),
      );
      app.router.go(AppRoutes.mine);
      try {
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('phone-provider-management')),
          findsNothing,
        );
        final manage = find.byType(Scaffold).first;
        final catalog = CatalogScope.of(tester.element(manage));
        await tester.runAsync(catalog.reload);
        expect(
          catalog.latestMovies.error,
          isNull,
          reason: 'Plex latest movies must use a supported provider sort',
        );
        expect(
          fake.requests.where(
            (request) =>
                request.path == '/library/all' &&
                request.query['type'] == '1' &&
                request.token == 'owner-resource',
          ),
          isNotEmpty,
          reason: 'Old media must be loaded through the real owner resource',
        );
        expect(
          catalog.latestMovies.items,
          isNotEmpty,
          reason: 'The old account has populated background catalog content',
        );
        app.router.go(AppRoutes.home);
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (find.text('Synthetic film').evaluate().isNotEmpty) break;
        }
        expect(
          find.text('Synthetic film'),
          findsWidgets,
          reason: 'The previous identity has rendered media before revocation',
        );
        app.router.go(AppRoutes.mine);
        await tester.pumpAndSettle();
        showSourceManagement(tester.element(manage));
        await tester.pumpAndSettle();
        final home = find.text('切换 Plex Home 用户');
        await tester.ensureVisible(home);
        await tester.tap(home);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          auth.session,
          isNull,
          reason: 'Old owner authority is revoked before Home IO',
        );
        expect(oldPermit.isValid, isFalse);
        expect(oldClient.accessToken, isNull);
        expect(auth.client.accessToken, isNull);
        await expectLater(
          oldPermit.dispatch((client) => client.getViews()),
          throwsStateError,
        );
        expect(catalog.resume.items, isEmpty);
        expect(catalog.nextUp.items, isEmpty);
        expect(catalog.latestMovies.items, isEmpty);
        expect(catalog.latestSeries.items, isEmpty);
        expect(catalog.libraries, isEmpty);
        expect(find.text('Synthetic film'), findsNothing);
        expect(find.text('Other film'), findsNothing);

        expect(
          find.byType(ProviderConnectDialog),
          findsOneWidget,
          reason: 'Login redirect must preserve the authorization dialog',
        );
        homeGate.complete();
        for (
          var i = 0;
          i < 40 &&
              find.byKey(const Key('provider-home-user')).evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('provider-home-user')), findsOneWidget);
        expect(
          find.byKey(const Key('provider-cancel')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        Future<void> waitUntil(bool Function() ready) async {
          for (var i = 0; i < 80 && !ready(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(ready(), isTrue);
        }

        await tester.tap(find.byKey(const Key('provider-home-user')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Child').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('provider-home-pin')),
          'wrong',
        );
        await tester.ensureVisible(
          find.byKey(const Key('provider-home-switch')),
        );
        await tester.tap(find.byKey(const Key('provider-home-switch')));
        await waitUntil(
          () => find.byKey(const Key('provider-error')).evaluate().isNotEmpty,
        );
        expect(auth.session, isNull);
        expect(oldPermit.isValid, isFalse);
        expect(
          find.descendant(
            of: find.byType(ProviderConnectDialog),
            matching: find.byType(OutlinedButton),
          ),
          findsNothing,
        );
        await tester.enterText(
          find.byKey(const Key('provider-home-pin')),
          '1234',
        );
        await tester.ensureVisible(
          find.byKey(const Key('provider-home-switch')),
        );
        await tester.tap(find.byKey(const Key('provider-home-switch')));
        await waitUntil(
          () => find.byType(OutlinedButton).evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.byType(OutlinedButton).first);
        await tester.tap(find.byType(OutlinedButton).first);
        await waitUntil(
          () =>
              find.byKey(const Key('provider-finish')).evaluate().isNotEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        await tester.tap(find.byKey(const Key('provider-finish')));
        await waitUntil(
          () =>
              auth.session?.userId == '2' &&
              find.byType(ProviderConnectDialog).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(auth.session?.accessToken, 'child-resource');
        expect(
          auth.sources.project(AccessRegion.ordinary).single.libraryIds,
          isEmpty,
        );
        // Opening Home again revokes Child immediately; cancelling leaves the
        // ordinary selected session empty and allows the login redirect.
        await tester.ensureVisible(find.text('切换 Plex Home 用户'));
        await tester.tap(find.text('切换 Plex Home 用户'));
        await waitUntil(
          () =>
              find.byKey(const Key('provider-home-user')).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('provider-cancel')));
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (w) => w is ProviderConnectDialog && !w.inline,
          ),
          findsNothing,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(auth.session, isNull);
        expect(
          app.router.routeInformationProvider.value.uri.path,
          AppRoutes.connect,
        );
      } finally {
        if (!homeGate.isCompleted) homeGate.complete();
        await tester.pumpWidget(const SizedBox());
        app.router.dispose();
        auth.dispose();
        for (final dio in _clients) {
          dio.close(force: true);
        }
        _clients.clear();
        await tester.runAsync(fake.close);
      }
    },
    tags: ['integration'],
  );
}
