import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_image/blurred_artwork.dart';

/// Promotional artwork for a title, never an episode's generated frame.
/// Shelf thumbnails keep their own selection rules.
class HeroArtworkSources {
  const HeroArtworkSources(this.backdrops, this.posters);

  final List<ItemImageRef> backdrops;
  final List<ItemImageRef> posters;
  bool get isEmpty => backdrops.isEmpty && posters.isEmpty;

  /// Route handoff keeps the navigated item ID while discarding episode stills.
  EmbyItem handoffItem(EmbyItem original) => EmbyItem(
    id: original.id,
    name: original.name,
    type: original.type,
    seriesName: original.seriesName,
    seriesId: original.seriesId,
    backdropImageTag: backdrops.firstOrNull?.itemId == original.id
        ? backdrops.firstOrNull?.tag
        : null,
    primaryImageTag: !original.isEpisode ? posters.firstOrNull?.tag : null,
    parentBackdropItemId: backdrops.firstOrNull?.itemId != original.id
        ? backdrops.firstOrNull?.itemId
        : null,
    parentBackdropImageTag: backdrops.firstOrNull?.itemId != original.id
        ? backdrops.firstOrNull?.tag
        : null,
    seriesPrimaryImageTag: original.isEpisode ? posters.firstOrNull?.tag : null,
  );

  EmbyItem? get themeItem {
    final source = backdrops.firstOrNull ?? posters.firstOrNull;
    if (source == null) return null;
    return EmbyItem(
      id: source.itemId,
      name: '',
      type: 'Movie',
      backdropImageTag: source.type == 'Backdrop' ? source.tag : null,
      primaryImageTag: source.type == 'Primary' ? source.tag : null,
    );
  }
}

HeroArtworkSources heroArtworkSources(
  EmbyItem item, {
  List<EmbyItem> series = const [],
}) {
  final backdrops = <ItemImageRef>[];
  final posters = <ItemImageRef>[];
  void add(List<ItemImageRef> target, String? id, String type, String? tag) {
    if (id == null || id.isEmpty || tag == null || tag.isEmpty) return;
    if (target.any((ref) => ref.itemId == id && ref.type == type)) return;
    target.add(ItemImageRef(itemId: id, type: type, tag: tag));
  }

  if (item.isEpisode) {
    add(
      backdrops,
      item.parentBackdropItemId,
      'Backdrop',
      item.parentBackdropImageTag,
    );
    final parent = series
        .where((entry) => entry.id == item.seriesId)
        .firstOrNull;
    if (parent != null) {
      add(backdrops, parent.id, 'Backdrop', parent.backdropImageTag);
    }
    add(posters, item.seriesId, 'Primary', item.seriesPrimaryImageTag);
    if (parent != null) {
      add(posters, parent.id, 'Primary', parent.primaryImageTag);
    }
  } else {
    add(backdrops, item.id, 'Backdrop', item.backdropImageTag);
    add(
      backdrops,
      item.parentBackdropItemId,
      'Backdrop',
      item.parentBackdropImageTag,
    );
    add(posters, item.id, 'Primary', item.primaryImageTag);
  }
  return HeroArtworkSources(backdrops, posters);
}

/// Reads encoded dimensions before accepting a backdrop. A small or incorrectly
/// shaped image falls back to a contained poster; missing art leaves the surface.
class HeroArtwork extends StatefulWidget {
  const HeroArtwork({
    super.key,
    required this.sources,
    required this.requestWidth,
    this.compact = false,
    this.spotlightBackground = false,
    this.posterFirst = false,
    this.ambient = false,
    this.prefetch = false,
    this.onResolved,
  });

  final HeroArtworkSources sources;
  final int requestWidth;
  final bool compact;

  /// Poster-spotlight mode: a poster result renders only the blurred, darkened
  /// full-bleed background; the parent draws the crisp poster card itself.
  final bool spotlightBackground;

  /// Poster-forward mode (phone card): try posters before backdrops and request
  /// the poster at [requestWidth]. A backdrop fallback renders contained over
  /// its own blur so a 2:3 card never crops a wide still.
  final bool posterFirst;

  /// Ambient mode: whatever resolves is drawn only as a soft blurred fill; the
  /// parent tints and fades it into the page. Never reports a theme colour.
  final bool ambient;

  /// Prefetch mode: resolve and decode the artwork the carousel will show next,
  /// paint nothing, and never report colours or layouts. When that slide
  /// arrives, the same sources hit the byte cache synchronously and the decoded
  /// frame is already in the image cache, so it does not flash the placeholder.
  final bool prefetch;

  /// Fires once per resolved image (post-frame, deduped by identity) so parents
  /// can switch between full-bleed and poster-spotlight layouts.
  final ValueChanged<HeroArtworkData>? onResolved;

  static bool suitableBackdrop(
    int width,
    int height, {
    required int minimumWidth,
  }) =>
      width >= minimumWidth &&
      height > 0 &&
      width / height >= 1.4 &&
      width / height <= 2.3;

  @override
  State<HeroArtwork> createState() => _HeroArtworkState();
}

/// A validated hero image. [poster] marks poster-shaped art, which parents may
/// present as a poster-spotlight instead of a full-bleed backdrop.
class HeroArtworkData {
  const HeroArtworkData(
    this.bytes, {
    required this.poster,
    required this.identity,
  });
  final Uint8List bytes;
  final bool poster;
  final String identity;
}

class _HeroArtworkState extends State<HeroArtwork> {
  // Byte objects are shared by MediaImageCache. Weak keys reuse header checks
  // across carousel remounts without keeping another image cache alive.
  static final _dimensions = Expando<(int, int)>();
  Future<HeroArtworkData?>? _future;
  HeroArtworkData? _initial;
  String? _precached;
  String? _token;
  String? _reportedIdentity;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(HeroArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  List<ItemImageRef> get _orderedRefs => widget.posterFirst
      ? [...widget.sources.posters, ...widget.sources.backdrops]
      : [...widget.sources.backdrops, ...widget.sources.posters];

  void _schedule() {
    final auth = AuthScope.maybeOf(context);
    final scope = mediaImageAccountScope(auth);
    final refs = _orderedRefs;
    final token =
        '$scope/${widget.requestWidth}/${widget.compact}/${widget.posterFirst}/${refs.map((ref) => '${ref.itemId}:${ref.type}:${ref.tag}').join('|')}';
    if (_token == token) return;
    _token = token;
    final generation = ++_generation;
    _initial = scope == null || auth == null ? null : _peek(scope);
    _future = scope == null || auth == null || _initial != null
        ? null
        : _load(scope, generation);
  }

  /// Pixel width each source is requested (and the cache keyed) at.
  int _sourceWidth(ItemImageRef ref) =>
      ref.type == 'Primary' && !widget.posterFirst
      ? math.min(widget.requestWidth, 480)
      : widget.requestWidth;

  bool _suitable(ItemImageRef ref, (int, int) dimensions) {
    if (ref.type == 'Primary') {
      return dimensions.$1 >= 240 && dimensions.$2 >= 320;
    }
    return HeroArtwork.suitableBackdrop(
      dimensions.$1,
      dimensions.$2,
      minimumWidth: math.min(widget.compact ? 640 : 960, widget.requestWidth),
    );
  }

  HeroArtworkData _data(String scope, ItemImageRef ref, Uint8List bytes) =>
      HeroArtworkData(
        bytes,
        poster: ref.type == 'Primary',
        identity: '$scope/${ref.itemId}/${ref.type}/${ref.tag}',
      );

  /// Synchronous replay of [_load] against the in-memory byte cache. Returns
  /// null as soon as any earlier source is still unknown, so the result always
  /// matches what the async walk would pick.
  HeroArtworkData? _peek(String scope) {
    final cache = MediaImageCache.instance;
    for (final ref in _orderedRefs) {
      final width = _sourceWidth(ref);
      final bytes = cache.peek(
        serverId: scope,
        itemId: ref.itemId,
        type: ref.type,
        tag: ref.tag,
        maxWidth: width,
      );
      if (bytes == null || bytes.isEmpty) {
        final missed = cache.isNegativeCached(
          serverId: scope,
          itemId: ref.itemId,
          type: ref.type,
          tag: ref.tag,
          maxWidth: width,
        );
        if (missed) continue;
        return null;
      }
      final dimensions = _dimensions[bytes];
      if (dimensions == null) return null;
      if (_suitable(ref, dimensions)) return _data(scope, ref, bytes);
    }
    return null;
  }

  Future<HeroArtworkData?> _load(String scope, int generation) async {
    final auth = AuthScope.of(context);
    final client = auth.client;
    final refs = _orderedRefs;
    bool current() =>
        mounted &&
        generation == _generation &&
        mediaImageAccountScope(auth) == scope;
    for (final ref in refs) {
      if (!current()) return null;
      try {
        // The sharp poster decodes at 480px; its blurred fill only needs 160px.
        // A poster-forward card asks for the poster at its own request width.
        final sourceWidth = _sourceWidth(ref);
        CancelToken? cancel;
        final bytes = await MediaImageCache.instance.load(
          serverId: scope,
          itemId: ref.itemId,
          type: ref.type,
          tag: ref.tag,
          maxWidth: sourceWidth,
          isCurrent: current,
          onAbort: () => cancel?.cancel('hero-image-expired'),
          fetch: () async {
            cancel = CancelToken();
            return Uint8List.fromList(
              await client.getItemImage(
                ref.itemId,
                type: ref.type,
                tag: ref.tag,
                maxWidth: sourceWidth,
                cancelToken: cancel,
              ),
            );
          },
        );
        if (!current()) return null;
        if (bytes == null || bytes.isEmpty) continue;
        var dimensions = _dimensions[bytes];
        if (dimensions == null) {
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          try {
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            try {
              dimensions = (descriptor.width, descriptor.height);
              _dimensions[bytes] = dimensions;
            } finally {
              descriptor.dispose();
            }
          } finally {
            buffer.dispose();
          }
        }
        if (_suitable(ref, dimensions) && current()) {
          return _data(scope, ref, bytes);
        }
      } catch (_) {
        // Try another official artwork source without a broken-image banner.
      }
    }
    return null;
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _notifyResolved(HeroArtworkData image) {
    final callback = widget.onResolved;
    if (callback == null || _reportedIdentity == image.identity) return;
    _reportedIdentity = image.identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedIdentity == image.identity) {
        callback(image);
      }
    });
  }

  /// Same provider [Image.memory] builds for these bytes and cache width, so
  /// the decoded frame lands under the key the visible slide will look up.
  int _cacheWidth(HeroArtworkData image) =>
      image.poster && !widget.posterFirst ? 480 : widget.requestWidth;

  Widget _buildPrefetch() {
    return FutureBuilder<HeroArtworkData?>(
      key: ValueKey(_token),
      future: _future,
      initialData: _initial,
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image != null && _precached != image.identity) {
          _precached = image.identity;
          final provider = ResizeImage.resizeIfNeeded(
            _cacheWidth(image),
            null,
            MemoryImage(image.bytes),
          );
          precacheImage(provider, context, onError: (_, _) {});
        }
        return const SizedBox.shrink();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.prefetch) return _buildPrefetch();
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHigh, scheme.surface],
        ),
      ),
      child: FutureBuilder<HeroArtworkData?>(
        key: ValueKey(_token),
        future: _future,
        initialData: _initial,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image == null) return const SizedBox.expand();
          _notifyResolved(image);
          if (widget.ambient) {
            return _blurredFill(image.bytes, opacity: 1, sigma: 40);
          }
          if (widget.spotlightBackground && image.poster) {
            return _spotlightBackdrop(image.bytes);
          }
          // The art whose shape matches the surface covers it; the other shape
          // sits contained over its own blur.
          final contain = widget.posterFirst ? !image.poster : image.poster;
          final art = Image.memory(
            image.bytes,
            fit: contain ? BoxFit.contain : BoxFit.cover,
            cacheWidth: _cacheWidth(image),
            filterQuality: FilterQuality.medium,
            frameBuilder: (context, child, frame, synchronous) {
              if (frame != null || synchronous) {
                ArtworkColorScope.maybeOf(context)?.report(
                  widget.sources.themeItem?.id ?? '',
                  image.identity,
                  image.bytes,
                );
              }
              // An already-decoded frame shows at once; a fresh decode fades
              // in over the placeholder instead of popping.
              if (synchronous) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: AppMotion.durationOf(context, AppMotion.slow),
                curve: AppMotion.standard,
                child: child,
              );
            },
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          );
          if (!contain) return SizedBox.expand(child: art);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _blurredFill(
                  image.bytes,
                  opacity: widget.posterFirst ? .45 : .25,
                  sigma: 24,
                ),
                Padding(
                  padding: EdgeInsets.all(widget.posterFirst ? 0 : 20),
                  child: art,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Full-bleed blurred + darkened layer behind a parent-drawn poster card.
  Widget _spotlightBackdrop(Uint8List bytes) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _blurredFill(bytes, opacity: .5, sigma: 32),
          const ColoredBox(color: Colors.black54),
        ],
      ),
    );
  }

  Widget _blurredFill(
    Uint8List bytes, {
    required double opacity,
    required double sigma,
  }) {
    return RepaintBoundary(
      child: BlurredArtwork(bytes: bytes, sigma: sigma, opacity: opacity),
    );
  }
}

EmbyItem seasonArtworkItem(EmbyItem season, EmbyItem series) => EmbyItem(
  id: season.id,
  name: season.name,
  type: 'Season',
  primaryImageTag: season.primaryImageTag,
  backdropImageTag: season.backdropImageTag,
  thumbImageTag: season.thumbImageTag,
  parentBackdropItemId: season.parentBackdropItemId ?? series.id,
  parentBackdropImageTag:
      season.parentBackdropImageTag ?? series.backdropImageTag,
  seriesId: series.id,
  seriesPrimaryImageTag: season.seriesPrimaryImageTag ?? series.primaryImageTag,
);
