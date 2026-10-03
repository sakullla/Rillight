import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);
  for (final tv in [false, true]) {
    testWidgets(
      'ended ${tv ? 'TV' : 'phone'} returns to the correct series and season',
      (tester) async {
        final server = FakeEmbyServer();
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'test',
              deviceId: 'ended-route',
              version: '1',
            ),
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final backend = FakeVideoBackend(duration: const Duration(minutes: 22));
        final router = GoRouter(
          initialLocation: '/item/origin',
          routes: [
            GoRoute(
              path: '/item/:id',
              builder: (_, state) => Scaffold(
                body: Text(
                  'item:${state.pathParameters['id']}:${state.uri.queryParameters['season']}',
                ),
              ),
            ),
            GoRoute(
              path: '/play',
              builder: (_, _) => tv
                  ? const TvPlayerPage(itemId: 'episode-friends-s1e2')
                  : MobilePlayerPage(
                      itemId: 'episode-friends-s1e2',
                      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
                    ),
            ),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 4));
          router.dispose();
          auth.dispose();
        });
        await tester.pumpWidget(
          AuthScope(
            controller: auth,
            child: PlayerScope(
              bindings: PlayerBindings(
                createBackend: () => backend,
                settingsStore: MemoryPlayerSettingsStore(),
                snapshotStore: MemoryPlaybackSessionSnapshotStore(),
              ),
              child: MaterialApp.router(
                routerConfig: router,
                theme: AppTheme.dark(),
                locale: const Locale('zh'),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        router.push('/play');
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        backend.completePlayback();
        await tester.pumpAndSettle();
        expect(find.byKey(PlayerKeys.endedViewSeries), findsOneWidget);
        await tester.tap(find.byKey(PlayerKeys.endedViewSeries));
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find
              .text('item:series-friends:season-friends-1')
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(
          find.text('item:series-friends:season-friends-1'),
          findsOneWidget,
        );
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(find.byType(TvPlayerPage), findsNothing);
      },
      tags: ['integration'],
    );
  }
}
