import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/window_geometry.dart';

void main() {
  test('1080p work area uses about 70% and stays 16:9', () {
    final size = adaptiveWindowSizeFor(const Size(1920, 1080));
    expect(size.width, 1344);
    expect(size.height, 756);
  });

  test('4K at 150% scaling is capped near 1440x810', () {
    final size = adaptiveWindowSizeFor(const Size(2560, 1440));
    expect(size.width, lessThanOrEqualTo(kMaxDefaultWindowSize.width));
    expect(size.height, lessThanOrEqualTo(kMaxDefaultWindowSize.height));
    expect(size.width, 1408);
    expect(size.height, 792);
  });

  test('4K at 100% scaling is capped at 1440x810 not 85% of the desktop', () {
    final size = adaptiveWindowSizeFor(const Size(3840, 2160));
    expect(size, kMaxDefaultWindowSize);
  });

  test('adaptive size shrinks when the work area is short', () {
    final size = adaptiveWindowSizeFor(const Size(1920, 800));
    expect(size.height, lessThanOrEqualTo(800 * 0.70));
    expect(size.width, closeTo(size.height * 16 / 9, 1));
    expect(size.width, lessThanOrEqualTo(1920));
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
