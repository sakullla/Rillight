import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// Samples saturated visible pixels only; transparent and neutral artwork
/// keeps the application palette. No Material color or theme types are used.
Future<AppColorScheme> contentPaletteFromBytes(
  Uint8List bytes,
  AppColorScheme fallback,
) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 32,
      allowUpscaling: false,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return fallback;
    final rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    var count = 0;
    var r = 0.0, g = 0.0, b = 0.0, weights = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final channels = [rgba[i], rgba[i + 1], rgba[i + 2]]..sort();
      final saturation = channels.last - channels.first;
      if (rgba[i + 3] <= 128 ||
          saturation <= 24 ||
          channels.last <= 32 ||
          channels.first >= 235) {
        continue;
      }
      final weight = saturation / 255;
      r += rgba[i] * weight;
      g += rgba[i + 1] * weight;
      b += rgba[i + 2] * weight;
      weights += weight;
      count++;
    }
    if (count < 32) return fallback;
    return composeContentPalette(
      fallback,
      Color.fromARGB(
        255,
        (r / weights).round(),
        (g / weights).round(),
        (b / weights).round(),
      ),
    );
  } catch (_) {
    return fallback;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Keep neutral surfaces and semantic errors while deriving a contrasting
/// action pair from the artwork hue. Foregrounds keep the app's AA contrast.
AppColorScheme composeContentPalette(AppColorScheme base, Color seed) {
  final dark = base.brightness == Brightness.dark;
  final hsl = HSLColor.fromColor(seed);
  final primary = hsl
      .withSaturation(hsl.saturation.clamp(.45, .8))
      .withLightness(dark ? .74 : .34)
      .toColor();
  Color on(Color color) => color.computeLuminance() > .179
      ? const Color(0xff000000)
      : const Color(0xffffffff);
  final container = hsl
      .withSaturation(.3)
      .withLightness(dark ? .24 : .9)
      .toColor();
  final tint = hsl.withSaturation(.2).withLightness(dark ? .22 : .88).toColor();
  Color surface(Color neutral) => Color.lerp(neutral, tint, .16)!;
  return base.copyWith(
    primary: primary,
    onPrimary: on(primary),
    primaryContainer: container,
    onPrimaryContainer: on(container),
    surface: surface(base.surface),
    surfaceContainerLowest: surface(base.surfaceContainerLowest),
    surfaceContainerLow: surface(base.surfaceContainerLow),
    surfaceContainer: surface(base.surfaceContainer),
    surfaceContainerHigh: surface(base.surfaceContainerHigh),
    surfaceContainerHighest: surface(base.surfaceContainerHighest),
    surfaceBright: surface(base.surfaceBright),
  );
}
