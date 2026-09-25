import 'package:dio/dio.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_models.dart';

/// Shared detail request contract; presentation controllers own view state.
class DetailRepository {
  DetailRepository(this.client, this.cache);
  final EmbyClient client;
  final CatalogCache cache;
  static const fields = '${EmbyClient.itemFields},People';
  final Map<String, Future<EmbyItem>> _itemsInFlight = {};
  final Map<String, Future<List<EmbyItem>>> _seasonsInFlight = {};
  final Map<String, Future<EmbyItemPage>> _episodesInFlight = {};
  final Map<String, Future<List<EmbyItem>>> _similarInFlight = {};

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

  Future<EmbyItem?> cachedItem(String id) async {
    final hit = await cache.lookupWhenReady(_itemRequest(id));
    return hit == null ? null : parseCatalogItem(hit.json);
  }

  Future<EmbyItem> item(String id) => _shared(
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
    fields: EmbyClient.itemFields,
  );

  Future<List<EmbyItem>> seasons(String seriesId) => _shared(
    _seasonsInFlight,
    _key('seasons:$seriesId'),
    () async => parseCatalogPage(
      await cache.fetch(client, _seasonsRequest(seriesId)),
    ).items,
  );

  Future<List<EmbyItem>?> cachedSeasons(String seriesId) async {
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
        fields: EmbyClient.itemFields,
      );
  Future<EmbyItemPage> episodes(
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

  Future<EmbyItemPage?> cachedEpisodes(
    String seasonId, {
    int start = 0,
    int limit = 50,
  }) async {
    final hit = await cache.lookupWhenReady(
      _episodesRequest(seasonId, start, limit),
    );
    return hit == null ? null : parseCatalogPage(hit.json);
  }

  Future<EmbyItemPage> scanEpisodes(
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

  Future<List<EmbyItem>?> cachedSimilar(String id, {int limit = 12}) async {
    final hit = await cache.lookupWhenReady(_similarRequest(id, limit));
    return hit == null ? null : parseCatalogPage(hit.json).items;
  }

  Future<List<EmbyItem>> similar(String id, {int limit = 12}) => _shared(
    _similarInFlight,
    _key('similar:$id:$limit'),
    () async => parseCatalogPage(
      await cache.fetch(client, _similarRequest(id, limit)),
    ).items,
  );
}
