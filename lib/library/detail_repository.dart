import 'package:dio/dio.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';

/// Shared detail request contract; presentation controllers own view state.
class DetailRepository {
  DetailRepository(this.client, this.cache);
  final MediaServerClient client;
  final CatalogCache cache;
  static const fields = MediaServerClient.detailWithPeople;
  final Map<String, Future<MediaItem>> _itemsInFlight = {};
  final Map<String, Future<List<MediaItem>>> _seasonsInFlight = {};
  final Map<String, Future<MediaItemPage>> _episodesInFlight = {};
  final Map<String, Future<List<MediaItem>>> _similarInFlight = {};

  /// Resolve progress within this series even when it was opened outside Home.
  Future<MediaItem?> resumeEpisode(String seriesId) async {
    final items = await client.getItems(
      parentId: seriesId,
      includeItemTypes: 'Episode',
      recursive: true,
      filters: const ['IsResumable'],
      sortBy: 'DatePlayed',
      sortOrder: 'Descending',
      limit: 1,
    );
    return items.where((item) => item.canResume).firstOrNull;
  }

  String _key(String path) =>
      '${cache.identityToken}|${client.baseUrl}|${client.userId}|$path';

  Future<T> _shared<T>(
    Map<String, Future<T>> requests,
    String key,
    Future<T> Function() fetch,
  ) => requests.putIfAbsent(key, () async {
    try {
      return await fetch();
    } finally {
      requests.remove(key);
    }
  });

  CatalogRequest _itemRequest(String id) => catalogItemRequest(
    userId: client.userId ?? '',
    itemId: id,
    fields: fields,
  );

  Future<MediaItem?> cachedItem(String id) async {
    final hit = await cache.lookupWhenReady(_itemRequest(id));
    return hit == null ? null : parseCatalogItem(hit.json);
  }

  Future<MediaItem> item(String id) => _shared(
    _itemsInFlight,
    _key('item:$id'),
    () async => parseCatalogItem(await cache.fetch(client, _itemRequest(id))),
  );

  CatalogRequest _seasonsRequest(String seriesId) => catalogItemsRequest(
    userId: client.userId ?? '',
    parentId: seriesId,
    includeItemTypes: 'Season',
    sortBy: 'IndexNumber',
    sortOrder: 'Ascending',
    fields: MediaServerClient.itemFields,
  );

  Future<List<MediaItem>> seasons(String seriesId) => _shared(
    _seasonsInFlight,
    _key('seasons:$seriesId'),
    () async =>
        parseCatalogPage(await cache.fetch(client, _seasonsRequest(seriesId)))
            .items,
  );

  Future<List<MediaItem>?> cachedSeasons(String seriesId) async {
    final hit = await cache.lookupWhenReady(_seasonsRequest(seriesId));
    return hit == null ? null : parseCatalogPage(hit.json).items;
  }

  CatalogRequest _episodesRequest(String seasonId, int start, int limit) =>
      catalogItemsRequest(
        userId: client.userId ?? '',
        parentId: seasonId,
        includeItemTypes: 'Episode',
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
        startIndex: start,
        limit: limit,
        fields: MediaServerClient.itemFields,
      );
  Future<MediaItemPage> episodes(
    String seasonId, {
    int start = 0,
    int limit = 50,
  }) => _shared(
    _episodesInFlight,
    _key('episodes:$seasonId:$start:$limit'),
    () async => parseCatalogPage(
      await cache.fetch(client, _episodesRequest(seasonId, start, limit)),
    ),
  );

  Future<MediaItemPage?> cachedEpisodes(
    String seasonId, {
    int start = 0,
    int limit = 50,
  }) async {
    final hit = await cache.lookupWhenReady(
      _episodesRequest(seasonId, start, limit),
    );
    return hit == null ? null : parseCatalogPage(hit.json);
  }

  Future<MediaItemPage> scanEpisodes(
    String seasonId, {
    required int start,
    required CancelToken cancelToken,
  }) async => parseCatalogPage(
    await cache.fetch(
      client,
      _episodesRequest(seasonId, start, 50),
      cancelToken: cancelToken,
    ),
  );

  CatalogRequest _similarRequest(String id, int limit) => catalogSimilarRequest(
    userId: client.userId ?? '',
    itemId: id,
    limit: limit,
  );

  Future<List<MediaItem>?> cachedSimilar(String id, {int limit = 12}) async {
    final hit = await cache.lookupWhenReady(_similarRequest(id, limit));
    return hit == null ? null : parseCatalogPage(hit.json).items;
  }

  Future<List<MediaItem>> similar(String id, {int limit = 12}) => _shared(
    _similarInFlight,
    _key('similar:$id:$limit'),
    () async =>
        parseCatalogPage(await cache.fetch(client, _similarRequest(id, limit)))
            .items,
  );
}
