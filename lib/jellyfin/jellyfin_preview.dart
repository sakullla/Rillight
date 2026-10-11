part of 'jellyfin_client.dart';

class _JellyfinPreview implements MediaPreview {
  _JellyfinPreview(
    this.client,
    this.itemId,
    this.source,
    this.width,
    this.height,
    this.columns,
    this.rows,
    this.count,
    this.interval,
  ) : generation = client._generation;
  final JellyfinClient client;
  @override
  final String itemId;
  final String source;
  final int width, height, columns, rows, count, interval, generation;
  bool closed = false;
  int? _cachedIndex;
  Uint8List? _cached;
  static _JellyfinPreview? tryCreate(
    JellyfinClient client,
    String item,
    String source,
    Map raw,
  ) {
    final values = [
      for (final k in [
        'Width',
        'Height',
        'TileWidth',
        'TileHeight',
        'ThumbnailCount',
        'Interval',
      ])
        raw[k],
    ];
    if (values.any((v) => v is! int || v <= 0) ||
        values[0] > 4096 ||
        values[1] > 4096 ||
        values[2] * values[3] > 10000 ||
        values[0] * values[2] > 32768 ||
        values[1] * values[3] > 32768) {
      return null;
    }
    return _JellyfinPreview(
      client,
      item,
      source,
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
    );
  }

  @override
  CapabilityStatus get availability => _available;
  @override
  Future<PreviewFrame?> frameAt(Duration position) async {
    client._check(generation);
    if (closed || position < Duration.zero) return null;
    final thumb = position.inMilliseconds ~/ interval;
    if (thumb >= count) return null;
    final tile = thumb ~/ (columns * rows);
    final offset = thumb % (columns * rows);
    final bytes = _cachedIndex == tile
        ? _cached!
        : Uint8List.fromList(
            await client.readAuthorizedBytes(
              client._uri(
                client.baseUrl!,
                'Videos/${Uri.encodeComponent(itemId)}/Trickplay/$width/$tile.jpg',
                {'mediaSourceId': source},
              ),
              maxBytes: 16 * 1024 * 1024,
            ),
          );
    client._check(generation);
    if (closed) return null;
    _cached = bytes;
    _cachedIndex = tile;
    return PreviewFrame(
      bytes: bytes,
      tile: PreviewTile(
        x: (offset % columns) * width,
        y: (offset ~/ columns) * height,
        width: width,
        height: height,
      ),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    _cached = null;
    _cachedIndex = null;
  }
}

class _ChapterPreview implements MediaPreview {
  _ChapterPreview(this.client, this.item) : generation = client._generation;
  final JellyfinClient client;
  final MediaItem item;
  final int generation;
  bool closed = false;
  @override
  String get itemId => item.id;
  @override
  CapabilityStatus get availability => _available;
  @override
  Future<PreviewFrame?> frameAt(Duration position) async {
    client._check(generation);
    if (closed) return null;
    var index = -1;
    for (var i = 0; i < item.chapters.length; i++) {
      if (item.chapters[i].startPosition <= position &&
          item.chapters[i].imageTag != null) {
        index = i;
      }
    }
    if (index < 0) return null;
    final chapter = item.chapters[index];
    final bytes = await client.getChapterImage(
      itemId,
      index: chapter.imageIndex ?? index,
      tag: chapter.imageTag,
    );
    client._check(generation);
    return closed ? null : PreviewFrame(bytes: Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
