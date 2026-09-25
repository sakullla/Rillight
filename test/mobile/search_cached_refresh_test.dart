import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/search/mobile_search_page.dart';
import 'package:rillight/search/search_page.dart';
import 'package:rillight/search/tv_search_page.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

enum _Surface { phone, tv, desktop }

void main() {
  setUp(isolateImageCache);

  for (final surface in _Surface.values) {
    testWidgets(
      '${surface.name} keeps cached search visible through refresh failure',
      (tester) async {
        tester.view.physicalSize = Size(
          surface == _Surface.phone ? 360 : 1280,
          800,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final server = FakeEmbyServer(
          items: [
            FakeEmbyItem(id: 'cached-film', name: 'Film Cached', type: 'Movie'),
          ],
        );
        final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'search-refresh',
              deviceId: 'search-refresh',
              version: '1',
            ),
            dio: dio,
          ),
        );
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final cache = CatalogCache()..debugSetDiskStore(null);
        final catalog = CatalogController(auth: auth, cache: cache);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          catalog.dispose();
          auth.dispose();
        });
        await tester.runAsync(
          () => cache.fetch(
            auth.client,
            catalogSearchRequest(
              userId: auth.client.userId!,
              searchTerm: 'Film',
              startIndex: 0,
            ),
          ),
        );
        server.items = [
          FakeEmbyItem(id: 'live-film', name: 'Film Live', type: 'Movie'),
        ];
        server.searchStatus = 503;
        final requested = Completer<void>();
        final release = Completer<void>();
        var held = false;
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (!held &&
                  options.uri.queryParameters['SearchTerm'] == 'Film') {
                held = true;
                requested.complete();
                await release.future;
              }
              handler.next(options);
            },
          ),
        );

        final page = switch (surface) {
          _Surface.phone => const MobileSearchPage(),
          _Surface.tv => const TvSearchPage(),
          _Surface.desktop => const SearchPage(),
        };
        await tester.pumpWidget(
          AuthScope(
            controller: auth,
            child: CatalogScope(
              controller: catalog,
              child: MaterialApp(
                theme: AppTheme.dark(),
                locale: const Locale('zh'),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                home: Scaffold(body: page),
              ),
            ),
          ),
        );
        if (surface == _Surface.tv) {
          await tester.tap(find.byType(TvInput));
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('tv-input-editor')),
            'Film',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
        } else {
          await tester.enterText(find.byType(TextField).first, 'Film');
          await tester.testTextInput.receiveAction(TextInputAction.search);
        }
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (requested.isCompleted &&
              find.text('Film Cached').evaluate().isNotEmpty) {
            break;
          }
        }
        expect(requested.isCompleted, isTrue);
        expect(find.text('Film Cached'), findsOneWidget);
        final refreshKey = switch (surface) {
          _Surface.phone => const Key('mobile-search-refreshing'),
          _Surface.tv => const Key('tv-search-refreshing'),
          _Surface.desktop => const Key('search-refreshing'),
        };
        expect(find.byKey(refreshKey), findsOneWidget);

        release.complete();
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (find.byKey(refreshKey).evaluate().isEmpty) break;
        }
        expect(find.byKey(refreshKey), findsNothing);
        expect(find.text('Film Cached'), findsOneWidget);
        expect(find.text('Film Live'), findsNothing);
        final failureKey = switch (surface) {
          _Surface.phone => const Key('mobile-search-refresh-failure'),
          _Surface.tv => const Key('tv-search-refresh-failure'),
          _Surface.desktop => SearchPage.refreshRetryKey,
        };
        expect(find.byKey(failureKey), findsOneWidget);

        server.searchStatus = null;
        final retry = switch (surface) {
          _Surface.tv => find.descendant(
            of: find.byKey(failureKey),
            matching: find.byType(TvAction),
          ),
          _Surface.phone => find.byKey(
            const Key('mobile-search-refresh-retry'),
          ),
          _Surface.desktop => find.byKey(SearchPage.refreshRetryKey),
        };
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(find.text('Film Live'), findsOneWidget);
        expect(find.text('Film Cached'), findsNothing);
        expect(find.byKey(failureKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }
}
