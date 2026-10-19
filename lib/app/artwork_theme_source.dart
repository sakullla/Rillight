import 'package:flutter/widgets.dart';

import 'package:rillight/media_server/models.dart';

/// The one artwork that decides a surface's mood.
///
/// Home heroes and detail pages both resolve through this function so the same
/// item always samples the same image, no matter which surface happens to be
/// visible or how bright the application theme is. Landscape artwork wins
/// because the mood layer covers a wide backdrop; posters are the last resort.
///
/// Episode order: parent/series backdrop, series primary, episode backdrop,
/// episode primary. The series poster comes before the episode's own still
/// because [heroArtworkSources] never shows a generated episode frame; the
/// mood must follow the promotional image both surfaces actually display.
/// Movie/series order: own backdrop, parent backdrop, primary.
ItemImageRef? resolveThemeArtwork(MediaItem? item, [MediaItem? series]) {
  if (item == null) return null;
  ItemImageRef? first(String? itemId, String type, String? tag) {
    if (itemId == null || itemId.isEmpty) return null;
    if (tag == null || tag.isEmpty) return null;
    return ItemImageRef(itemId: itemId, type: type, tag: tag);
  }

  if (item.isEpisode) {
    final parent = first(
      item.parentBackdropItemId ?? series?.id,
      'Backdrop',
      item.parentBackdropImageTag ?? series?.backdropImageTag,
    );
    if (parent != null) return parent;
    final seriesPoster = first(
      series?.id ?? item.seriesId,
      'Primary',
      series?.primaryImageTag ?? item.seriesPrimaryImageTag,
    );
    if (seriesPoster != null) return seriesPoster;
    final ownBackdrop = first(item.id, 'Backdrop', item.backdropImageTag);
    if (ownBackdrop != null) return ownBackdrop;
    return first(item.id, 'Primary', item.primaryImageTag);
  }

  final backdrop = first(item.id, 'Backdrop', item.backdropImageTag);
  if (backdrop != null) return backdrop;
  final parentBackdrop = first(
    item.parentBackdropItemId,
    'Backdrop',
    item.parentBackdropImageTag,
  );
  if (parentBackdrop != null) return parentBackdrop;
  return first(item.id, 'Primary', item.primaryImageTag);
}

/// Stable identity of an artwork independent of request width or fallback
/// variant. The mood cache key adds the theme brightness.
String paletteKey(
  String? accountScope,
  String itemId,
  String type,
  String? tag,
) => '$accountScope/$itemId/$type/$tag';

/// Moods are sampled from visible pixels, so cache them per rendered theme.
String artworkMoodKey(String paletteKey, Brightness brightness) =>
    '$paletteKey/${brightness.name}';
