import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_image/blurred_artwork.dart';

Future<Uint8List> _source() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 60, 60),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    const Rect.fromLTWH(60, 0, 60, 60),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 60);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Widget _subject(Uint8List bytes, {double width = 1600, double height = 800}) =>
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: BlurredArtwork(bytes: bytes, sigma: 32, opacity: .5),
        ),
      ),
    );

Future<Uint8List> _waitForRaster(WidgetTester tester) async {
  final image = find.descendant(
    of: find.byType(BlurredArtwork),
    matching: find.byType(Image),
  );
  for (var i = 0; i < 100 && image.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(image, findsOneWidget);
  return (tester.widget<Image>(image).image as MemoryImage).bytes;
}

void main() {
  testWidgets(
    'HiDPI hero blur is bounded, cached and contains blended pixels',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(4800, 3000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final bytes = (await tester.runAsync(_source))!;
      await tester.pumpWidget(_subject(bytes));
      final raster = await _waitForRaster(tester);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(raster);
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, 160);
          expect(image.height, 80);
          final pixels = (await image.toByteData())!;
          final center = (40 * image.width + 80) * 4;
          expect(pixels.getUint8(center), greaterThan(20));
          expect(pixels.getUint8(center + 2), greaterThan(20));
          expect(pixels.getUint8(center + 3), 255);
        } finally {
          image.dispose();
          codec.dispose();
        }
      });
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_subject(bytes));
      final cached = await _waitForRaster(tester);
      expect(identical(raster, cached), isTrue);
      await tester.pumpWidget(_subject(bytes, width: 800, height: 800));
      final resized = await _waitForRaster(tester);
      expect(identical(raster, resized), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('invalid artwork and disposal while rasterizing are harmless', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(Uint8List.fromList([1, 2, 3])));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final bytes = (await tester.runAsync(_source))!;
    await tester.pumpWidget(_subject(bytes));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    expect(tester.takeException(), isNull);
  });
}
