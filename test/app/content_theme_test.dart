import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/theme.dart';

void main() {
  testWidgets(
    'a red image becomes a dark scheme and keeps the app error color',
    (tester) async {
      final scheme = await tester.runAsync(() async {
        final bytes = await _solidPng(const Color(0xFFE23B3B));
        final fallback = AppTheme.dark().colorScheme;
        return contentSchemeFromBytes(bytes, fallback);
      });
      final fallback = AppTheme.dark().colorScheme;

      expect(scheme, isNotNull);
      expect(scheme!.brightness, Brightness.dark);
      expect(scheme.primary.r, greaterThan(scheme.primary.b));
      expect(scheme.error, fallback.error);
      expect(scheme.onSurface, fallback.onSurface);
      expect(scheme.surfaceTint, Colors.transparent);
    },
  );
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = color);
  final image = await recorder.endRecording().toImage(16, 16);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
