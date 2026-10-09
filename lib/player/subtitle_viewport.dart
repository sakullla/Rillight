import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rillight/player/player_controller.dart';

/// Reports the video surface to subtitle sizing.
///
/// Phone, desktop and TV all render text subtitles from this rectangle.
/// Identical measurements are ignored by the controller.
class SubtitleViewportReporter extends StatefulWidget {
  const SubtitleViewportReporter({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SubtitleViewportReporter> createState() =>
      _SubtitleViewportReporterState();
}

class _SubtitleViewportReporterState extends State<SubtitleViewportReporter> {
  double? _width, _height, _textScale;
  bool? _landscape;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
          return const SizedBox.expand();
        }
        final landscape = width > height;
        final base = landscape ? 24.0 : 20.0;
        final textScale = MediaQuery.textScalerOf(context).scale(base) / base;
        if (width != _width ||
            height != _height ||
            landscape != _landscape ||
            textScale != _textScale) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                width == _width &&
                    height == _height &&
                    landscape == _landscape &&
                    textScale == _textScale) {
              return;
            }
            _width = width;
            _height = height;
            _landscape = landscape;
            _textScale = textScale;
            unawaited(
              widget.controller.updateSubtitleViewport(
                width: width,
                height: height,
                landscape: landscape,
                textScale: textScale,
              ),
            );
          });
        }
        return const SizedBox.expand();
      },
    );
  }
}
