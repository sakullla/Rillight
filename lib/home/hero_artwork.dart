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
  });

  final HeroArtworkSources sources;
  final int requestWidth;
  final bool compact;

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

class _ArtworkData {
  const _ArtworkData(
    this.bytes, {
    required this.poster,
    required this.identity,
  });
  final Uint8List bytes;
  final bool poster;
  final String identity;
}

class _HeroArtworkState extends State<HeroArtwork> {
  Future<_ArtworkData?>? _future;
  String? _token;
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

  Future<_ArtworkData?> _load(String scope, int generation) async {
    final auth = AuthScope.of(context);
    final client = auth.client;
    final width = widget.requestWidth;
    final minimum = widget.compact ? 640 : 960;
    final refs = [...widget.sources.backdrops, ...widget.sources.posters];
    bool current() =>
        mounted &&
        generation == _generation &&
        mediaImageAccountScope(auth) == scope;
    for (final ref in refs) {
      if (!current()) return null;
      try {
        final poster = ref.type == 'Primary';
        CancelToken? cancel;
        final bytes = await MediaImageCache.instance.load(
          serverId: scope,
          itemId: ref.itemId,
          type: ref.type,
          tag: ref.tag,
          maxWidth: width,
          isCurrent: current,
          onAbort: () => cancel?.cancel('hero-image-expired'),
          fetch: () async {
            cancel = CancelToken();
            return Uint8List.fromList(
              await client.getItemImage(
                ref.itemId,
                type: ref.type,
                tag: ref.tag,
                maxWidth: width,
                cancelToken: cancel,
              ),
            );
          },
        );
        if (!current()) return null;
        if (bytes == null || bytes.isEmpty) continue;
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        try {
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          try {
            final suitable = poster
                ? descriptor.width >= 240 && descriptor.height >= 320
                : HeroArtwork.suitableBackdrop(
                    descriptor.width,
                    descriptor.height,
                    minimumWidth: minimum,
                  );
            if (suitable && current()) {
              return _ArtworkData(
                bytes,
                poster: poster,
                identity: '$scope/${ref.itemId}/${ref.type}/${ref.tag}',
              );
            }
          } finally {
            descriptor.dispose();
          }
        } finally {
          buffer.dispose();
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
      child: FutureBuilder<_ArtworkData?>(
        key: ValueKey(_token),
        future: _future,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image == null) return const SizedBox.expand();
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
                Opacity(
                  opacity: .25,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Image.memory(
                      image.bytes,
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                    ),
                  ),
                ),
                Padding(padding: const EdgeInsets.all(20), child: art),
              ],
            ),
          );
        },
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
