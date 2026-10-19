import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/artwork_theme_source.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/media_server/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkMood', () {
    test('dominant hue drives a confident mood', () async {
      final mood = await ArtworkMood.fromBytes(
        await _solidPng(HSLColor.fromAHSL(1, 350, .85, .5).toColor()),
      );
      expect(mood.neutral, isFalse);
      expect(mood.effectiveShare, closeTo(1, .001));
      expect(mood.dominantShare, closeTo(1, .001));
      expect(mood.confidence, closeTo(1, .001));
      final seed = HSLColor.fromColor(mood.seed);
      expect(_hueDistance(seed.hue, 350), lessThan(8));
      expect(seed.saturation, inInclusiveRange(.28, .50));
      expect(seed.lightness, inInclusiveRange(.25, .85));
    });

    test('red 350/10 stays one family across the wrap', () async {
      final left = HSLColor.fromAHSL(1, 350, .85, .5).toColor();
      final right = HSLColor.fromAHSL(1, 10, .85, .5).toColor();
      final mood = await ArtworkMood.fromBytes(
        await _png([for (var i = 0; i < 1024; i++) i < 512 ? left : right]),
      );
      expect(mood.neutral, isFalse);
      expect(mood.dominantShare, closeTo(1, .01));
      expect(mood.confidence, closeTo(1, .01));
    });

    test('multicolour artwork falls back to neutral', () async {
      final hues = [0, 60, 120, 180, 240, 300];
      final mood = await ArtworkMood.fromBytes(
        await _png([
          for (var i = 0; i < 1024; i++)
            HSLColor.fromAHSL(
              1,
              hues[i % hues.length].toDouble(),
              .8,
              .5,
            ).toColor(),
        ]),
      );
      expect(mood.neutral, isTrue);
      expect(mood.confidence, lessThan(.18));
    });

    test('black and white with a small logo stays neutral', () async {
      final red = HSLColor.fromAHSL(1, 0, .9, .5).toColor();
      final mood = await ArtworkMood.fromBytes(
        await _png([
          for (var i = 0; i < 1024; i++) i < 64 ? red : const Color(0xFFFFFFFF),
        ]),
      );
      expect(mood.neutral, isTrue);
    });

    test('low-confidence green hue falls back to neutral', () async {
      final mood = await ArtworkMood.fromBytes(
        await _png([
          for (var i = 0; i < 1024; i++)
            HSLColor.fromAHSL(
              1,
              i < 410 ? 120 : (i < 717 ? 210 : 0),
              .8,
              .5,
            ).toColor(),
        ]),
      );
      expect(mood.neutral, isTrue);
    });

    test('fluorescent green is rejected', () async {
      final mood = await ArtworkMood.fromBytes(
        await _solidPng(const Color(0xFF66FF66)),
      );
      expect(mood.neutral, isTrue);
    });

    test('confidence multiplies dominant share by effective share', () async {
      final red = HSLColor.fromAHSL(1, 0, .9, .5).toColor();
      final mood = await ArtworkMood.fromBytes(
        await _png([
          for (var i = 0; i < 1024; i++)
            i < 256 ? red : const Color(0xFF808080),
        ]),
      );
      expect(mood.neutral, isFalse);
      expect(mood.dominantShare, closeTo(1, .001));
      expect(mood.effectiveShare, closeTo(.25, .001));
      expect(mood.confidence, closeTo(.25, .001));
    });

    test('seed saturation and lightness are clamped', () async {
      final mood = await ArtworkMood.fromBytes(
        await _solidPng(const Color(0xFFFF00FF)),
      );
      final seed = HSLColor.fromColor(mood.seed);
      expect(seed.saturation, closeTo(.50, .01));
      expect(seed.lightness, closeTo(.50, .01));
    });

    test('monochrome artwork is neutral', () async {
      for (final color in [
        const Color(0xFFFFFFFF),
        const Color(0xFF000000),
        const Color(0xFF808080),
      ]) {
        final mood = await ArtworkMood.fromBytes(await _solidPng(color));
        expect(mood.neutral, isTrue, reason: '$color');
      }
    });
  });

  group('surface composition', () {
    final baseDark = AppUiTheme.dark().colorScheme;
    final baseLight = AppUiTheme.light().colorScheme;

    test('only the 7 surface fields follow artwork', () async {
      final mood = await ArtworkMood.fromBytes(
        await _solidPng(HSLColor.fromAHSL(1, 350, .8, .5).toColor()),
      );
      for (final base in [baseDark, baseLight]) {
        final scheme = composeContentPaletteFromMood(base, mood);
        expect(scheme.primary, base.primary);
        expect(scheme.onPrimary, base.onPrimary);
        expect(scheme.primaryContainer, base.primaryContainer);
        expect(scheme.onPrimaryContainer, base.onPrimaryContainer);
        expect(scheme.secondary, base.secondary);
        expect(scheme.error, base.error);
        expect(scheme.onSurface, base.onSurface);
        expect(scheme.onSurfaceVariant, base.onSurfaceVariant);
        for (final field in [
          scheme.surface,
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
          scheme.surfaceBright,
        ]) {
          expect([
            base.surface,
            base.surfaceContainerLowest,
            base.surfaceContainerLow,
            base.surfaceContainer,
            base.surfaceContainerHigh,
            base.surfaceContainerHighest,
            base.surfaceBright,
          ], isNot(contains(field)));
        }
      }
    });

    test('neutral mood keeps the base scheme', () {
      expect(
        composeContentPaletteFromMood(baseDark, ArtworkMood.neutralMood),
        same(baseDark),
      );
    });

    test('legacy compose keeps 7 fields and primaryContainer', () {
      final scheme = composeContentPalette(baseLight, const Color(0xFF007AFF));
      expect(scheme.primaryContainer, baseLight.primaryContainer);
      expect(scheme.primary, baseLight.primary);
      expect(scheme.surface, isNot(baseLight.surface));
    });

    test('dark and light moods stay in their own lightness band', () async {
      final mood = await ArtworkMood.fromBytes(
        await _solidPng(HSLColor.fromAHSL(1, 210, .8, .5).toColor()),
      );
      final dark = composeContentPaletteFromMood(baseDark, mood);
      final light = composeContentPaletteFromMood(baseLight, mood);
      expect(
        HSLColor.fromColor(dark.surface).lightness,
        lessThan(HSLColor.fromColor(light.surface).lightness),
      );
      expect(
        HSLColor.fromColor(dark.surface).lightness,
        inInclusiveRange(.10, .30),
      );
      expect(
        HSLColor.fromColor(light.surface).lightness,
        inInclusiveRange(.90, 1.0),
      );
    });

    test('lerpSurfaces blends only surfaces', () {
      final a = baseDark.copyWith(
        surface: const Color(0xFF101010),
        surfaceContainerHigh: const Color(0xFF202020),
      );
      final b = baseDark.copyWith(
        surface: const Color(0xFF303030),
        surfaceContainerHigh: const Color(0xFF404040),
      );
      final half = AppColorScheme.lerpSurfaces(a, b, .5);
      expect(half.surface, const Color(0xFF202020));
      expect(half.surfaceContainerHigh, const Color(0xFF303030));
      expect(half.primary, a.primary);
      expect(half.primaryContainer, a.primaryContainer);
      expect(
        AppColorScheme.lerpSurfaces(a, b, 1).surfaceContainerHigh,
        b.surfaceContainerHigh,
      );
    });
  });

  group('ArtworkMoodCache', () {
    test('evicts the oldest entry beyond capacity', () async {
      final cache = ArtworkMoodCache(maxEntries: 2);
      final bytes = await _solidPng(const Color(0xFFFF3B30));
      await cache.load('a', bytes);
      await cache.load('b', bytes);
      await cache.load('c', bytes);
      expect(cache.length, 2);
      expect(cache.peek('a'), isNull);
      expect(cache.peek('c'), isNotNull);
    });

    test('peek and clear reset the mood store', () async {
      final cache = ArtworkMoodCache();
      final bytes = await _solidPng(const Color(0xFF007AFF));
      expect(cache.peek('a'), isNull);
      final mood = await cache.load('a', bytes);
      expect(cache.peek('a'), same(mood));
      cache.clear();
      expect(cache.peek('a'), isNull);
    });
  });

  group('resolveThemeArtwork', () {
    test('episode prefers its parent backdrop', () {
      final ref = resolveThemeArtwork(
        const MediaItem(
          id: 'episode',
          name: '',
          type: 'Episode',
          parentBackdropItemId: 'series',
          parentBackdropImageTag: 'parent',
          backdropImageTag: 'own',
          primaryImageTag: 'poster',
        ),
      );
      expect(ref?.itemId, 'series');
      expect(ref?.type, 'Backdrop');
      expect(ref?.tag, 'parent');
    });

    test('episode theme artwork matches the promotional hero source', () {
      // Heroes and detail headers never show a generated episode frame, so the
      // mood has to follow the series poster they do show.
      const episode = MediaItem(
        id: 'episode',
        name: '',
        type: 'Episode',
        seriesId: 'series',
        seriesPrimaryImageTag: 'poster',
        backdropImageTag: 'own-still',
        primaryImageTag: 'own-poster',
      );
      final hero = heroArtworkSources(episode);
      expect(hero.themeItem?.id, 'series');
      expect(hero.themeItem?.primaryImageTag, 'poster');
      final ref = resolveThemeArtwork(episode)!;
      expect(ref.itemId, hero.themeItem?.id);
      expect(ref.type, 'Primary');
      expect(ref.tag, 'poster');

      // Without promotional art the hero paints nothing; the detail header
      // falls back to the episode's own backdrop and themes from it.
      const noPromo = MediaItem(
        id: 'episode',
        name: '',
        type: 'Episode',
        backdropImageTag: 'own-still',
      );
      expect(heroArtworkSources(noPromo).isEmpty, isTrue);
      expect(resolveThemeArtwork(noPromo)?.tag, 'own-still');
    });

    test('episode falls back to its own backdrop or the series poster', () {
      expect(
        resolveThemeArtwork(
          const MediaItem(
            id: 'episode',
            name: '',
            type: 'Episode',
            backdropImageTag: 'own',
            primaryImageTag: 'poster',
          ),
        )?.tag,
        'own',
      );
      final seriesPoster = resolveThemeArtwork(
        const MediaItem(
          id: 'episode',
          name: '',
          type: 'Episode',
          seriesId: 'series',
          seriesPrimaryImageTag: 'series-poster',
        ),
      );
      expect(seriesPoster?.itemId, 'series');
      expect(seriesPoster?.type, 'Primary');
      expect(seriesPoster?.tag, 'series-poster');
    });

    test('movie prefers backdrop over poster', () {
      final ref = resolveThemeArtwork(
        const MediaItem(
          id: 'movie',
          name: '',
          type: 'Movie',
          backdropImageTag: 'back',
          primaryImageTag: 'poster',
        ),
      );
      expect(ref?.type, 'Backdrop');
      expect(ref?.tag, 'back');
    });

    test('untagged artwork cannot theme a surface', () {
      expect(
        resolveThemeArtwork(
          const MediaItem(id: 'movie', name: '', type: 'Movie'),
        ),
        isNull,
      );
    });

    test('palette key is width independent and mood key adds brightness', () {
      final key = paletteKey('account', 'movie', 'Backdrop', 'tag');
      expect(key, 'account/movie/Backdrop/tag');
      expect(
        artworkMoodKey(key, Brightness.dark),
        'account/movie/Backdrop/tag/dark',
      );
      expect(
        artworkMoodKey(key, Brightness.light),
        isNot(artworkMoodKey(key, Brightness.dark)),
      );
    });
  });
}

double _hueDistance(double a, double b) {
  final delta = (a - b).abs();
  return delta > 180 ? 360 - delta : delta;
}

Future<Uint8List> _solidPng(Color color) =>
    _png([for (var i = 0; i < 1024; i++) color]);

Future<Uint8List> _png(List<Color> pixels) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var i = 0; i < pixels.length; i++) {
    canvas.drawRect(
      Rect.fromLTWH((i % 32).toDouble(), (i ~/ 32).toDouble(), 1, 1),
      Paint()..color = pixels[i],
    );
  }
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
