import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Rasterize static artwork blur once at thumbnail size, then scale the result.
/// A small Image.cacheWidth alone does not bound an ImageFiltered layer: that
/// layer still covers the entire displayed hero, including on HiDPI screens.
class BlurredArtwork extends StatelessWidget {
  const BlurredArtwork({
    super.key,
    required this.bytes,
    required this.sigma,
    this.opacity = 1,
  });

  final Uint8List bytes;
  final double sigma;
  final double opacity;

  static const maxRasterDimension = 160;
  static final _cache =
      Expando<LinkedHashMap<(int, int, double), Future<Uint8List?>>>();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (!size.isFinite || size.isEmpty) return const SizedBox.shrink();
      final scale = maxRasterDimension / math.max(size.width, size.height);
      final width = math.max(1, (size.width * scale).round());
      final height = math.max(1, (size.height * scale).round());
      final blur = (sigma * scale * 100).round() / 100;
      final key = (width, height, blur);
      final entries = _cache[bytes] ??= LinkedHashMap();
      final future =
          entries.remove(key) ?? _rasterize(bytes, width, height, blur);
      entries[key] = future;
      // Weak byte keys share carousel remounts without retaining source art.
      // Bound resize variants as well, rather than caching every window size.
      while (entries.length > 4) {
        entries.remove(entries.keys.first);
      }
      return FutureBuilder<Uint8List?>(
        key: ValueKey((identityHashCode(bytes), key)),
        future: future,
        builder: (context, snapshot) {
          final raster = snapshot.data;
          if (raster == null) return const SizedBox.expand();
          return Image.memory(
            raster,
            width: size.width,
            height: size.height,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.low,
            color: Colors.white.withValues(alpha: opacity),
            colorBlendMode: BlendMode.modulate,
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          );
        },
      );
    },
  );

  static Future<Uint8List?> _rasterize(
    Uint8List bytes,
    int width,
    int height,
    double sigma,
  ) async {
    ui.Codec? codec;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Image? source, raster;
    ui.Picture? picture;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final decodeScale = math.min(
        1.0,
        maxRasterDimension / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * decodeScale).round()),
        targetHeight: math.max(1, (descriptor.height * decodeScale).round()),
      );
      source = (await codec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      );
      paintImage(
        canvas: canvas,
        rect: bounds,
        image: source,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
      );
      canvas.restore();
      picture = recorder.endRecording();
      raster = await picture.toImage(width, height);
      final data = await raster.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    } finally {
      raster?.dispose();
      picture?.dispose();
      source?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
