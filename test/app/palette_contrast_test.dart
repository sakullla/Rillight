import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme/brand.dart';
import 'package:rillight/app/theme/palette.dart';

double _contrast(Color a, Color b) {
  final values = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

List<(String, Color)> _surfaces(Tones tones) => [
  ('base', tones.base),
  ('surfaceLowest', tones.surfaceLowest),
  ('surfaceLow', tones.surfaceLow),
  ('surface', tones.surface),
  ('surfaceHigh', tones.surfaceHigh),
  ('surfaceHighest', tones.surfaceHighest),
  ('surfaceBright', tones.surfaceBright),
];

List<(String, Color)> _foregrounds(Tones tones) => [
  ('onSurface', tones.onSurface),
  ('onSurfaceVariant', tones.onSurfaceVariant),
  ('accent', tones.accent),
  ('secondary', tones.secondary),
  ('tertiary', tones.tertiary),
  ('error', tones.error),
];

List<(String, Color, Color)> _containerPairs(Tones tones) => [
  ('onAccent', tones.onAccent, tones.accent),
  ('onAccentContainer', tones.onAccentContainer, tones.accentContainer),
  ('onSecondary', tones.onSecondary, tones.secondary),
  (
    'onSecondaryContainer',
    tones.onSecondaryContainer,
    tones.secondaryContainer,
  ),
  ('onTertiary', tones.onTertiary, tones.tertiary),
  ('onTertiaryContainer', tones.onTertiaryContainer, tones.tertiaryContainer),
  ('onError', tones.onError, tones.error),
  ('onErrorContainer', tones.onErrorContainer, tones.errorContainer),
];

void main() {
  for (final (themeName, tones) in [
    ('dark', AppPalette.darkTones),
    ('light', AppPalette.lightTones),
  ]) {
    test('$themeName text and link foregrounds pass on every surface', () {
      for (final (surfaceName, surface) in _surfaces(tones)) {
        for (final (foregroundName, foreground) in _foregrounds(tones)) {
          expect(
            _contrast(foreground, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$foregroundName on $surfaceName',
          );
        }
      }
    });

    test('$themeName container pairs and outline pass', () {
      for (final (name, foreground, background) in _containerPairs(tones)) {
        expect(
          _contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: name,
        );
      }
      for (final (surfaceName, surface) in _surfaces(tones)) {
        expect(
          _contrast(tones.outline, surface),
          greaterThanOrEqualTo(3),
          reason: 'outline on $surfaceName',
        );
      }
    });

    test('$themeName rating star keeps a visible boundary', () {
      final star = AppBrand.ratingStar(tones.brightness);
      for (final (surfaceName, surface) in _surfaces(tones)) {
        expect(
          _contrast(star, surface),
          greaterThanOrEqualTo(4.5),
          reason: 'rating star on $surfaceName',
        );
      }
    });
  }

  test('all six tone sets share the same brand hues', () {
    for (final tones in [
      AppPalette.darkTones,
      AppPalette.phoneDarkTones,
      AppPalette.tvDarkTones,
    ]) {
      expect(tones.accent, AppBrand.pink);
      expect(tones.secondary, AppBrand.cyan);
      expect(tones.tertiary, AppBrand.lavender);
    }
    for (final tones in [
      AppPalette.lightTones,
      AppPalette.phoneLightTones,
      AppPalette.tvLightTones,
    ]) {
      expect(tones.accent, AppBrand.pinkDeep);
      expect(tones.secondary, AppBrand.cyanDeep);
      expect(tones.tertiary, AppBrand.lavenderDeep);
    }
  });

  test('light surface ladder stays in the pink family', () {
    double hue(Color color) {
      final max = [color.r, color.g, color.b].reduce((a, b) => a > b ? a : b);
      final min = [color.r, color.g, color.b].reduce((a, b) => a < b ? a : b);
      final delta = max - min;
      if (delta == 0) return 0;
      final double value;
      if (max == color.r) {
        value = ((color.g - color.b) / delta) % 6;
      } else if (max == color.g) {
        value = (color.b - color.r) / delta + 2;
      } else {
        value = (color.r - color.g) / delta + 4;
      }
      final degrees = value * 60;
      return degrees < 0 ? degrees + 360 : degrees;
    }

    for (final surface in [
      AppPalette.lightTones.surface,
      AppPalette.lightTones.surfaceHigh,
      AppPalette.lightTones.surfaceHighest,
      AppPalette.lightTones.surfaceBright,
    ]) {
      expect(hue(surface), inInclusiveRange(300, 350));
    }
  });
}
