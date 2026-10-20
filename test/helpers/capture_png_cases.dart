import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../../tool/ui_capture/png.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'capture PNG preserves dimensions, row boundaries and RGBA pixels',
    () async {
      final pixels = Uint8List.fromList([
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        0,
        0,
        255,
        0,
        0,
        128,
        255,
        255,
        255,
        255,
      ]);
      final codec = await ui.instantiateImageCodec(
        encodeCapturePng(pixels, 3, 2),
      );
      addTearDown(codec.dispose);
      final image = (await codec.getNextFrame()).image;
      addTearDown(image.dispose);
      expect(image.width, 3);
      expect(image.height, 2);
      final decoded = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      expect(decoded!.buffer.asUint8List(), pixels);
      expect(() => encodeCapturePng(pixels, 2, 2), throwsArgumentError);
      expect(() => encodeCapturePng(Uint8List(0), 0, 0), throwsArgumentError);
    },
  );
}
