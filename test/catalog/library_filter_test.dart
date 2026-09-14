import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/app/widgets/skeleton.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/top_bar_hit.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-library-filters',
  version: '0.1.0',
);

/// 带流派字段的条目:toJson 注入 Genres,供客户端聚合流派取值。
class _GenreItem extends FakeEmbyItem {
  _GenreItem({
    required super.id,
    required super.name,
    required super.type,
    required super.parentId,
    required this.genres,
    super.productionYear,
    super.dateCreated,
    super.played,
  });

  final List<String> genres;

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json['Genres'] = genres;
    return json;
  }
}

/// 在 /Users/{id}/Items 上实现 Filters/Genres/Years 服务端筛选语义的假服务器。
///
/// 基础 FakeEmbyServer 不支持这些参数;本类只拦截携带筛选参数的网格请求,
/// 其余(认证/首页行/详情等)全部委托给原实现。
class _FilteringEmbyServer extends FakeEmbyServer {
  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final method = options.method.toUpperCase();
    final query = options.uri.queryParameters;
    final hasFilterParams =
        query.containsKey('Filters') ||
        query.containsKey('Genres') ||
        query.containsKey('Years');
    if (method == 'GET' &&
        options.uri.path == '/Users/user-alice/Items' &&
        hasFilterParams) {
      requests.add(
        options.uri.query.isEmpty
            ? 'GET ${options.uri.path}'
            : 'GET ${options.uri.path}?${options.uri.query}',
      );
      return _filteredItems(options);
    }
    return super.handle(options, requestStream);
  }

  ResponseBody _filteredItems(RequestOptions options) {
    final q = options.uri.queryParameters;
    final parentId = q['ParentId'];
    final recursive = (q['Recursive'] ?? 'false').toLowerCase() == 'true';
    final types = _splitValues(q['IncludeItemTypes']);
    final filters = _splitValues(q['Filters']);
    final genres = _splitValues(q['Genres']);
    final years = _splitValues(
      q['Years'],
    ).map(int.tryParse).whereType<int>().toSet();

    var matched = items.where((item) {
      if (types.isNotEmpty && !types.contains(item.type)) {
        return false;
      }
      if (parentId != null &&
          parentId.isNotEmpty &&
          !_belongsTo(item, parentId, recursive: recursive)) {
        return false;
      }
      if (filters.contains('IsPlayed') && !item.played) {
        return false;
      }
      if (filters.contains('IsUnplayed') && item.played) {
        return false;
      }
      if (years.isNotEmpty && !years.contains(item.productionYear)) {
        return false;
      }
      if (genres.isNotEmpty) {
        final itemGenres = item is _GenreItem ? item.genres : const <String>[];
        if (!itemGenres.any(genres.contains)) {
          return false;
        }
      }
      return true;
    }).toList();

    final sortBy = q['SortBy'] ?? '';
    final descending = (q['SortOrder'] ?? '').toLowerCase() == 'descending';
    if (sortBy.isNotEmpty) {
      matched.sort((a, b) {
        final compared = _compareBy(a, b, sortBy);
        return descending ? -compared : compared;
      });
    }
    final total = matched.length;
    final startIndex = int.tryParse(q['StartIndex'] ?? '') ?? 0;
    if (startIndex > 0) {
      matched = matched.skip(startIndex).toList();
    }
    final limit = int.tryParse(q['Limit'] ?? '');
    if (limit != null && limit >= 0) {
      matched = matched.take(limit).toList();
    }
    return ResponseBody.fromString(
      jsonEncode({
        'Items': [for (final item in matched) item.toJson()],
        'TotalRecordCount': total,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  static Set<String> _splitValues(String? raw) {
    return (raw ?? '')
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static int _compareBy(FakeEmbyItem a, FakeEmbyItem b, String sortBy) {
    switch (sortBy) {
      case 'SortName':
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'DateLastContentAdded':
      case 'DateModified':
        return a.dateLastContentAdded.compareTo(b.dateLastContentAdded);
      case 'DateCreated':
        return a.dateCreated.compareTo(b.dateCreated);
      case 'ProductionYear':
        return (a.productionYear ?? 0).compareTo(b.productionYear ?? 0);
      default:
        return 0;
    }
  }

  bool _belongsTo(
    FakeEmbyItem item,
    String parentId, {
    required bool recursive,
  }) {
    if (item.parentId == parentId) {
      return true;
    }
    if (!recursive) {
      return false;
    }
    var current = item.parentId;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      if (current == parentId) {
        return true;
      }
      current = _itemByIdPublic(current)?.parentId;
    }
    return false;
  }

  FakeEmbyItem? _itemByIdPublic(String id) {
    for (final item in items) {
      if (item.id == id) {
        return item;
      }
    }
    for (final view in views) {
      if (view.id == id) {
        return view;
      }
    }
    return null;
  }
}

void main() {
  late _FilteringEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = _FilteringEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  Future<AuthController> pumpLoggedIn(WidgetTester tester) async {
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();
    return auth;
  }

  Future<void> goHome(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      final home = find.byKey(AppShell.homeNavKey);
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home);
        await tester.pumpAndSettle();
        return;
      }
      final back = find.byKey(CatalogKeys.back);
      if (back.evaluate().isEmpty) {
        return;
      }
      await tester.tap(back);
      await tester.pumpAndSettle();
    }
  }

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    await goHome(tester);
    final tile = find.byKey(CatalogKeys.library(viewId));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> tapFilter(WidgetTester tester, String dimension) async {
    if (find.byKey(gridFilterKey(dimension)).evaluate().isEmpty) {
      await tapBelowTopBar(tester, find.byKey(gridFilterMenuKey));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(gridFilterKey(dimension)));
    await tester.pumpAndSettle();
  }

  Future<void> chooseOption(
    WidgetTester tester,
    String dimension,
    String value,
  ) async {
    await tester.tap(find.byKey(gridFilterOption(dimension, value)));
    await tester.pumpAndSettle();
  }

  List<String> posterNames(WidgetTester tester) {
    return tester
        .widgetList<PosterCard>(
          find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(PosterCard),
          ),
        )
        .map((card) => card.item.name)
        .toList();
  }

  testWidgets('library header offers the four filter dimensions', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');

    expect(find.byKey(gridFilterMenuKey), findsOneWidget);
    expect(find.byKey(gridFilterKey('watch')), findsNothing);
    expect(find.byKey(gridFilterClearKey), findsNothing);
    expect(find.byKey(CatalogKeys.sortBy), findsOneWidget);
    expect(find.byKey(gridRefreshKey), findsOneWidget);

    await tapBelowTopBar(tester, find.byKey(gridFilterMenuKey));
    await tester.pumpAndSettle();
    expect(find.byKey(gridFilterKey('watch')), findsOneWidget);
    expect(find.byKey(gridFilterKey('year')), findsOneWidget);
    expect(find.byKey(gridFilterKey('genre')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '确定'));
    await tester.pumpAndSettle();

    // 非片库来源(最近更新电影更多页)不显示筛选控件。
    await goHome(tester);
    final more = find.byKey(
      CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies),
    );
    await tester.ensureVisible(more);
    await tapBelowTopBar(tester, more);
    await tester.pumpAndSettle();
    expect(find.byKey(gridFilterKey('watch')), findsNothing);
    expect(find.byKey(CatalogKeys.sortBy), findsOneWidget);
  });

  testWidgets(
    'type plus year combined filter narrows the grid and clearing restores',
    (tester) async {
      server.items.addAll([
        _GenreItem(
          id: 'movie-2025',
          name: '新电影',
          type: 'Movie',
          parentId: 'view-untyped',
          productionYear: 2025,
          genres: const ['科幻'],
          dateCreated: DateTime.utc(2026, 3, 1),
        ),
        _GenreItem(
          id: 'series-2025',
          name: '新剧集',
          type: 'Series',
          parentId: 'view-untyped',
          productionYear: 2025,
          genres: const ['科幻'],
          dateCreated: DateTime.utc(2026, 3, 2),
        ),
        _GenreItem(
          id: 'series-old',
          name: '老剧集',
          type: 'Series',
          parentId: 'view-untyped',
          productionYear: 1999,
          genres: const ['喜剧'],
          dateCreated: DateTime.utc(2026, 3, 3),
        ),
      ]);
      await pumpLoggedIn(tester);
      await openLibrary(tester, 'view-untyped');

      expect(posterNames(tester), containsAll(['未分类型电影', '新电影', '新剧集', '老剧集']));

      // 类型=电影。
      await tapFilter(tester, 'type');
      await chooseOption(tester, 'type', 'Movie');
      expect(posterNames(tester), containsAll(['未分类型电影', '新电影']));
      expect(posterNames(tester), isNot(contains('新剧集')));
      expect(
        server.requests.any(
          (request) =>
              request.contains('ParentId=view-untyped') &&
              request.contains('IncludeItemTypes=Movie'),
        ),
        isTrue,
      );

      // 叠加 年份=2025:组合筛选结果只剩新电影。
      await tapFilter(tester, 'year');
      await chooseOption(tester, 'year', '2025');
      expect(posterNames(tester), ['新电影']);
      expect(
        server.requests.last,
        allOf(contains('IncludeItemTypes=Movie'), contains('Years=2025')),
        reason: '类型与年份组合在同一次请求中生效',
      );

      // 清除全部:恢复完整网格。
      await tapBelowTopBar(tester, find.byKey(gridFilterClearKey));
      await tester.pumpAndSettle();
      expect(posterNames(tester), containsAll(['未分类型电影', '新电影', '新剧集', '老剧集']));
      expect(
        server.requests.last,
        allOf(
          isNot(contains('Years=')),
          isNot(contains('Filters=')),
          contains('IncludeItemTypes=Movie%2CSeries'),
        ),
        reason: '清除后请求回到无筛选形态',
      );
      expect(find.byKey(gridFilterClearKey), findsNothing);
    },
  );

  testWidgets('watched filter narrows by IsPlayed and IsUnplayed', (
    tester,
  ) async {
    server.items.add(
      _GenreItem(
        id: 'movie-watched',
        name: '已看过的片',
        type: 'Movie',
        parentId: 'view-movies',
        genres: const [],
        played: true,
        dateCreated: DateTime.utc(2026, 4, 1),
      ),
    );
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    expect(posterNames(tester), contains('已看过的片'));

    // 已看=未看。
    await tapFilter(tester, 'watch');
    await chooseOption(tester, 'watch', 'IsUnplayed');
    expect(posterNames(tester), isNot(contains('已看过的片')));
    expect(posterNames(tester), contains('Inception'));
    expect(server.requests.last, contains('Filters=IsUnplayed'));

    // 已看=已看。
    await tapFilter(tester, 'watch');
    await chooseOption(tester, 'watch', 'IsPlayed');
    expect(posterNames(tester), ['已看过的片']);
    expect(server.requests.last, contains('Filters=IsPlayed'));

    // 菜单内选「全部」清除该维度。
    await tapFilter(tester, 'watch');
    await chooseOption(tester, 'watch', 'all');
    expect(posterNames(tester), contains('已看过的片'));
    expect(posterNames(tester), contains('Inception'));
    expect(server.requests.last, isNot(contains('Filters=')));
  });

  testWidgets('genre filter narrows by Genres', (tester) async {
    server.items.addAll([
      _GenreItem(
        id: 'movie-scifi',
        name: '科幻片',
        type: 'Movie',
        parentId: 'view-movies',
        genres: const ['科幻'],
        dateCreated: DateTime.utc(2026, 5, 1),
      ),
      _GenreItem(
        id: 'movie-comedy',
        name: '喜剧片',
        type: 'Movie',
        parentId: 'view-movies',
        genres: const ['喜剧'],
        dateCreated: DateTime.utc(2026, 5, 2),
      ),
    ]);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');

    // 流派取值从已加载条目聚合。
    await tapFilter(tester, 'genre');
    expect(find.byKey(gridFilterOption('genre', '科幻')), findsOneWidget);
    expect(find.byKey(gridFilterOption('genre', '喜剧')), findsOneWidget);
    await chooseOption(tester, 'genre', '科幻');

    expect(posterNames(tester), ['科幻片']);
    expect(
      server.requests.last,
      contains('Genres=${Uri.encodeQueryComponent('科幻')}'),
    );

    await tapBelowTopBar(tester, find.byKey(gridFilterClearKey));
    await tester.pumpAndSettle();
    expect(posterNames(tester), contains('科幻片'));
    expect(posterNames(tester), contains('喜剧片'));
  });

  testWidgets('filters combine with the existing sort options', (tester) async {
    server.items.addAll([
      _GenreItem(
        id: 'movie-zeta',
        name: 'Zeta',
        type: 'Movie',
        parentId: 'view-untyped',
        productionYear: 2025,
        genres: const [],
        dateCreated: DateTime.utc(2026, 6, 1),
      ),
      _GenreItem(
        id: 'movie-alpha',
        name: 'Alpha',
        type: 'Movie',
        parentId: 'view-untyped',
        productionYear: 2025,
        genres: const [],
        dateCreated: DateTime.utc(2026, 6, 2),
      ),
    ]);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-untyped');

    // 类型=电影 + 年份=2025。
    await tapFilter(tester, 'type');
    await chooseOption(tester, 'type', 'Movie');
    await tapFilter(tester, 'year');
    await chooseOption(tester, 'year', '2025');

    // 与现有排序组合:按标题升序。
    await tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
    await tester.pumpAndSettle();

    expect(posterNames(tester), ['Alpha', 'Zeta']);
    expect(posterNames(tester).first, 'Alpha');
    expect(
      server.requests.last,
      allOf(
        contains('IncludeItemTypes=Movie'),
        contains('Years=2025'),
        contains('SortBy=SortName'),
        contains('SortOrder=Ascending'),
      ),
      reason: '筛选与排序在同一次请求中组合生效',
    );

    // 现有排序选项全部保留。
    await tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
    await tester.pumpAndSettle();
    expect(
      find.byKey(CatalogKeys.sortOption('DateLastContentAdded')),
      findsOneWidget,
    );
    expect(find.byKey(CatalogKeys.sortOption('DateCreated')), findsOneWidget);
    expect(find.byKey(CatalogKeys.sortOption('SortName')), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.sortOption('ProductionYear')),
      findsOneWidget,
    );
    expect(
      find.byKey(CatalogKeys.sortOption('CommunityRating')),
      findsOneWidget,
    );
    expect(find.byKey(CatalogKeys.sortOption('Random')), findsOneWidget);
  });

  testWidgets('changing filters refreshes incrementally without a skeleton', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    expect(posterNames(tester), isNotEmpty);

    await tapFilter(tester, 'watch');
    // 切筛选不清空整页:刷新期间旧内容仍在,不出现整页骨架屏。
    var sawSkeleton = false;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(SkeletonPosterGrid).evaluate().isNotEmpty) {
        sawSkeleton = true;
      }
    }
    expect(sawSkeleton, isFalse);
    expect(find.byType(PosterCard), findsWidgets);
    await tester.pumpAndSettle();
    expect(posterNames(tester), isNotEmpty);
  });
}
