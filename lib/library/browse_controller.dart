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
  }) {
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
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
  late Object _identity;
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _revision++;
    items = const [];
    _offset = 0;
    loading = hasMore = false;
    error = null;
    notifyListeners();
  }

  bool _owns(int revision) =>
      !_disposed && revision == _revision && _identity == _currentIdentity;
  Future<void> load({bool more = false}) async {
    if (more && (loading || !hasMore)) return;
    final revision = more ? _revision : ++_revision;
    final offset = more ? _offset : 0;
    if (!more) {
      _offset = 0;
      hasMore = false;
    }
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
      if (!_owns(revision)) return;
      items = {
        for (final item in [...(more ? items : <EmbyItem>[]), ...page.items])
          item.id: item,
      }.values.toList();
      _offset = offset + page.items.length;
      hasMore = page.totalRecordCount == null
          ? page.items.length == 50
          : _offset < page.totalRecordCount!;
    } catch (failure) {
      if (!_owns(revision)) return;
      error = failure is EmbyException
          ? failure
          : EmbyException(EmbyFailureKind.unknown, cause: failure);
    }
    if (!_owns(revision)) return;
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
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
