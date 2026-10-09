import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/window_geometry.dart';

void main() {
  test('1080p browser keeps its width and gains height at 3:2', () {
    final size = adaptiveWindowSizeFor(const Size(1920, 1080));
    expect(size.width, 1344);
    expect(size.height, 896);
  });

  test('4K at 150% scaling uses logical pixels near 1440x960', () {
    final size = adaptiveWindowSizeFor(const Size(2560, 1440));
    expect(size.width, lessThanOrEqualTo(kMaxDefaultWindowSize.width));
    expect(size.height, lessThanOrEqualTo(kMaxDefaultWindowSize.height));
    expect(size.width, 1408);
    expect(size.height, 939);
  });

  test('4K at 100% scaling is capped at 1440x960', () {
    final size = adaptiveWindowSizeFor(const Size(3840, 2160));
    expect(size, kMaxDefaultWindowSize);
  });

  test('adaptive size shrinks when the work area is short', () {
    final size = adaptiveWindowSizeFor(const Size(1920, 800));
    expect(size.height, 800 * .90);
    expect(size.width, 1344);
  });

  test('small logical work areas do not throw or exceed the screen', () {
    for (final work in [const Size(800, 500), const Size(640, 360)]) {
      final size = adaptiveWindowSizeFor(work);
      expect(size.width, lessThanOrEqualTo(work.width));
      expect(size.height, lessThanOrEqualTo(work.height));
    }
  });

  test('invalid display measurements use the fallback', () {
    for (final work in [
      Size.zero,
      const Size(double.nan, 1080),
      const Size(1920, double.infinity),
    ]) {
      expect(adaptiveWindowSizeFor(work), kMinWindowSize);
    }
  });

  test('short player window retains the existing 16:9 policy', () {
    final size = adaptivePlayerWindowSizeFor(const Size(1920, 800));
    expect(size.height, 560);
    expect(size.width, closeTo(size.height * 16 / 9, 1));
  });

  test('adaptive size never drops below the minimum window', () {
    final size = adaptiveWindowSizeFor(const Size(1100, 700));
    expect(size.width, greaterThanOrEqualTo(kMinWindowSize.width));
    expect(size.height, greaterThanOrEqualTo(kMinWindowSize.height));
  });

  test('player popup is capped at 1280x720 on 4K', () {
    final size = adaptivePlayerWindowSizeFor(const Size(3840, 2160));
    expect(size, kMaxPlayerWindowSize);
  });

  test('player popup stays at most 1280x720 on 1080p', () {
    final size = adaptivePlayerWindowSizeFor(const Size(1920, 1080));
    expect(size.width, lessThanOrEqualTo(kMaxPlayerWindowSize.width));
    expect(size.height, lessThanOrEqualTo(kMaxPlayerWindowSize.height));
    expect(size.width, 1280);
    expect(size.height, 720);
  });
}
