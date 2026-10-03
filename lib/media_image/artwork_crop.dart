import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A small detail/chroma map, not face recognition. Cover crops only one axis,
/// so two marginal profiles suffice and resizing never needs another decode.
class ArtworkCropProfile {
  ArtworkCropProfile._(this.aspectRatio, this.columns, this.rows);

  final double aspectRatio;
  final List<double> columns;
  final List<double> rows;

  factory ArtworkCropProfile.fromPixels({
    required Uint8List rgba,
    required int width,
    required int height,
    required double aspectRatio,
  }) {
    final columns = List<double>.filled(width, 0);
    final rows = List<double>.filled(height, 0);
    double luminance(int x, int y) {
      final i = (y * width + x) * 4;
      return (rgba[i] * .2126 + rgba[i + 1] * .7152 + rgba[i + 2] * .0722) /
          255;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final low = math.min(rgba[i], math.min(rgba[i + 1], rgba[i + 2]));
        final high = math.max(rgba[i], math.max(rgba[i + 1], rgba[i + 2]));
        final detail =
            (luminance(math.min(x + 1, width - 1), y) -
                    luminance(math.max(x - 1, 0), y))
                .abs() +
            (luminance(x, math.min(y + 1, height - 1)) -
                    luminance(x, math.max(y - 1, 0)))
                .abs();
        final weight = (detail + (high - low) / 255 * .08) * rgba[i + 3] / 255;
        columns[x] += weight;
        rows[y] += weight;
      }
    }
    return ArtworkCropProfile._(aspectRatio, columns, rows);
  }

  Alignment alignmentFor(Size viewport) {
    if (viewport.isEmpty || !viewport.isFinite) return const Alignment(0, -.3);
    final targetAspect = viewport.width / viewport.height;
    if ((targetAspect - aspectRatio).abs() < .001) return Alignment.center;
    return targetAspect > aspectRatio
        ? Alignment(0, _bestOffset(rows, aspectRatio / targetAspect, .35))
        : Alignment(_bestOffset(columns, targetAspect / aspectRatio, .5), 0);
  }

  static double _bestOffset(
    List<double> weights,
    double fraction,
    double prior,
  ) {
    final total = weights.fold<double>(0, (sum, value) => sum + value);
    if (total < .001 || fraction >= .999) return prior * 2 - 1;
    final length = math.max(1, (weights.length * fraction).round());
    final travel = weights.length - length;
    if (travel <= 0) return 0;
    var best = prior;
    var bestScore = -double.infinity;
    for (var start = 0; start <= travel; start++) {
      var retained = 0.0;
      for (var i = start; i < start + length; i++) {
        retained += weights[i];
      }
      final position = start / travel;
      // Prefer a stable, slightly raised crop when there is no clear subject.
      // Penalize cutting through detail at either edge of the crop window.
      final edge = weights[start] + weights[start + length - 1];
      final score =
          retained / total -
          edge / total * math.min(length * .15, 2) -
          .12 * math.pow(position - prior, 2);
      if (score > bestScore) {
        bestScore = score;
        best = position;
      }
    }
    return best * 2 - 1;
  }
}

/// Opt-in for the large hero only. Samples at most 64×64 pixels after scrolling
/// stops, caches by authenticated image identity, and never fetches another URL.
class ArtworkCrop extends StatefulWidget {
  const ArtworkCrop({
    super.key,
    required this.identity,
    required this.bytes,
    required this.waitForIdle,
    required this.builder,
  });

  final String identity;
  final Uint8List bytes;
  final Future<void> Function() waitForIdle;
  final Widget Function(Alignment alignment) builder;

  @override
  State<ArtworkCrop> createState() => _ArtworkCropState();
}

class _ArtworkCropState extends State<ArtworkCrop> {
  static final _cache = <String, Future<ArtworkCropProfile?>>{};
  ArtworkCropProfile? _profile;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ArtworkCrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _profile = null;
      _schedule();
    }
  }

  void _schedule() {
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation) return;
      await widget.waitForIdle();
      if (!mounted || generation != _generation) return;
      final identity = widget.identity;
      final future = _cache.putIfAbsent(identity, () => _sample(widget.bytes));
      if (_cache.length > 32) _cache.remove(_cache.keys.first);
      final profile = await future;
      if (!mounted || generation != _generation || profile == null) return;
      setState(() => _profile = profile);
    });
  }

  static Future<ArtworkCropProfile?> _sample(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final codec = await descriptor.instantiateCodec(
            targetWidth: 64,
            targetHeight: 64,
          );
          try {
            final frame = await codec.getNextFrame();
            try {
              final data = await frame.image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              if (data == null) return null;
              return ArtworkCropProfile.fromPixels(
                rgba: data.buffer.asUint8List(
                  data.offsetInBytes,
                  data.lengthInBytes,
                ),
                width: frame.image.width,
                height: frame.image.height,
                aspectRatio: descriptor.width / descriptor.height,
              );
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => widget.builder(
      _profile?.alignmentFor(constraints.biggest) ?? const Alignment(0, -.3),
    ),
  );
}
