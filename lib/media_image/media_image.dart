import 'dart:async';
import 'dart:math' as math;
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
    this.preferThumb = false,
    this.maxWidth,
  });

  final EmbyItem item;
  final double? width;
  final double? height;
  final bool preferBackdrop;
  final bool preferThumb;
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

  List<ItemImageRef> get _candidates {
    return widget.item.imageCandidates(
      preferBackdrop: widget.preferBackdrop,
      preferThumb: widget.preferThumb,
    );
  }

  bool get _hasImageSource => _candidates.isNotEmpty;

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
    // 网格滚动时 LayoutBuilder 宽度会抖 1px;已指定 maxWidth 则不重拉。
    final maxWidthChanged = oldWidget.maxWidth != widget.maxWidth;
    final widthChanged =
        widget.maxWidth == null && oldWidget.width != widget.width;
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.primaryImageTag != widget.item.primaryImageTag ||
        oldWidget.item.thumbImageTag != widget.item.thumbImageTag ||
        oldWidget.item.backdropImageTag != widget.item.backdropImageTag ||
        oldWidget.item.parentBackdropItemId !=
            widget.item.parentBackdropItemId ||
        oldWidget.item.parentBackdropImageTag !=
            widget.item.parentBackdropImageTag ||
        oldWidget.item.seriesPrimaryImageTag !=
            widget.item.seriesPrimaryImageTag ||
        oldWidget.preferBackdrop != widget.preferBackdrop ||
        oldWidget.preferThumb != widget.preferThumb ||
        maxWidthChanged ||
        widthChanged) {
      _future = _hasImageSource ? _load() : null;
    }
  }

  _LoadedImage? _peekLoaded() {
    // 只看首选候选。后面的剧 Backdrop 往往已经在缓存里,跳过去会让换集时
    // 背景永远停在同一张剧图,连本集 Thumb 都不拉。
    if (_candidates.isEmpty) {
      return null;
    }
    final candidate = _candidates.first;
    final bytes = _MediaImageCache.instance.peek(
      itemId: candidate.itemId,
      type: candidate.type,
      maxWidth: _requestMaxWidth,
    );
    if (bytes != null && bytes.isNotEmpty) {
      return _LoadedImage(bytes: bytes, type: candidate.type);
    }
    return null;
  }

  Future<_LoadedImage?> _load() async {
    final client = AuthScope.of(context).client;
    final maxWidth = _requestMaxWidth;
    for (final candidate in _candidates) {
      final bytes = await _MediaImageCache.instance.load(
        itemId: candidate.itemId,
        type: candidate.type,
        maxWidth: maxWidth,
        fetch: () async {
          try {
            final data = await client.getItemImage(
              candidate.itemId,
              type: candidate.type,
              tag: candidate.tag,
              maxWidth: maxWidth,
            );
            if (data.isEmpty) {
              return null;
            }
            return Uint8List.fromList(data);
          } catch (_) {
            return null;
          }
        },
      );
      if (bytes != null && bytes.isNotEmpty) {
        return _LoadedImage(bytes: bytes, type: candidate.type);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (!_hasImageSource) {
      return PosterPlaceholder(width: width, height: height);
    }
    final cached = _peekLoaded();
    if (cached != null) {
      return _paint(context, cached, width, height);
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
        return _paint(context, loaded, width, height);
      },
    );
  }

  Widget _paint(
    BuildContext context,
    _LoadedImage loaded,
    double? width,
    double? height,
  ) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final displayWidth = width == null || width <= 0
        ? null
        : math.max(1, (width * dpr).round());
    final cacheWidth = displayWidth == null
        ? null
        : math.min(displayWidth, _requestMaxWidth);
    return Image.memory(
      loaded.bytes,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return PosterPlaceholder(width: width, height: height);
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
/// 同时限制并发拉取,网格快滑时不会一次打几十张把 UI 打卡。
class _MediaImageCache {
  _MediaImageCache();

  static final _MediaImageCache instance = _MediaImageCache();

  static const int _maxConcurrentFetches = 12;

  final Map<String, Uint8List> _bytes = {};
  final Set<String> _misses = {};
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _activeFetches = 0;
  final List<Completer<void>> _waiters = [];

  static String key(String itemId, String type, int maxWidth) =>
      '$itemId|$type|$maxWidth';

  Uint8List? peek({
    required String itemId,
    required String type,
    required int maxWidth,
  }) {
    return _bytes[key(itemId, type, maxWidth)];
  }

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
    if (_misses.contains(cacheKey)) {
      return Future<Uint8List?>.value(null);
    }
    return _inflight.putIfAbsent(cacheKey, () async {
      await _acquire();
      try {
        final bytes = await fetch();
        if (bytes != null && bytes.isNotEmpty) {
          _bytes[cacheKey] = bytes;
          return bytes;
        }
        _misses.add(cacheKey);
        return null;
      } finally {
        _release();
        _inflight.remove(cacheKey);
      }
    });
  }

  Future<void> _acquire() async {
    if (_activeFetches < _maxConcurrentFetches) {
      _activeFetches++;
      return;
    }
    final gate = Completer<void>();
    _waiters.add(gate);
    await gate.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _activeFetches--;
    }
  }

  void clear() {
    _bytes.clear();
    _misses.clear();
    _inflight.clear();
    final pending = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    _activeFetches = 0;
    for (final waiter in pending) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}
