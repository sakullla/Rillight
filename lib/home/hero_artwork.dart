import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';

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
    this.onResolved,
  });

  final HeroArtworkSources sources;
  final int requestWidth;
  final bool compact;

  /// Poster-spotlight mode: a poster result renders only the blurred, darkened
  /// full-bleed background; the parent draws the crisp poster card itself.
  final bool spotlightBackground;

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

  void _schedule() {
    final auth = AuthScope.maybeOf(context);
    final scope = mediaImageAccountScope(auth);
    final refs = [...widget.sources.backdrops, ...widget.sources.posters];
    final token =
        '$scope/${widget.requestWidth}/${widget.compact}/${refs.map((ref) => '${ref.itemId}:${ref.type}:${ref.tag}').join('|')}';
    if (_token == token) return;
    _token = token;
    final generation = ++_generation;
    _future = scope == null || auth == null ? null : _load(scope, generation);
  }

  Future<HeroArtworkData?> _load(String scope, int generation) async {
    final auth = AuthScope.of(context);
    final client = auth.client;
    final width = widget.requestWidth;
    final minimum = math.min(widget.compact ? 640 : 960, width);
    final refs = [...widget.sources.backdrops, ...widget.sources.posters];
    bool current() =>
        mounted &&
        generation == _generation &&
        mediaImageAccountScope(auth) == scope;
    for (final ref in refs) {
      if (!current()) return null;
      try {
        final poster = ref.type == 'Primary';
        // The sharp poster decodes at 480px; its blurred fill only needs 160px.
        final sourceWidth = poster ? math.min(width, 480) : width;
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
        final suitable = poster
            ? dimensions.$1 >= 240 && dimensions.$2 >= 320
            : HeroArtwork.suitableBackdrop(
                dimensions.$1,
                dimensions.$2,
                minimumWidth: minimum,
              );
        if (suitable && current()) {
          return HeroArtworkData(
            bytes,
            poster: poster,
            identity: '$scope/${ref.itemId}/${ref.type}/${ref.tag}',
          );
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

  @override
  Widget build(BuildContext context) {
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
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image == null) return const SizedBox.expand();
          _notifyResolved(image);
          if (widget.spotlightBackground && image.poster) {
            return _spotlightBackdrop(image.bytes);
          }
          final art = Image.memory(
            image.bytes,
            fit: image.poster ? BoxFit.contain : BoxFit.cover,
            cacheWidth: image.poster ? 480 : widget.requestWidth,
            filterQuality: FilterQuality.medium,
            frameBuilder: (context, child, frame, synchronous) {
              if (frame != null || synchronous) {
                ArtworkColorScope.maybeOf(context)?.report(
                  widget.sources.themeItem?.id ?? '',
                  image.identity,
                  image.bytes,
                );
              }
              return child;
            },
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          );
          if (!image.poster) return SizedBox.expand(child: art);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _blurredFill(image.bytes, opacity: .25, sigma: 24),
                Padding(padding: const EdgeInsets.all(20), child: art),
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
      child: Opacity(
        opacity: opacity,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 160),
        ),
      ),
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
