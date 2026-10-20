import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme/brand.dart';
import 'package:rillight/app/theme/palette.dart';
import 'package:rillight/app/theme/tokens.dart';

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

    test('$themeName accent separates from its container and surfaces', () {
      expect(
        _contrast(tones.accent, tones.accentContainer),
        greaterThanOrEqualTo(3),
        reason: 'accent on accentContainer',
      );
      for (final (surfaceName, surface) in _surfaces(tones)) {
        expect(
          _contrast(tones.accent, surface),
          greaterThanOrEqualTo(3),
          reason: 'accent on $surfaceName',
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

  test('all six tone sets share the single brand accent', () {
    for (final tones in [
      AppPalette.darkTones,
      AppPalette.phoneDarkTones,
      AppPalette.tvDarkTones,
    ]) {
      expect(tones.accent, AppBrand.accent);
      expect(tones.onAccent, AppBrand.onAccent);
      expect(tones.base, AppBrand.ink);
      expect(tones.brightness, Brightness.dark);
    }
    for (final tones in [
      AppPalette.lightTones,
      AppPalette.phoneLightTones,
      AppPalette.tvLightTones,
    ]) {
      expect(tones.accent, AppBrand.accentDeep);
      expect(tones.base, AppBrand.paper);
      expect(tones.brightness, Brightness.light);
    }
  });

  for (final (themeName, tones) in [
    ('dark', AppPalette.darkTones),
    ('light', AppPalette.lightTones),
  ]) {
    test('$themeName surface ladder is a low-saturation neutral', () {
      for (final (surfaceName, surface) in _surfaces(tones)) {
        final channels = [surface.r, surface.g, surface.b];
        final chroma =
            channels.reduce((a, b) => a > b ? a : b) -
            channels.reduce((a, b) => a < b ? a : b);
        expect(chroma, lessThanOrEqualTo(.07), reason: surfaceName);
        expect(
          HSLColor.fromColor(surface).saturation,
          lessThanOrEqualTo(.25),
          reason: surfaceName,
        );
      }
      // 辅助色、第三色与 accent 同色系或中性,不再引入第二个品牌色相。
      final accentHue = HSLColor.fromColor(tones.accent).hue;
      for (final (name, color) in [
        ('secondary', tones.secondary),
        ('accentContainer', tones.accentContainer),
      ]) {
        final diff = (HSLColor.fromColor(color).hue - accentHue).abs() % 360;
        expect(diff > 180 ? 360 - diff : diff, lessThan(20), reason: name);
      }
      expect(
        HSLColor.fromColor(tones.tertiary).saturation,
        lessThanOrEqualTo(.25),
        reason: 'tertiary stays neutral',
      );
    });
  }

  test('light theme sits on a white page', () {
    expect(AppPalette.lightTones.surfaceLowest, const Color(0xFFFFFFFF));
    expect(AppPalette.lightTones.base.computeLuminance(), greaterThan(.9));
  });

  test('restraint tokens converge radii and keep single-layer shadows', () {
    expect(AppRadii.card, 12);
    expect(AppRadii.lg, 14);
    expect(AppRadii.xl, 20);
    expect(AppRadii.overlay, 20);
    expect(AppRadii.md, 12);
    expect(AppRadii.pill, 999);
    for (final brightness in Brightness.values) {
      for (final shadows in [
        AppShadow.cardHover(brightness),
        AppShadow.emphasis(brightness),
        AppShadow.overlay(brightness),
      ]) {
        expect(shadows, hasLength(1));
        final color = shadows.single.color;
        // 中性黑影,不带彩色光晕。
        expect([color.r, color.g, color.b], everyElement(0));
      }
    }
  });
}
