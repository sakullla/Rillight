import 'dart:typed_data';
import 'package:flutter/widgets.dart';

/// Only a successfully displayed frame can choose a content palette. The image
/// reports its authenticated cache identity, including its actual fallback.
class ArtworkColorScope extends InheritedWidget {
  const ArtworkColorScope({
    super.key,
    required this.report,
    required super.child,
  });
  final void Function(String itemId, String identity, Uint8List bytes) report;
  static ArtworkColorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtworkColorScope>();
  @override
  bool updateShouldNotify(ArtworkColorScope oldWidget) =>
      report != oldWidget.report;
}
