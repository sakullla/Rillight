import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/bif_preview.dart';
import 'package:rillight/player/player_controller.dart';

/// Decorates the slider without replacing its input, keyboard or semantics.
class SeekPreview extends StatefulWidget {
  const SeekPreview({
    super.key,
    required this.controller,
    required this.child,
    this.dragValue,
  });
  final PlayerController controller;
  final Widget child;
  final double? dragValue;

  @override
  State<SeekPreview> createState() => _SeekPreviewState();
}

class _SeekPreviewState extends State<SeekPreview> {
  double? _hover;
  Timer? _debounce;
  CancelToken? _cancel;
  String? _itemId;
  Future<BifPreview?>? _bifFuture;
  BifPreview? _bif;
  Uint8List? _image;
  ItemChapter? _chapter;
  Future<Uint8List?>? _chapterFuture;
  int _revision = 0;

  @override
  void didUpdateWidget(SeekPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_itemId != widget.controller.itemId) {
      _cancel?.cancel();
      _bifFuture = null;
      _bif = null;
      _chapter = null;
      _chapterFuture = null;
      _image = null;
      _revision++;
      _itemId = widget.controller.itemId;
    }
    if (widget.dragValue != oldWidget.dragValue) _scheduleImage();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    super.dispose();
  }

  Duration _position(double fraction) => Duration(
    milliseconds: (widget.controller.duration.inMilliseconds * fraction)
        .round(),
  );

  void _scheduleImage() {
    _debounce?.cancel();
    final revision = ++_revision;
    final fraction = widget.dragValue ?? _hover;
    if (fraction == null) return;
    if (_bif != null) {
      _image = _bif!.imageAt(_position(fraction));
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_loadImage(revision)),
    );
  }

  Future<BifPreview?> _loadBif() async {
    final client = widget.controller.client;
    final id = widget.controller.itemId;
    _itemId = id;
    final cancel = _cancel = CancelToken();
    try {
      if (!await client.hasVideoPreviewThumbnails(id, cancelToken: cancel)) {
        return null;
      }
      return BifPreview.parse(
        await client.getVideoPreviewBif(id, cancelToken: cancel),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadImage(int revision) async {
    final id = widget.controller.itemId;
    final bif = await (_bifFuture ??= _loadBif());
    if (!mounted || revision != _revision || widget.controller.itemId != id) {
      return;
    }
    _bif = bif;
    final fraction = widget.dragValue ?? _hover;
    if (fraction == null) return;
    if (bif != null) {
      setState(() => _image = bif.imageAt(_position(fraction)));
      return;
    }
    final ticks = _position(fraction).inMicroseconds * 10;
    ItemChapter? chapter;
    for (final entry in widget.controller.item?.chapters ?? <ItemChapter>[]) {
      if (entry.imageTag == null || entry.startPositionTicks > ticks) continue;
      if (chapter == null ||
          entry.startPositionTicks > chapter.startPositionTicks) {
        chapter = entry;
      }
    }
    if (chapter == null) {
      _chapter = null;
      _chapterFuture = null;
      if (_image != null) setState(() => _image = null);
      return;
    }
    final index =
        chapter.imageIndex ?? widget.controller.item!.chapters.indexOf(chapter);
    try {
      if (chapter != _chapter) {
        _chapter = chapter;
        setState(() => _image = null);
        _chapterFuture = loadChapterImage(
          context,
          itemId: id,
          index: index,
          tag: chapter.imageTag,
          maxWidth: 320,
        );
      }
      final image = await _chapterFuture;
      if (mounted && revision == _revision && widget.controller.itemId == id) {
        setState(() => _image = image);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fraction = widget.dragValue ?? _hover;
      final previewWidth = constraints.maxWidth.clamp(
        0.0,
        _image == null ? 88.0 : 176.0,
      );
      final scheme = Theme.of(context).colorScheme;
      // Match the slider's actual padded track, rather than the entire widget.
      final sliderTheme = SliderTheme.of(context);
      final box = context.findRenderObject();
      final rect = box is RenderBox && box.hasSize
          ? sliderTheme.trackShape?.getPreferredRect(
              parentBox: box,
              sliderTheme: sliderTheme,
              isEnabled: true,
              isDiscrete: false,
            )
          : null;
      final trackLeft = rect?.left ?? 24.0;
      final trackWidth =
          rect?.width ??
          (constraints.maxWidth - 48).clamp(1.0, double.infinity);
      double logicalFraction(double dx) {
        final value = ((dx - trackLeft) / trackWidth).clamp(0.0, 1.0);
        return Directionality.of(context) == TextDirection.rtl
            ? 1 - value
            : value;
      }

      final physicalFraction = Directionality.of(context) == TextDirection.rtl
          ? 1 - (fraction ?? 0)
          : (fraction ?? 0);
      return MouseRegion(
        onHover: widget.controller.duration <= Duration.zero
            ? null
            : (event) {
                setState(
                  () => _hover = logicalFraction(event.localPosition.dx),
                );
                widget.controller.onPointerHover();
                _scheduleImage();
              },
        onExit: (_) {
          setState(() => _hover = null);
          if (widget.dragValue == null) {
            _debounce?.cancel();
            _revision++;
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            if (fraction != null && widget.controller.duration > Duration.zero)
              Positioned(
                bottom: 48,
                left:
                    (trackLeft +
                            trackWidth * physicalFraction -
                            previewWidth / 2)
                        .clamp(
                          0.0,
                          (constraints.maxWidth - previewWidth).clamp(
                            0.0,
                            double.infinity,
                          ),
                        ),
                width: previewWidth,
                child: IgnorePointer(
                  child: Material(
                    key: const Key('player-seek-preview'),
                    color: scheme.surfaceContainerHigh,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_image != null)
                          Image.memory(
                            _image!,
                            width: previewWidth,
                            height: previewWidth * 9 / 16,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            _clock(_position(fraction)),
                            key: const Key('player-seek-preview-time'),
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: scheme.onSurface,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

String _clock(Duration time) {
  final minutes = time.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = time.inSeconds.remainder(60).toString().padLeft(2, '0');
  return time.inHours > 0
      ? '${time.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
}
