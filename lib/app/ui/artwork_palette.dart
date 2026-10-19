import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// A dominant hue family sampled from artwork.
///
/// [neutral] means the image cannot carry a trustworthy mood (monochrome,
/// multicolour, a tiny logo on black, fluorescent panels) and the application
/// palette must be kept unchanged.
class ArtworkMood {
  const ArtworkMood({
    required this.seed,
    required this.confidence,
    required this.dominantShare,
    required this.effectiveShare,
    this.neutral = false,
  });

  final Color seed;

  /// [dominantShare] × [effectiveShare]: how much of the picture is both
  /// visible and part of the dominant family.
  final double confidence;
  final double dominantShare;
  final double effectiveShare;
  final bool neutral;

  static const neutralMood = ArtworkMood(
    seed: Color(0xFF808080),
    confidence: 0,
    dominantShare: 0,
    effectiveShare: 0,
    neutral: true,
  );

  /// 12 hue bins of 30°. Bins 11 and 0 are adjacent, so a red around 350°/10°
  /// stays one family instead of splitting in half.
  static const hueBins = 12;

  static const _sampleWidth = 32;
  static const _sampleHeight = 32;
  static const _minConfidence = 0.18;
  static const _minEffectiveShare = 0.12;

  /// Derive a mood directly from a representative colour. Used by the legacy
  /// [composeContentPalette] signature; the same clamp and neutral rules apply.
  factory ArtworkMood.fromSeed(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    if (hsl.saturation < 0.1 ||
        hsl.lightness <= 0.12 ||
        hsl.lightness >= 0.94) {
      return neutralMood;
    }
    if (hsl.saturation >= 0.85 && hsl.lightness >= 0.70) {
      return neutralMood;
    }
    final clamped = _clamp(hsl);
    return ArtworkMood(
      seed: clamped.toColor(),
      confidence: 1,
      dominantShare: 1,
      effectiveShare: 1,
    );
  }

  /// Samples a 32×32 preview. Transparent, nearly neutral, near-black and
  /// blown-out pixels do not vote; the remaining pixels are weighted by their
  /// saturation so a large pale wash cannot outvote a saturated subject.
  static Future<ArtworkMood> fromBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return neutralMood;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _sampleWidth,
        targetHeight: _sampleHeight,
        allowUpscaling: false,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return neutralMood;
      final rgba = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return _sample(rgba);
    } catch (_) {
      return neutralMood;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static ArtworkMood _sample(Uint8List rgba) {
    final pixels = rgba.length ~/ 4;
    if (pixels == 0) return neutralMood;
    final weights = List<double>.filled(hueBins, 0);
    final reds = List<double>.filled(hueBins, 0);
    final greens = List<double>.filled(hueBins, 0);
    final blues = List<double>.filled(hueBins, 0);
    var effective = 0;
    var effectiveWeight = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final high = math.max(r, math.max(g, b));
      final low = math.min(r, math.min(g, b));
      final saturation = high - low;
      if (rgba[i + 3] <= 128 || saturation <= 24 || high <= 32 || low >= 235) {
        continue;
      }
      final bin =
          (HSLColor.fromColor(Color.fromARGB(255, r, g, b)).hue / 30).floor() %
          hueBins;
      final weight = saturation / 255;
      weights[bin] += weight;
      reds[bin] += r * weight;
      greens[bin] += g * weight;
      blues[bin] += b * weight;
      effectiveWeight += weight;
      effective++;
    }
    if (effective == 0 || effectiveWeight == 0) return neutralMood;

    var dominant = 0;
    for (var bin = 1; bin < hueBins; bin++) {
      if (weights[bin] > weights[dominant]) dominant = bin;
    }
    final family = <int>[
      (dominant + hueBins - 1) % hueBins,
      dominant,
      (dominant + 1) % hueBins,
    ];
    var familyWeight = 0.0;
    var familyR = 0.0, familyG = 0.0, familyB = 0.0;
    for (final bin in family) {
      familyWeight += weights[bin];
      familyR += reds[bin];
      familyG += greens[bin];
      familyB += blues[bin];
    }
    if (familyWeight == 0) return neutralMood;

    final dominantShare = familyWeight / effectiveWeight;
    final effectiveShare = effective / pixels;
    final confidence = dominantShare * effectiveShare;
    final seedColor = Color.fromARGB(
      255,
      (familyR / familyWeight).round().clamp(0, 255),
      (familyG / familyWeight).round().clamp(0, 255),
      (familyB / familyWeight).round().clamp(0, 255),
    );
    final hsl = HSLColor.fromColor(seedColor);
    final tooGreen = hsl.hue >= 60 && hsl.hue <= 160 && confidence < 0.55;
    final fluorescent = hsl.saturation >= 0.85 && hsl.lightness >= 0.70;
    if (confidence < _minConfidence ||
        effectiveShare < _minEffectiveShare ||
        tooGreen ||
        fluorescent) {
      return neutralMood;
    }
    return ArtworkMood(
      seed: _clamp(hsl).toColor(),
      confidence: confidence,
      dominantShare: dominantShare,
      effectiveShare: effectiveShare,
    );
  }

  static HSLColor _clamp(HSLColor hsl) => hsl
      .withSaturation(hsl.saturation.clamp(0.28, 0.50))
      .withLightness(hsl.lightness.clamp(0.25, 0.85));
}

/// Global mood cache. One entry per palette key and rendered brightness; the
/// same image feeds the home overlay and the detail surfaces.
class ArtworkMoodCache {
  ArtworkMoodCache({this.maxEntries = 96});

  static final ArtworkMoodCache instance = ArtworkMoodCache();

  final int maxEntries;
  final LinkedHashMap<String, ArtworkMood> _entries = LinkedHashMap();
  final Map<String, Future<ArtworkMood>> _pending = {};

  int get length => _entries.length;

  ArtworkMood? peek(String key) {
    final mood = _entries.remove(key);
    if (mood == null) return null;
    _entries[key] = mood;
    return mood;
  }

  Future<ArtworkMood> load(String key, Uint8List bytes) {
    final cached = peek(key);
    if (cached != null) return Future.value(cached);
    return _pending.putIfAbsent(key, () async {
      try {
        final mood = await ArtworkMood.fromBytes(bytes);
        _remember(key, mood);
        return mood;
      } finally {
        _pending.remove(key);
      }
    });
  }

  void clear() {
    _entries.clear();
    _pending.clear();
  }

  void _remember(String key, ArtworkMood mood) {
    _entries.remove(key);
    _entries[key] = mood;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// Legacy entry point. Decodes the image, derives an [ArtworkMood] and keeps
/// the same 7-surface composition as the widget path.
Future<AppColorScheme> contentPaletteFromBytes(
  Uint8List bytes,
  AppColorScheme fallback,
) async {
  final mood = await ArtworkMood.fromBytes(bytes);
  return composeContentPaletteFromMood(fallback, mood);
}

/// Artwork sets the mood, not the actions: only the 7 surface fields are
/// tinted. Primary, containers, selection, errors and text stay on the brand
/// palette so a poster can never recolour a play button or a selected pill.
AppColorScheme composeContentPalette(AppColorScheme base, Color seed) =>
    composeContentPaletteFromMood(base, ArtworkMood.fromSeed(seed));

AppColorScheme composeContentPaletteFromMood(
  AppColorScheme base,
  ArtworkMood mood,
) {
  if (mood.neutral) return base;
  final dark = base.brightness == Brightness.dark;
  final tint = HSLColor.fromColor(mood.seed)
      .withLightness(dark ? 0.22 : 0.88)
      .toColor();
  Color surface(Color neutral) => Color.lerp(neutral, tint, 0.16)!;
  return base.copyWith(
    surface: surface(base.surface),
    surfaceContainerLowest: surface(base.surfaceContainerLowest),
    surfaceContainerLow: surface(base.surfaceContainerLow),
    surfaceContainer: surface(base.surfaceContainer),
    surfaceContainerHigh: surface(base.surfaceContainerHigh),
    surfaceContainerHighest: surface(base.surfaceContainerHighest),
    surfaceBright: surface(base.surfaceBright),
  );
}
