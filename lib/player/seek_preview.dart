import 'buffered_ranges_track.dart';

import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/resources.dart';
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
  Future<MediaPreview?>? _bifFuture;
  MediaPreview? _bif;
  Uint8List? _image;
  ItemChapter? _chapter;
  Future<Uint8List?>? _chapterFuture;
  int _revision = 0;

  @override
  void didUpdateWidget(SeekPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_itemId != widget.controller.itemId) {
      _cancel?.cancel();
      unawaited(_bif?.close());
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
    unawaited(_bif?.close());
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
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_loadImage(revision)),
    );
  }

  Future<MediaPreview?> _loadBif() async {
    final client = widget.controller.client;
    final id = widget.controller.itemId;
    _itemId = id;
    final cancel = _cancel = CancelToken();
    try {
      final preview = await client.openPreview(id);
      if (cancel.isCancelled) {
        await preview?.close();
        return null;
      }
      return preview;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadImage(int revision) async {
    final id = widget.controller.itemId;
    bool isCurrent() =>
        mounted && revision == _revision && widget.controller.itemId == id;
    final bif = await (_bifFuture ??= _loadBif());
    if (!isCurrent()) return;
    _bif = bif;
    final fraction = widget.dragValue ?? _hover;
    if (fraction == null) return;
    if (bif != null) {
      try {
        final frame = await bif.frameAt(_position(fraction));
        if (!isCurrent()) return;
        final bytes = frame == null ? null : await _previewBytes(frame);
        if (!isCurrent()) return;
        if (bytes != null) {
          setState(() => _image = bytes);
          return;
        }
      } catch (_) {
        // Remote frames and tiles are optional. A failed read or decode must
        // fall back just like absent preview data, without escaping the timer.
      }
      if (!isCurrent()) return;
      if (_image != null) setState(() => _image = null);
    }
    if (!mounted || !isCurrent()) return;
    final position = _position(fraction);
    ItemChapter? chapter;
    for (final entry in widget.controller.item?.chapters ?? <ItemChapter>[]) {
      if (entry.imageTag == null || entry.startPosition > position) continue;
      if (chapter == null || entry.startPosition > chapter.startPosition) {
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
      if (isCurrent()) {
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
      final scheme = AppUiTheme.of(context).colorScheme;
      // Match the slider's actual padded track, rather than the entire widget.
      const trackLeft = playerSliderInset;
      final trackWidth = (constraints.maxWidth - playerSliderInset * 2).clamp(
        1.0,
        double.infinity,
      );
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
                  child: Container(
                    key: const Key('player-seek-preview'),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: AppEdge.of(
                          AppUiTheme.of(context).brightness,
                          strong: true,
                        ),
                      ),
                      boxShadow: AppShadow.cardHover(
                        AppUiTheme.of(context).brightness,
                      ),
                    ),
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
                            style: AppUiTheme.of(context).textTheme.labelLarge
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

Future<Uint8List> _previewBytes(PreviewFrame frame) async {
  final tile = frame.tile;
  if (tile == null) return frame.bytes;
  if (tile.x < 0 ||
      tile.y < 0 ||
      tile.width <= 0 ||
      tile.height <= 0 ||
      tile.width > 4096 ||
      tile.height > 4096) {
    throw const FormatException('Invalid preview tile');
  }
  final codec = await ui.instantiateImageCodec(frame.bytes);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  try {
    if (tile.x + tile.width > image.width ||
        tile.y + tile.height > image.height) {
      throw const FormatException('Preview tile outside image');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        tile.x.toDouble(),
        tile.y.toDouble(),
        tile.width.toDouble(),
        tile.height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, tile.width.toDouble(), tile.height.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    final ui.Image cropped;
    try {
      cropped = await picture.toImage(tile.width, tile.height);
    } finally {
      picture.dispose();
    }
    try {
      return (await cropped.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    } finally {
      cropped.dispose();
    }
  } finally {
    image.dispose();
  }
}
