import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../helpers/synthetic_source_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-browsing-polish',
  version: '0.1.0',
);

double _contrast(Color a, Color b) {
  final values = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

double _channelDistance(Color a, Color b) {
  final dr = a.r - b.r;
  final dg = a.g - b.g;
  final db = a.b - b.b;
  return dr * dr + dg * dg + db * db;
}

void main() {
  setUp(isolateImageCache);

  test('shipped theme pairs keep body text at least 4.5:1', () {
    final themes = [
      AppTheme.light(),
      AppTheme.dark(),
      AppTheme.tvLight(),
      AppTheme.tvDark(),
      AppTheme.phoneLight(),
      AppTheme.phoneDark(),
    ];
    for (final theme in themes) {
      final scheme = theme.colorScheme;
      for (final surface in [
        scheme.surface,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
      ]) {
        expect(
          _contrast(scheme.onSurface, surface),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness} onSurface',
        );
        expect(
          _contrast(scheme.onSurfaceVariant, surface),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness} onSurfaceVariant',
        );
      }
    }
  });

  test('artwork color tints detail surfaces without replacing them', () {
    for (final brightness in Brightness.values) {
      final base = brightness == Brightness.dark
          ? AppTheme.dark().colorScheme
          : AppTheme.light().colorScheme;
      final artwork = ColorScheme.fromSeed(
        seedColor: const Color(0xFFE23B3B),
        brightness: brightness,
      );
      final composed = composeContentScheme(base, artwork);
      expect(
        _channelDistance(composed.surface, base.surface),
        lessThan(_channelDistance(composed.surface, artwork.primary)),
      );
      expect(
        _contrast(composed.onSurface, composed.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(composed.onSurfaceVariant, composed.surface),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets(
    'signed-in browsing keeps play dominant and does not restate a shown status',
    (tester) async {
      final server = FakeEmbyServer();
      final adapter = FakeEmbyAdapter([server]);
      final auth = SyntheticSourceAuth(
        adapter: adapter,
        device: _device,
        libraryIds: {'view-movies', 'view-tv'},
      );
      await tester.runAsync(() {
        return auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      final runtime = (await tester.runAsync(auth.runtime))!;
      final app = RillightApp(
        auth: auth,
        playerBindings: PlayerBindings(runtime: runtime),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        await tester.runAsync(
          () => runtime.history.close().timeout(const Duration(seconds: 5)),
        );
        auth.dispose();
      });
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(app);
        await settle(tester);

        expect(find.text('播放'), findsWidgets);
        final resume = find.byKey(CatalogKeys.resumeProgress);
        expect(resume, findsWidgets);
        await tester.ensureVisible(resume.first);
        await tester.pump();
        expect(find.textContaining('已看 40%'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('已看 40%')), findsWidgets);

        app.router.go('/library/view-movies');
        await tester.pumpWidget(app);
        await settle(tester);
        expect(find.byType(ShelfGridPage), findsOneWidget);
        expect(find.text('Inception'), findsOneWidget);
        int itemQueries() => server.requests
            .where((request) => request.contains('/Items'))
            .length;
        final beforeCancel = itemQueries();
        await tester.tap(find.byKey(gridFilterMenuKey));
        await settle(tester);
        await tester.tap(
          find.byKey(const Key('catalog-grid-filter-section-watch')),
        );
        await settle(tester);
        await tester.tap(find.byKey(gridFilterOption('watch', 'IsPlayed')));
        await settle(tester);
        expect(itemQueries(), beforeCancel);
        expect(
          server.requests.where(
            (request) => request.contains('Filters=IsPlayed'),
          ),
          isEmpty,
        );
        await tester.tap(find.byKey(const Key('catalog-grid-filter-cancel')));
        await settle(tester);
        expect(itemQueries(), beforeCancel);
        expect(
          server.requests.where(
            (request) => request.contains('Filters=IsPlayed'),
          ),
          isEmpty,
        );
        expect(find.byKey(gridFilterPanelKey), findsNothing);
        expect(find.text('Inception'), findsOneWidget);

        await tester.tap(find.text('Inception'));
        await settle(tester);
        expect(find.byKey(PlayerKeys.open), findsOneWidget);
        expect(find.text('继续播放'), findsOneWidget);
        expect(find.byTooltip('标记已看'), findsOneWidget);
        expect(find.text('已看 40%'), findsNothing);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: find.byKey(CatalogKeys.resumeProgress),
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          closeTo(0.4, 0.001),
        );

        await tester.tap(find.byTooltip('搜索'));
        await settle(tester);
        expect(find.byType(AggregationPage), findsOneWidget);
        expect(find.text('输入片名后搜索'), findsOneWidget);
        expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
        await tester.enterText(
          find.byKey(const Key('aggregation-keyword')),
          'Inception',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await settle(tester);
        expect(
          find.descendant(
            of: find.byType(AggregationPage),
            matching: find.text('Inception'),
          ),
          findsWidgets,
        );

        app.router.go(AppRoutes.settings);
        await tester.pumpWidget(app);
        await settle(tester);
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.text('播放'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
    tags: ['integration'],
  );

  testWidgets('phone connect and desktop connect open from their start state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final phoneAuth = AuthController.memory();
    final phone = RillightApp(
      auth: phoneAuth,
      environment: PresentationEnvironment.phone,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      phone.router.dispose();
      phoneAuth.dispose();
    });
    await tester.pumpWidget(phone);
    await settle(tester);
    expect(find.byType(AndroidConnectPage), findsOneWidget);
    final submit = tester.getSize(
      find.byKey(const Key('android-connect-submit')),
    );
    expect(submit.width, greaterThanOrEqualTo(48));
    expect(submit.height, greaterThanOrEqualTo(48));

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final desktopAuth = AuthController.memory();
    final desktop = RillightApp(auth: desktopAuth);
    addTearDown(desktop.router.dispose);
    addTearDown(desktopAuth.dispose);
    await tester.pumpWidget(desktop);
    await settle(tester);
    expect(find.byType(ConnectPage), findsOneWidget);
    expect(find.byKey(ConnectFormKeys.submit), findsOneWidget);
  }, tags: ['integration']);

  testWidgets(
    'a TV card shows watched and progress once, and focus uses one ring',
    (tester) async {
      final played = const EmbyItem(
        id: 'played',
        name: '看完的一集',
        type: 'Episode',
        userData: EmbyUserData(played: true),
      );
      final resume = const EmbyItem(
        id: 'resume',
        name: '看到一半',
        type: 'Episode',
        runTimeTicks: 20 * 60 * 10000000,
        userData: EmbyUserData(
          playbackPositionTicks: 8 * 60 * 10000000,
          playedPercentage: 40,
        ),
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.tvDark(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TvStageTheme(
              child: Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: TvCard(item: played, onPressed: () {}),
                  ),
                  SizedBox(
                    width: 160,
                    child: TvCard(
                      key: const Key('resume-card'),
                      item: resume,
                      focusNode: focus,
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();

        expect(find.byType(EpisodeWatchedBadge), findsOneWidget);
        expect(find.text('已看'), findsNothing);
        expect(find.text('已看 40%'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.bySemanticsLabel('已看 40%'), findsOneWidget);

        focus.requestFocus();
        await tester.pump();
        final rings = tester
            .widgetList<AnimatedContainer>(
              find.descendant(
                of: find.byKey(const Key('resume-card')),
                matching: find.byType(AnimatedContainer),
              ),
            )
            .map((container) => container.foregroundDecoration)
            .whereType<BoxDecoration>()
            .where((decoration) => decoration.border != null);
        expect(rings, hasLength(1));
        expect(rings.single.boxShadow, isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
