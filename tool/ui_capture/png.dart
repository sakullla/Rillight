import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Lossless RGBA PNG with inexpensive native compression for local captures.
/// No palette quantization, resizing, or alpha premultiplication is performed.
Uint8List encodeCapturePng(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError('Expected width × height straight RGBA pixels');
  }
  final stride = width * 4;
  // PNG filter 0 copies pixels unchanged. Deflate still compresses repeated
  // backgrounds without evaluating five filters for every screenshot row.
  final scanlines = Uint8List(rgba.length + height);
  for (var y = 0; y < height; y++) {
    scanlines.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      rgba,
      y * stride,
    );
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final output = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final content = Uint8List(4 + data.length)
      ..setRange(0, 4, ascii.encode(type))
      ..setRange(4, 4 + data.length, data);
    output
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(content)
      ..add(
        (ByteData(4)..setUint32(0, getCrc32(content))).buffer.asUint8List(),
      );
  }

  chunk('IHDR', header.buffer.asUint8List());
  // Match Flutter's PNG color profile (sRGB, perceptual rendering intent).
  chunk('sRGB', const [0]);
  chunk('IDAT', ZLibEncoder(level: 1).convert(scanlines));
  chunk('IEND', const []);
  return output.takeBytes();
}
