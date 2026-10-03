import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_image/artwork_crop.dart';

Uint8List pixels({Rect? detail}) {
  final rgba = Uint8List(64 * 64 * 4);
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final i = (y * 64 + x) * 4;
      final bright =
          detail?.contains(Offset(x.toDouble(), y.toDouble())) == true &&
          (x ~/ 2 + y ~/ 2).isEven;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = bright ? 240 : 40;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

ArtworkCropProfile profile({Rect? detail}) => ArtworkCropProfile.fromPixels(
  rgba: pixels(detail: detail),
  width: 64,
  height: 64,
  aspectRatio: 16 / 9,
);

void main() {
  test('wide hero retains high detail near the top of the artwork', () {
    final map = profile(detail: const Rect.fromLTWH(20, 6, 24, 16));
    final alignment = map.alignmentFor(const Size(1600, 400));
    expect(alignment.x, 0);
    expect(alignment.y, lessThan(-.4));
    // Converting alignment to source coordinates keeps the whole subject.
    final visibleHeight = 64 * (16 / 9) / 4;
    final top = (64 - visibleHeight) * (alignment.y + 1) / 2;
    expect(top, lessThanOrEqualTo(6));
    expect(top + visibleHeight, greaterThanOrEqualTo(22));
  });

  test('narrow hero retains a subject near the right edge', () {
    final map = profile(detail: const Rect.fromLTWH(47, 18, 12, 25));
    final alignment = map.alignmentFor(const Size(500, 500));
    expect(alignment.x, greaterThan(.4));
    expect(alignment.y, 0);
    final left = 28 * (alignment.x + 1) / 2;
    expect(left, lessThanOrEqualTo(47));
    expect(left + 36, greaterThanOrEqualTo(59));
    expect(map.alignmentFor(const Size(1600, 900)), Alignment.center);
  });

  test('neutral artwork has a stable raised fallback', () {
    final map = profile();
    expect(map.alignmentFor(const Size(1600, 400)).y, closeTo(-.3, 1e-9));
    expect(map.alignmentFor(const Size(500, 500)), Alignment.center);
    expect(map.alignmentFor(Size.zero), const Alignment(0, -.3));
  });

  testWidgets(
    'sampling waits for idle and resizing reuses the resolved profile',
    (tester) async {
      final bytes = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.black, BlendMode.src);
        for (var y = 5; y < 20; y += 2) {
          canvas.drawRect(
            Rect.fromLTWH(10, y.toDouble(), 44, 1),
            Paint()..color = Colors.white,
          );
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      }))!;
      final idle = Completer<void>();
      var waits = 0;
      late Alignment alignment;
      Widget app(double height) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: height,
            child: ArtworkCrop(
              identity: 'isolated-crop-test',
              bytes: bytes,
              waitForIdle: () {
                waits++;
                return idle.future;
              },
              builder: (value) {
                alignment = value;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(60));
      expect(alignment, const Alignment(0, -.3));
      expect(waits, 1);
      idle.complete();
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(alignment.y, lessThan(-.4));
      await tester.pumpWidget(app(200));
      expect(alignment, Alignment.center);
      expect(waits, 1);
    },
  );
}
