import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Only a successfully displayed frame can choose a content palette. The image
/// reports [itemId] plus the stable [paletteKey] of the exact candidate that
/// produced these bytes; consumers reject any key they did not ask for so a
/// poster, a similar row or a neighbouring hero page cannot leak its colour.
class ArtworkColorScope extends InheritedWidget {
  const ArtworkColorScope({
    super.key,
    required this.report,
    required super.child,
  });

  final void Function(String itemId, String paletteKey, Uint8List bytes) report;

  static ArtworkColorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtworkColorScope>();

  @override
  bool updateShouldNotify(ArtworkColorScope oldWidget) =>
      report != oldWidget.report;
}
