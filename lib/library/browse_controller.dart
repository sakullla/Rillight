import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

class BrowseController extends ChangeNotifier {
  BrowseController({
    required this.auth,
    required this.cache,
    required this.parentId,
  });
  final AuthController auth;
  final CatalogCache cache;
  final String parentId;
  List<EmbyItem> items = const [];
  bool loading = false, hasMore = false;
  String? type, watch;
  String sortBy = 'SortName';
  EmbyException? error;
  int _revision = 0, _offset = 0;
  bool _disposed = false;
  Future<void> load({bool more = false}) async {
    if (more && (loading || !hasMore)) return;
    final revision = more ? _revision : ++_revision;
    final identity = (
      auth.client.baseUrl,
      auth.client.userId,
      auth.client.accessToken,
    );
    final offset = more ? _offset : 0;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final page = parseCatalogPage(
        await cache.fetch(
          auth.client,
          catalogItemsRequest(
            userId: auth.client.userId ?? '',
            parentId: parentId,
            recursive: true,
            includeItemTypes: type ?? 'Movie,Series',
            limit: 50,
            startIndex: offset,
            sortBy: sortBy,
            sortOrder: sortBy == 'SortName' ? 'Ascending' : 'Descending',
            filters: watch == null ? null : [watch!],
          ),
        ),
      );
      if (_disposed ||
          revision != _revision ||
          identity !=
              (
                auth.client.baseUrl,
                auth.client.userId,
                auth.client.accessToken,
              )) {
        return;
      }
      items = {
        for (final item in [...(more ? items : <EmbyItem>[]), ...page.items])
          item.id: item,
      }.values.toList();
      _offset = offset + page.items.length;
      hasMore = page.totalRecordCount == null
          ? page.items.length == 50
          : _offset < page.totalRecordCount!;
    } catch (failure) {
      if (_disposed || revision != _revision) return;
      error = failure is EmbyException
          ? failure
          : EmbyException(EmbyFailureKind.unknown, cause: failure);
    }
    if (_disposed || revision != _revision) return;
    loading = false;
    notifyListeners();
  }

  Future<void> filter({String? type, String? watch, required String sortBy}) {
    this.type = type;
    this.watch = watch;
    this.sortBy = sortBy;
    items = const [];
    return load();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
