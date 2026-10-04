import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_sort.dart';

/// 每个片库在首页只预览一屏多一点，完整列表从标题进入。
const int libraryLatestPreview = 12;

final _libraryLatestLoads = _LoadGate(2);

/// 一个片库的最近添加。各端共用这一次请求，画面由 [builder] 决定。
class LibraryLatestData extends StatefulWidget {
  const LibraryLatestData({
    super.key,
    required this.library,
    required this.builder,
  });

  final EmbyItem library;
  final Widget Function(BuildContext context, LibraryLatestSnapshot snapshot)
  builder;

  @override
  State<LibraryLatestData> createState() => _LibraryLatestDataState();
}

class LibraryLatestSnapshot {
  const LibraryLatestSnapshot({
    required this.items,
    required this.loading,
    required this.error,
    required this.retry,
  });

  final List<EmbyItem> items;
  final bool loading;
  final EmbyException? error;
  final VoidCallback retry;
}

class _LibraryLatestDataState extends State<LibraryLatestData> {
  List<EmbyItem> _items = const [];
  var _loading = true;
  EmbyException? _error;
  var _started = false;
  Object? _identity;
  var _generation = 0;
  var _previewRevision = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    final identity = (
      auth.session?.server.id,
      auth.client.baseUrl,
      auth.client.userId,
    );
    final revision = CatalogScope.of(context).libraryPreviewRevision;
    final revisionChanged = _previewRevision != revision;
    if (_started && identity == _identity && !revisionChanged) {
      return;
    }
    final sessionChanged = !_started || identity != _identity;
    _previewRevision = revision;
    if (sessionChanged) {
      _started = true;
      _identity = identity;
      _items = const [];
      _loading = true;
      _error = null;
    } else {
      _error = null;
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LibraryLatestData oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library.id != widget.library.id) {
      _items = const [];
      _loading = true;
      _error = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final identity = _identity;
    bool owns() =>
        mounted && generation == _generation && identity == _identity;
    final catalog = CatalogScope.of(context);
    final request = catalogItemsRequest(
      userId: catalog.client.userId ?? '',
      parentId: widget.library.id,
      includeItemTypes: _latestTypes(widget.library),
      recursive: true,
      limit: libraryLatestPreview,
      // 与片库页默认「更新日期」相同，首页预览才是点进去后的前几项。
      sortBy: CatalogSort.initial.sortBy,
      sortOrder: CatalogSort.initial.sortOrder,
      fields: EmbyClient.homePosterFields,
    );
    final network = _libraryLatestLoads.run<Object?>(
      () async => owns() ? catalog.cache.fetch(catalog.client, request) : null,
    );
    unawaited(network.then<void>((_) {}, onError: (Object _) {}));
    unawaited(() async {
      try {
        final hit = await catalog.cache.lookupWhenReady(request);
        if (!owns() ||
            hit == null ||
            (_items.isNotEmpty || (!_loading && _error == null))) {
          return;
        }
        final cached = parseCatalogPage(hit.json).items;
        if (cached.isEmpty) {
          return;
        }
        setState(() {
          _items = cached;
          _loading = false;
        });
      } catch (_) {
        // A damaged disk row cannot delay the live library response.
      }
    }());
    try {
      final items = await network;
      if (!owns() || items == null) {
        return;
      }
      setState(() {
        _items = parseCatalogPage(items).items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!owns()) {
        return;
      }
      setState(() {
        _error = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      LibraryLatestSnapshot(
        items: _items,
        loading: _loading,
        error: _error,
        retry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          unawaited(_load());
        },
      ),
    );
  }
}

String _latestTypes(EmbyItem library) {
  return switch (library.collectionTypeNormalized) {
    'movies' => 'Movie',
    'tvshows' => 'Series',
    _ => 'Movie,Series',
  };
}

class _LoadGate {
  _LoadGate(this._limit);

  final int _limit;
  var _active = 0;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_active >= _limit) {
      final ticket = Completer<void>();
      _waiters.add(ticket);
      await ticket.future;
    } else {
      _active++;
    }
    try {
      return await job();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}
