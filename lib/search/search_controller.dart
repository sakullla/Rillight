import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

/// Shared search paging and stale-result ownership for all presentations.
class SearchController extends ChangeNotifier {
  SearchController({required this.auth, required this.cache}) {
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
  final AuthController auth;
  final CatalogCache cache;
  static const pageSize = 50;
  List<EmbyItem> items = const [];
  String term = '';
  String? watch;
  int fetched = 0;
  bool loading = false, loadingMore = false, hasMore = false, searched = false;
  EmbyException? error, pageError;
  int _revision = 0;
  bool _disposed = false;
  late Object _identity;
  // A renewed credential still owns the same catalog request. User/server/line
  // changes invalidate it, including logout followed by the same user's login.
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _revision++;
    items = const [];
    fetched = 0;
    watch = null;
    loading = loadingMore = hasMore = searched = false;
    error = pageError = null;
    _emit();
  }

  bool _owns(int revision) =>
      !_disposed && revision == _revision && _identity == _currentIdentity;
  Future<void> submit(String raw) async {
    final revision = ++_revision;
    final next = raw.trim();
    if (next != term) items = const [];
    term = next;
    loading = next.isNotEmpty;
    searched = next.isNotEmpty;
    loadingMore = hasMore = false;
    fetched = 0;
    error = pageError = null;
    _emit();
    if (next.isEmpty) return;
    final request = _request(0);
    final hit = await cache.lookup(request);
    if (!_owns(revision)) return;
    if (hit != null) _accept(parseCatalogPage(hit.json).items, 0);
    try {
      final result = parseCatalogPage(await cache.fetch(auth.client, request));
      if (!_owns(revision)) return;
      _accept(result.items, 0);
    } catch (failure) {
      if (!_owns(revision)) return;
      error = _failure(failure);
      loading = false;
      _emit();
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || loading || loadingMore || term.isEmpty) return;
    final revision = _revision;
    final start = fetched;
    loadingMore = true;
    pageError = null;
    _emit();
    try {
      final page = parseCatalogPage(
        await cache.fetch(auth.client, _request(start)),
      );
      if (!_owns(revision)) return;
      _accept(page.items, start);
    } catch (failure) {
      if (!_owns(revision)) return;
      pageError = _failure(failure);
      loadingMore = false;
      _emit();
    }
  }

  void setWatch(String? next) {
    if (next == watch) {
      return;
    }
    watch = next;
    if (term.isNotEmpty) {
      submit(term);
      return;
    }
    _emit();
  }

  CatalogRequest _request(int startIndex) {
    return catalogSearchRequest(
      userId: auth.client.userId ?? '',
      searchTerm: term,
      startIndex: startIndex,
      filters: watch == null ? null : [watch!],
    );
  }

  void _accept(List<EmbyItem> raw, int start) {
    items = {
      for (final item in [
        ...(start == 0 ? <EmbyItem>[] : items),
        ...raw.where((item) => item.isMovieOrSeries),
      ])
        item.id: item,
    }.values.toList();
    fetched = start + raw.length;
    hasMore = raw.length >= pageSize;
    loading = loadingMore = false;
    _emit();
  }

  EmbyException _failure(Object failure) => failure is EmbyException
      ? failure
      : EmbyException(EmbyFailureKind.unknown, cause: failure);
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
