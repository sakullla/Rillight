import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.item,
    this.width,
    this.height,
    this.preferBackdrop = false,
    this.maxWidth,
  });

  final EmbyItem item;
  final double? width;
  final double? height;
  final bool preferBackdrop;
  final int? maxWidth;

  /// 清空同 [itemId]+type+maxWidth 字节复用表,仅测试使用。
  @visibleForTesting
  static void debugClearCache() {
    _MediaImageCache.instance.clear();
  }

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _LoadedImage {
  const _LoadedImage({required this.bytes, required this.type});

  final Uint8List bytes;
  final String type;
}

class _MediaImageState extends State<MediaImage> {
  Future<_LoadedImage?>? _future;

  bool get _hasImageSource {
    if (widget.item.primaryImageTag != null) {
      return true;
    }
    return widget.preferBackdrop && widget.item.backdropImageTag != null;
  }

  int get _requestMaxWidth => widget.maxWidth ?? widget.width?.round() ?? 280;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasImageSource) {
      _future ??= _load();
    }
  }

  @override
  void didUpdateWidget(MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxWidthChanged =
        oldWidget.maxWidth != widget.maxWidth ||
        oldWidget.width != widget.width;
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.primaryImageTag != widget.item.primaryImageTag ||
        oldWidget.item.backdropImageTag != widget.item.backdropImageTag ||
        oldWidget.preferBackdrop != widget.preferBackdrop ||
        maxWidthChanged) {
      _future = _hasImageSource ? _load() : null;
    }
  }

  Future<_LoadedImage?> _load() async {
    final client = AuthScope.of(context).client;
    final maxWidth = _requestMaxWidth;
    Future<Uint8List?> fetch(String type, String? tag) {
      return _MediaImageCache.instance.load(
        itemId: widget.item.id,
        type: type,
        maxWidth: maxWidth,
        fetch: () async {
          try {
            final bytes = await client.getItemImage(
              widget.item.id,
              type: type,
              tag: tag,
              maxWidth: maxWidth,
            );
            if (bytes.isEmpty) {
              return null;
            }
            return Uint8List.fromList(bytes);
          } catch (_) {
            return null;
          }
        },
      );
    }

    if (widget.preferBackdrop) {
      final backdropTag = widget.item.backdropImageTag;
      if (backdropTag != null) {
        final backdrop = await fetch('Backdrop', backdropTag);
        if (backdrop != null) {
          return _LoadedImage(bytes: backdrop, type: 'Backdrop');
        }
      }
    }
    final primary = await fetch('Primary', widget.item.primaryImageTag);
    if (primary == null) {
      return null;
    }
    return _LoadedImage(bytes: primary, type: 'Primary');
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (!_hasImageSource) {
      return PosterPlaceholder(width: width, height: height);
    }
    return FutureBuilder<_LoadedImage?>(
      future: _future,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return _loadingBox(context, width, height);
        }
        if (loaded == null || loaded.bytes.isEmpty) {
          return PosterPlaceholder(width: width, height: height);
        }
        final billboardFallback =
            widget.preferBackdrop && loaded.type != 'Backdrop';
        return Image.memory(
          loaded.bytes,
          width: width,
          height: height,
          fit: billboardFallback ? BoxFit.contain : BoxFit.cover,
          alignment: billboardFallback
              ? Alignment.centerLeft
              : Alignment.center,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: AppMotion.normal,
              curve: AppMotion.standard,
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return PosterPlaceholder(width: width, height: height);
          },
        );
      },
    );
  }

  Widget _loadingBox(BuildContext context, double? width, double? height) {
    return SkeletonBlock(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(AppRadii.sm),
    );
  }
}

/// 按 itemId+type+maxWidth 复用已取字节,避免同尺寸重复打图。
class _MediaImageCache {
  _MediaImageCache();

  static final _MediaImageCache instance = _MediaImageCache();

  final Map<String, Uint8List> _bytes = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  static String key(String itemId, String type, int maxWidth) =>
      '$itemId|$type|$maxWidth';

  Future<Uint8List?> load({
    required String itemId,
    required String type,
    required int maxWidth,
    required Future<Uint8List?> Function() fetch,
  }) {
    final cacheKey = key(itemId, type, maxWidth);
    final cached = _bytes[cacheKey];
    if (cached != null) {
      return Future<Uint8List?>.value(cached);
    }
    return _inflight.putIfAbsent(cacheKey, () async {
      try {
        final bytes = await fetch();
        if (bytes != null && bytes.isNotEmpty) {
          _bytes[cacheKey] = bytes;
        }
        return bytes;
      } finally {
        _inflight.remove(cacheKey);
      }
    });
  }

  void clear() {
    _bytes.clear();
    _inflight.clear();
  }
}
