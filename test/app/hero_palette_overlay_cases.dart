import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/artwork_theme_source.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/hero_palette_overlay.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/player/playback_runtime.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/cupertino_test_app.dart';
import '../helpers/synthetic_source_fixture.dart';
import '../helpers/widget_harness.dart';

/// Reports a frame from inside [HeroPaletteOverlay], the way HeroArtwork and
/// MediaImage do while building.
class _Reporter extends StatelessWidget {
  const _Reporter({required this.paletteKey, required this.bytes});

  final String paletteKey;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    ArtworkColorScope.maybeOf(context)?.report('movie', paletteKey, bytes);
    return const SizedBox.expand();
  }
}

void main() {
  testWidgets('only the active palette key tints the overlay', (tester) async {
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/active',
          child: _Reporter(
            paletteKey: 'scope/next/Backdrop/prefetch',
            bytes: red,
          ),
        ),
      ),
    );
    await _settleMood(tester);
    // A neighbouring PageView page reports first; it must not tint the
    // visible slide while the active key is still missing.
    expect(
      _gradient(tester).colors.first,
      AppBrand.accent.withValues(alpha: .10),
    );

    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/active',
          child: _Reporter(
            paletteKey: 'scope/movie/Backdrop/active',
            bytes: red,
          ),
        ),
      ),
    );
    await _settleMood(tester);
    final first = _gradient(tester).colors.first;
    expect(_hueDistance(HSLColor.fromColor(first).hue, 2.5), lessThan(15));
    expect(first.a, greaterThan(0));
  });

  testWidgets('every stop follows the poster hue with no second brand stop', (
    tester,
  ) async {
    final blue = (await tester.runAsync(
      () => _solidPng(const Color(0xff1e5cff)),
    ))!;
    const key = 'scope/movie/Backdrop/blue';
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: key,
          child: _Reporter(paletteKey: key, bytes: blue),
        ),
      ),
    );
    await _settleMood(tester);
    final gradient = _gradient(tester);
    expect(gradient.stops, orderedEquals(AppBrandGradient.ambientStops));
    expect(gradient.colors, hasLength(AppBrandGradient.ambientStops.length));
    final moodHue = HSLColor.fromColor(gradient.colors.first).hue;
    expect(_hueDistance(moodHue, 220), lessThan(15));
    // 单色相:后续 stop 只是同一色相的透明度递减,最后溶到全透明。
    for (final color in gradient.colors) {
      expect(_hueDistance(HSLColor.fromColor(color).hue, moodHue), lessThan(1));
    }
    for (var i = 1; i < gradient.colors.length; i++) {
      expect(
        gradient.colors[i].a,
        lessThan(gradient.colors[i - 1].a),
        reason: 'stop $i fades toward transparent',
      );
    }
    expect(gradient.colors.last.a, 0);
    // 300–400ms crossfade; reduced motion collapses it to zero.
    final container = tester.widget<AnimatedContainer>(
      find.byKey(HeroPaletteOverlay.overlayKey),
    );
    expect(container.duration, AppMotion.slow);
  });

  testWidgets('neutral artwork keeps the brand fallback above the image', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/none',
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gradient = _gradient(tester);
    expect(gradient.colors.first, AppBrand.accent.withValues(alpha: .10));
    expect(gradient.colors.last.a, 0);
    for (final color in gradient.colors) {
      expect(
        color.withValues(alpha: 1),
        AppBrand.accent,
        reason: 'the fallback keeps the single accent hue',
      );
    }
    final overlay = tester.widget<AnimatedContainer>(
      find.byKey(HeroPaletteOverlay.overlayKey),
    );
    expect(
      (overlay.decoration! as BoxDecoration).gradient,
      isA<LinearGradient>(),
    );
    // 覆盖层永远不拦截点击。
    final hitTestWrappers = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.byKey(HeroPaletteOverlay.overlayKey),
            matching: find.byType(IgnorePointer),
          ),
        )
        .where((wrapper) => wrapper.ignoring);
    expect(hitTestWrappers, isNotEmpty);
  });

  testWidgets('detail source scope decides the overlay palette key', (
    tester,
  ) async {
    // 详情页的聚合条目由 DetailSourceScope 授权图片范围;覆盖层必须和
    // ContentTheme、MediaImage 用同一范围,不能回落到登录服务器的账号范围。
    final server = FakeEmbyServer();
    final auth = SyntheticSourceAuth(
      adapter: FakeEmbyAdapter([server]),
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'overlay',
        deviceId: 'hero-palette-overlay',
        version: '1',
      ),
      libraryIds: const {'view-movies'},
    );
    addTearDown(auth.dispose);
    final session = await tester.runAsync(() async {
      await auth.sources.load();
      final connected = await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      if (!connected) throw StateError('signed-in fixture failed');
      return auth.sources.authenticate(auth.session!.server.id);
    });
    final account = session!.account;
    final origin = PlaybackOrigin(
      source: SourceReference(account: account, itemId: 'movie-inception'),
      work: SourceReference(account: account, itemId: 'movie-inception'),
      libraryId: 'view-movies',
      permit: auth.sources.permit(account, libraryId: 'view-movies'),
      client: session.client,
    );
    final policy = MediaImageSourcePolicy(origin);
    addTearDown(policy.dispose);

    String? scoped;
    String? keyed;
    String? fallback;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: AuthScope(
          controller: auth,
          child: DetailSourceScope(
            origin: origin,
            cache: CatalogCache()..debugSetDiskStore(null),
            imagePolicy: policy,
            child: Builder(
              builder: (context) {
                scoped = DetailSourceScope.imagePolicyOf(context)?.scope;
                keyed = HeroPaletteOverlay.paletteKeyFor(
                  context,
                  const MediaItem(
                    id: 'movie-inception',
                    name: '',
                    type: 'Movie',
                    backdropImageTag: 'backdrop',
                  ),
                );
                fallback = paletteKey(
                  mediaImageAccountScope(auth),
                  'movie-inception',
                  'Backdrop',
                  'backdrop',
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(scoped, isNotNull);
    expect(
      keyed,
      paletteKey(scoped!, 'movie-inception', 'Backdrop', 'backdrop'),
    );
    expect(keyed, isNot(fallback));
  });

  for (final brightness in Brightness.values) {
    test('$brightness fallback is a low-alpha single accent hue', () {
      final gradient = HeroPaletteOverlay.gradientFor(brightness, null);
      final accent = brightness == Brightness.dark
          ? AppBrand.accent
          : AppBrand.accentDeep;
      expect(gradient.colors.first, accent.withValues(alpha: .10));
      for (final color in gradient.colors) {
        expect(color.withValues(alpha: 1), accent);
      }
      expect(gradient.colors.last.a, 0);
    });

    test('light and dark generate matching depth', () {
      final mood = ArtworkMood.fromSeed(const Color(0xffff3b30));
      final gradient = HeroPaletteOverlay.gradientFor(brightness, mood);
      final hsl = HSLColor.fromColor(gradient.colors.first);
      expect(
        hsl.lightness,
        closeTo(brightness == Brightness.dark ? .22 : .90, .001),
      );
      expect(
        gradient.colors.first.a,
        closeTo(brightness == Brightness.dark ? .18 : .16, .001),
      );
    });
  }
}

LinearGradient _gradient(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.byKey(HeroPaletteOverlay.overlayKey),
  );
  return (container.decoration! as BoxDecoration).gradient! as LinearGradient;
}

double _hueDistance(double a, double b) {
  final diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _settleMood(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
