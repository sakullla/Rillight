import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';

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
  setUp(isolateImageCache);
  late _FilteringEmbyServer server;
  late FakeEmbyAdapter adapter;
  late RillightApp app;

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
    app = RillightApp(auth: auth);
    return auth;
  }

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    app.router.go('/library/$viewId');
    await tester.pumpWidget(app);
    await settle(tester);
  }

  Future<void> tapFilter(WidgetTester tester, String dimension) async {
    if (find.byKey(gridFilterKey(dimension)).evaluate().isEmpty) {
      await tapBelowTopBar(tester, find.byKey(gridFilterMenuKey));
      await settle(tester);
    }
    await tester.ensureVisible(find.byKey(gridFilterKey(dimension)));
    await settle(tester);
  }

  Future<void> chooseOption(
    WidgetTester tester,
    String dimension,
    String value,
  ) async {
    // 面板为草稿式:点选项只暂存,点「确定」才生效并关闭面板。
    await tester.ensureVisible(find.byKey(gridFilterOption(dimension, value)));
    await tester.tap(find.byKey(gridFilterOption(dimension, value)));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, '确定'));
    await settle(tester);
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

  testWidgets('filter confirm, type, and year share one logged-in pump', (
    tester,
  ) async {
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
    await openLibrary(tester, 'view-movies');
    final before = posterNames(tester);

    await tapBelowTopBar(tester, find.byKey(gridFilterMenuKey));
    await settle(tester);
    await tester.tap(find.byKey(gridFilterOption('watch', 'IsPlayed')));
    await settle(tester);

    // 未点确定:网格不变,面板仍开着。
    expect(posterNames(tester), before);
    expect(find.byKey(gridFilterPanelKey), findsOneWidget);

    // 取消:丢弃草稿并关闭,网格仍不变。
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);
    expect(find.byKey(gridFilterPanelKey), findsNothing);
    expect(posterNames(tester), before);

    // 重开面板,选择后点确定才生效。
    await tapBelowTopBar(tester, find.byKey(gridFilterMenuKey));
    await settle(tester);
    await tester.tap(find.byKey(gridFilterOption('watch', 'IsPlayed')));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, '确定'));
    await settle(tester);
    expect(find.byKey(gridFilterPanelKey), findsNothing);
    expect(posterNames(tester), isNot(before));

    await openLibrary(tester, 'view-untyped');
    expect(posterNames(tester), containsAll(['未分类型电影', '新电影', '新剧集', '老剧集']));

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

    await tapFilter(tester, 'year');
    await chooseOption(tester, 'year', '2025');
    expect(posterNames(tester), ['新电影']);
    expect(
      server.requests.last,
      allOf(contains('IncludeItemTypes=Movie'), contains('Years=2025')),
      reason: '类型与年份组合在同一次请求中生效',
    );

    await tapBelowTopBar(tester, find.byKey(gridFilterClearKey));
    await settle(tester);
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
  }, tags: ['integration']);
}
