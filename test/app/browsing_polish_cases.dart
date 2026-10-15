import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
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

const _device = ClientDeviceInfo(
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

bool _leansSakura(Color color) => color.r > color.b && color.b > color.g;

bool _isSakuraAccent(Color color) =>
    _leansSakura(color) && color.r - color.g >= 0.25;

bool _leansBluePurple(Color color) => color.b > color.r && color.r > color.g;

bool _isWarmGold(Color color) =>
    color.r > color.g && color.g > color.b && color.g - color.b >= 0.12;

bool _isRed(Color color) =>
    color.r > color.g &&
    color.g >= color.b &&
    color.r - color.b >= 0.35 &&
    color.g - color.b < 0.12;

bool _tinted(Color color) {
  final channels = [color.r, color.g, color.b]..sort();
  return channels.last - channels.first >= 0.03;
}

List<Color> _toneColors(Tones tones) => [
  tones.base,
  tones.surfaceLowest,
  tones.surfaceLow,
  tones.surface,
  tones.surfaceHigh,
  tones.surfaceHighest,
  tones.surfaceBright,
  tones.onSurface,
  tones.onSurfaceVariant,
  tones.outline,
  tones.outlineVariant,
  tones.accent,
  tones.onAccent,
  tones.accentContainer,
  tones.onAccentContainer,
  tones.secondary,
  tones.onSecondary,
  tones.secondaryContainer,
  tones.onSecondaryContainer,
  tones.tertiary,
  tones.onTertiary,
  tones.tertiaryContainer,
  tones.onTertiaryContainer,
  tones.error,
  tones.onError,
  tones.errorContainer,
  tones.onErrorContainer,
  tones.inverseSurface,
  tones.onInverseSurface,
  tones.inversePrimary,
  tones.scrim,
];

void main() {
  setUp(isolateImageCache);

  test('shipped theme pairs keep body text at least 4.5:1', () {
    final themes = [
      AppUiTheme.light(),
      AppUiTheme.dark(),
      AppUiTheme.tvLight(),
      AppUiTheme.tvDark(),
      AppUiTheme.phoneLight(),
      AppUiTheme.phoneDark(),
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

  test('phone themes use sakura and blue-purple while desktop and TV stay', () {
    expect(
      _toneColors(AppPalette.darkTones),
      _toneColors(
        const Tones(
          base: Color(0xFF151A28),
          surfaceLowest: Color(0xFF171D2C),
          surfaceLow: Color(0xFF1D2536),
          surface: Color(0xFF242D40),
          surfaceHigh: Color(0xFF2B354A),
          surfaceHighest: Color(0xFF354158),
          surfaceBright: Color(0xFF414D65),
          onSurface: Color(0xFFF3F5FF),
          onSurfaceVariant: Color(0xFFB9C3D9),
          outline: Color(0xFF78849F),
          outlineVariant: Color(0xFF39445B),
          accent: Color(0xFFB8B8FF),
          onAccent: Color(0xFF242052),
          accentContainer: Color(0xFF37355F),
          onAccentContainer: Color(0xFFE4DFFF),
          secondary: Color(0xFFEDB7CD),
          onSecondary: Color(0xFF462437),
          secondaryContainer: Color(0xFF4E3447),
          onSecondaryContainer: Color(0xFFFFDBEA),
          tertiary: Color(0xFF9EDBD5),
          onTertiary: Color(0xFF143C3B),
          tertiaryContainer: Color(0xFF284C4C),
          onTertiaryContainer: Color(0xFFC1F2EC),
          error: Color(0xFFE8786F),
          onError: Color(0xFF2A0A08),
          errorContainer: Color(0xFF5C2320),
          onErrorContainer: Color(0xFFFFD2CD),
          inverseSurface: Color(0xFFF3F5FF),
          onInverseSurface: Color(0xFF242D40),
          inversePrimary: Color(0xFF5757A8),
          scrim: Color(0xFF000000),
        ),
      ),
    );
    expect(
      _toneColors(AppPalette.lightTones),
      _toneColors(
        const Tones(
          base: Color(0xFFF3F5F8),
          surfaceLowest: Color(0xFFFFFFFF),
          surfaceLow: Color(0xFFFFFFFF),
          surface: Color(0xFFE9EDF4),
          surfaceHigh: Color(0xFFDFE5EE),
          surfaceHighest: Color(0xFFD4DBE6),
          surfaceBright: Color(0xFFC7CFD9),
          onSurface: Color(0xFF151A24),
          onSurfaceVariant: Color(0xFF3B4454),
          outline: Color(0xFF5A6475),
          outlineVariant: Color(0xFFCDD4DF),
          accent: Color(0xFF3A42B0),
          onAccent: Color(0xFFFFFFFF),
          accentContainer: Color(0xFFE4E6F8),
          onAccentContainer: Color(0xFF1E2468),
          secondary: Color(0xFF8A4564),
          onSecondary: Color(0xFFFFFFFF),
          secondaryContainer: Color(0xFFF8E4EC),
          onSecondaryContainer: Color(0xFF5C2C42),
          tertiary: Color(0xFF1F6A64),
          onTertiary: Color(0xFFFFFFFF),
          tertiaryContainer: Color(0xFFD7F1ED),
          onTertiaryContainer: Color(0xFF0E3E3A),
          error: Color(0xFFB42318),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFF8D7D4),
          onErrorContainer: Color(0xFF5C1612),
          inverseSurface: Color(0xFF1C2433),
          onInverseSurface: Color(0xFFF4F6FA),
          inversePrimary: Color(0xFFC4C6FF),
          scrim: Color(0xFF000000),
        ),
      ),
    );
    expect(
      _toneColors(AppPalette.tvDarkTones),
      _toneColors(
        const Tones(
          base: Color(0xFF0E1014),
          surfaceLowest: Color(0xFF121419),
          surfaceLow: Color(0xFF171A20),
          surface: Color(0xFF1D2027),
          surfaceHigh: Color(0xFF24282F),
          surfaceHighest: Color(0xFF2D3139),
          surfaceBright: Color(0xFF383D46),
          onSurface: Color(0xFFF2F3F5),
          onSurfaceVariant: Color(0xFFA9AFBA),
          outline: Color(0xFF6E7480),
          outlineVariant: Color(0xFF2E323A),
          accent: Color(0xFFB8B8FF),
          onAccent: Color(0xFF242052),
          accentContainer: Color(0xFF37355F),
          onAccentContainer: Color(0xFFE4DFFF),
          secondary: Color(0xFFEDB7CD),
          onSecondary: Color(0xFF462437),
          secondaryContainer: Color(0xFF4E3447),
          onSecondaryContainer: Color(0xFFFFDBEA),
          tertiary: Color(0xFF9EDBD5),
          onTertiary: Color(0xFF143C3B),
          tertiaryContainer: Color(0xFF284C4C),
          onTertiaryContainer: Color(0xFFC1F2EC),
          error: Color(0xFFF08A80),
          onError: Color(0xFF2A0A08),
          errorContainer: Color(0xFF5C2320),
          onErrorContainer: Color(0xFFFFD2CD),
          inverseSurface: Color(0xFFF2F3F5),
          onInverseSurface: Color(0xFF15171C),
          inversePrimary: Color(0xFF5757A8),
          scrim: Color(0xFF000000),
        ),
      ),
    );
    expect(
      _toneColors(AppPalette.tvLightTones),
      _toneColors(
        const Tones(
          base: Color(0xFFF4F5F7),
          surfaceLowest: Color(0xFFFFFFFF),
          surfaceLow: Color(0xFFFFFFFF),
          surface: Color(0xFFE8EAEE),
          surfaceHigh: Color(0xFFDEE1E6),
          surfaceHighest: Color(0xFFD3D7DE),
          surfaceBright: Color(0xFFC6CBD4),
          onSurface: Color(0xFF14171C),
          onSurfaceVariant: Color(0xFF3C424C),
          outline: Color(0xFF5C636E),
          outlineVariant: Color(0xFFD5D8DE),
          accent: Color(0xFF3A42B0),
          onAccent: Color(0xFFFFFFFF),
          accentContainer: Color(0xFFE4E6F8),
          onAccentContainer: Color(0xFF1E2468),
          secondary: Color(0xFF8A4564),
          onSecondary: Color(0xFFFFFFFF),
          secondaryContainer: Color(0xFFF8E4EC),
          onSecondaryContainer: Color(0xFF5C2C42),
          tertiary: Color(0xFF1F6A64),
          onTertiary: Color(0xFFFFFFFF),
          tertiaryContainer: Color(0xFFD7F1ED),
          onTertiaryContainer: Color(0xFF0E3E3A),
          error: Color(0xFFB42318),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFF8D7D4),
          onErrorContainer: Color(0xFF5C1612),
          inverseSurface: Color(0xFF14171C),
          onInverseSurface: Color(0xFFF7F8FA),
          inversePrimary: Color(0xFFC4C6FF),
          scrim: Color(0xFF000000),
        ),
      ),
    );

    final phoneLight = AppPalette.phoneLightTones;
    final phoneDark = AppPalette.phoneDarkTones;
    expect(phoneLight.brightness, Brightness.light);
    expect(phoneDark.brightness, Brightness.dark);
    expect(phoneLight.base.computeLuminance(), greaterThan(0.75));
    expect(phoneDark.base.computeLuminance(), lessThan(0.02));
    expect(_tinted(phoneLight.base), isTrue);
    expect(_tinted(phoneDark.base), isTrue);
    expect(_leansSakura(phoneLight.base), isTrue);
    expect(_leansBluePurple(phoneDark.base), isTrue);
    expect(_leansSakura(phoneLight.surface), isTrue);
    expect(_leansBluePurple(phoneDark.surface), isTrue);

    for (final tones in [phoneLight, phoneDark]) {
      expect(_isSakuraAccent(tones.accent), isTrue);
      expect(_isWarmGold(tones.accent), isFalse);
      expect(_leansSakura(tones.accentContainer), isTrue);
      expect(_leansBluePurple(tones.secondary), isTrue);
      expect(_leansBluePurple(tones.surfaceHigh), isTrue);
      expect(_isRed(tones.error), isTrue);
      expect(_isSakuraAccent(tones.error), isFalse);
      expect(_channelDistance(tones.error, tones.accent), greaterThan(0.05));
      expect(tones.scrim, const Color(0xFF000000));
      expect(
        _contrast(tones.onAccent, tones.accent),
        greaterThanOrEqualTo(4.5),
      );
    }

    for (final entry in <String, Color>{
      'base': phoneLight.base,
      'surfaceLow': phoneLight.surfaceLow,
      'surface': phoneLight.surface,
      'surfaceHigh': phoneLight.surfaceHigh,
    }.entries) {
      expect(
        _contrast(phoneLight.accent, entry.value),
        greaterThanOrEqualTo(4.5),
        reason: 'phone light accent on ${entry.key}',
      );
    }
    expect(phoneLight.error, const Color(0xFFB42318));
    expect(phoneDark.error, const Color(0xFFF08A80));
    expect(AppUiTheme.dark().colorScheme.primary, AppPalette.darkTones.accent);
  });

  test('artwork color tints detail surfaces without replacing them', () {
    for (final brightness in Brightness.values) {
      final base = brightness == Brightness.dark
          ? AppUiTheme.dark().colorScheme
          : AppUiTheme.light().colorScheme;
      const artwork = Color(0xFFE23B3B);
      final composed = composeContentPalette(base, artwork);
      expect(
        _channelDistance(composed.surface, base.surface),
        lessThan(_channelDistance(composed.surface, artwork)),
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
        expect(findAppTooltip('标记已看'), findsOneWidget);
        expect(find.text('已看 40%'), findsNothing);
        expect(
          tester
              .widget<AppLoadingBar>(
                find.descendant(
                  of: find.byKey(CatalogKeys.resumeProgress),
                  matching: find.byType(AppLoadingBar),
                ),
              )
              .value,
          closeTo(0.4, 0.001),
        );

        await tester.tap(findAppTooltip('搜索'));
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
      final played = const MediaItem(
        id: 'played',
        name: '看完的一集',
        type: 'Episode',
        userData: MediaUserData(played: true),
      );
      final resume = const MediaItem(
        id: 'resume',
        name: '看到一半',
        type: 'Episode',
        runtime: Duration(microseconds: (20 * 60 * 10000000) ~/ 10),
        userData: MediaUserData(
          playbackPosition: Duration(microseconds: (8 * 60 * 10000000) ~/ 10),
          playedPercentage: 40,
        ),
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: AppUiTheme.tvDark(),
          locale: const Locale('zh'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: TvStageTheme(
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
        expect(find.byType(AppLoadingBar), findsOneWidget);
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
