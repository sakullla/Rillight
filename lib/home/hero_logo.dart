import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';

/// Decoded logo bytes and their intrinsic size.
class _LogoData {
  const _LogoData(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
  double get aspect => width / height;
}

/// Carousel title drawn as the server's transparent title logo
/// (`ImageTags.Logo`), falling back to [fallback] (the plain title text).
///
/// The logo is fitted inside [maxWidth] × [maxHeight] and sized to its own
/// aspect, so wide wordmarks stay short and stacked logos stay narrow. While the
/// bytes load the slot reserves a typical logo height instead of flashing the
/// text title first; a missing, broken or oddly shaped logo shows [fallback].
///
/// Without a session (tests, UI capture without art) or without a logo tag the
/// widget is exactly [fallback].
class HeroLogo extends StatefulWidget {
  const HeroLogo({
    super.key,
    required this.item,
    required this.fallback,
    required this.maxWidth,
    required this.maxHeight,
    this.alignment = Alignment.bottomLeft,
    this.prefetch = false,
  });

  final EmbyItem item;
  final Widget fallback;
  final double maxWidth;
  final double maxHeight;
  final Alignment alignment;

  /// Load and decode only; paint nothing. Used for the next carousel slide.
  final bool prefetch;

  /// Whether [item] can show a logo at all; callers may skip layout work.
  static bool available(EmbyItem item) => item.logoImageTag?.isNotEmpty == true;

  /// Request width for a logo slot: physical pixels, bounded for decode cost.
  static int requestWidthFor(double maxWidth, double devicePixelRatio) =>
      (maxWidth * devicePixelRatio).round().clamp(240, 800);

  @override
  State<HeroLogo> createState() => _HeroLogoState();
}

class _HeroLogoState extends State<HeroLogo> {
  static final _dimensions = Expando<(int, int)>();
  String? _token;
  _LogoData? _data;
  bool _failed = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(HeroLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  int get _requestWidth => HeroLogo.requestWidthFor(
    widget.maxWidth,
    MediaQuery.devicePixelRatioOf(context),
  );

  void _schedule() {
    final tag = widget.item.logoImageTag;
    final auth = AuthScope.maybeOf(context);
    final scope = mediaImageAccountScope(auth);
    final width = _requestWidth;
    final token = '$scope/${widget.item.id}/$tag/$width';
    if (token == _token) return;
    _token = token;
    final generation = ++_generation;
    _data = null;
    if (tag == null || tag.isEmpty || scope == null || auth == null) {
      _failed = true;
      return;
    }
    _failed = false;
    final cached = MediaImageCache.instance.peek(
      serverId: scope,
      itemId: widget.item.id,
      type: 'Logo',
      tag: tag,
      maxWidth: width,
    );
    final known = cached == null ? null : _dimensions[cached];
    if (cached != null && known != null) {
      _data = _accept(cached, known);
      _failed = _data == null;
      return;
    }
    _load(scope, tag, width, generation);
  }

  /// Logos are wide or roughly square wordmarks; tall slivers or tiny images
  /// are not title art, so they fall back to text.
  _LogoData? _accept(Uint8List bytes, (int, int) size) {
    final (width, height) = size;
    if (width < 80 || height < 20) return null;
    final aspect = width / height;
    if (aspect < .6 || aspect > 12) return null;
    return _LogoData(bytes, width, height);
  }

  Future<void> _load(
    String scope,
    String tag,
    int width,
    int generation,
  ) async {
    final auth = AuthScope.of(context);
    final client = auth.client;
    bool current() =>
        mounted &&
        generation == _generation &&
        mediaImageAccountScope(auth) == scope;
    _LogoData? data;
    try {
      CancelToken? cancel;
      final bytes = await MediaImageCache.instance.load(
        serverId: scope,
        itemId: widget.item.id,
        type: 'Logo',
        tag: tag,
        maxWidth: width,
        isCurrent: current,
        onAbort: () => cancel?.cancel('hero-logo-expired'),
        fetch: () async {
          cancel = CancelToken();
          return Uint8List.fromList(
            await client.getItemImage(
              widget.item.id,
              type: 'Logo',
              tag: tag,
              maxWidth: width,
              cancelToken: cancel,
            ),
          );
        },
      );
      if (bytes != null && bytes.isNotEmpty && current()) {
        var size = _dimensions[bytes];
        if (size == null) {
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          try {
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            size = (descriptor.width, descriptor.height);
            descriptor.dispose();
          } finally {
            buffer.dispose();
          }
          _dimensions[bytes] = size;
        }
        data = _accept(bytes, size);
        if (data != null && widget.prefetch && current()) {
          if (!mounted) return;
          await precacheImage(
            ResizeImage.resizeIfNeeded(width, null, MemoryImage(bytes)),
            context,
            onError: (_, _) {},
          );
        }
      }
    } catch (_) {
      data = null;
    }
    if (!current()) return;
    setState(() {
      _data = data;
      _failed = data == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.prefetch) return const SizedBox.shrink();
    if (_failed) return widget.fallback;
    final data = _data;
    final duration = AppMotion.durationOf(context, AppMotion.normal);
    if (data == null) {
      // A typical wordmark height; keeps the copy below from jumping twice.
      return SizedBox(width: widget.maxWidth, height: widget.maxHeight * .62);
    }
    final height = math.min(widget.maxHeight, widget.maxWidth / data.aspect);
    final width = height * data.aspect;
    return Semantics(
      header: true,
      label: _semanticTitle(widget.item),
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: Image.memory(
            data.bytes,
            width: width,
            height: height,
            fit: BoxFit.contain,
            alignment: widget.alignment,
            cacheWidth: _requestWidth,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, synchronous) {
              if (synchronous) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: duration,
                curve: AppMotion.standard,
                child: child,
              );
            },
            errorBuilder: (_, _, _) => widget.fallback,
          ),
        ),
      ),
    );
  }

  static String _semanticTitle(EmbyItem item) =>
      item.isEpisode && item.seriesName?.isNotEmpty == true
      ? item.seriesName!
      : item.name;
}
