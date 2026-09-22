import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_models.dart';

/// Shared detail request contract; presentation controllers own view state.
class DetailRepository {
  const DetailRepository(this.client, this.cache);
  final EmbyClient client;
  final CatalogCache cache;
  static const fields = '${EmbyClient.itemFields},People';
  Future<EmbyItem> item(String id) async => parseCatalogItem(
    await cache.fetch(
      client,
      catalogItemRequest(
        userId: client.userId ?? '',
        itemId: id,
        fields: fields,
      ),
    ),
  );
  Future<List<EmbyItem>> seasons(String seriesId) => client.getItems(
    parentId: seriesId,
    includeItemTypes: 'Season',
    sortBy: 'IndexNumber',
    sortOrder: 'Ascending',
  );
  Future<EmbyItemPage> episodes(
    String seasonId, {
    int start = 0,
    int limit = 50,
  }) => client.queryItems(
    parentId: seasonId,
    includeItemTypes: 'Episode',
    sortBy: 'IndexNumber',
    sortOrder: 'Ascending',
    startIndex: start,
    limit: limit,
    fields: EmbyClient.itemFields,
  );
}
