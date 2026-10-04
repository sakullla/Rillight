import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/library_latest_row.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'home',
  deviceId: 'library-latest-row',
  version: '1',
);

const _library = EmbyItem(
  id: 'view-tv',
  name: '剧集',
  type: 'CollectionFolder',
  collectionType: 'tvshows',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'library preview matches updated order and refreshes with the home',
    (tester) async {
      final server = FakeEmbyServer();
      server.items = [
        FakeEmbyItem(
          id: 'series-old-add',
          name: '最近更新',
          type: 'Series',
          parentId: 'view-tv',
          dateCreated: DateTime.utc(2020, 1, 1),
          dateLastContentAdded: DateTime.utc(2026, 8, 1),
        ),
        FakeEmbyItem(
          id: 'series-new-add',
          name: '只是新入库',
          type: 'Series',
          parentId: 'view-tv',
          dateCreated: DateTime.utc(2026, 9, 1),
          dateLastContentAdded: DateTime.utc(2024, 1, 1),
        ),
      ];
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      final catalog = CatalogController(
        auth: auth,
        cache: CatalogCache()..debugSetDiskStore(null),
      );
      addTearDown(catalog.dispose);

      await tester.pumpWidget(
        AuthScope(
          controller: auth,
          child: CatalogScope(
            controller: catalog,
            child: const MaterialApp(
              locale: Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: LibraryLatestData(library: _library, builder: _names),
              ),
            ),
          ),
        ),
      );
      await _until(tester, find.text('最近更新'));

      expect(
        server.requests.where(
          (request) =>
              request.contains('ParentId=view-tv') &&
              request.contains('IncludeItemTypes=Series') &&
              request.contains('SortBy=DateLastContentAdded') &&
              request.contains('SortOrder=Descending'),
        ),
        isNotEmpty,
      );
      expect(
        tester.getTopLeft(find.text('最近更新')).dy,
        lessThan(tester.getTopLeft(find.text('只是新入库')).dy),
      );

      final before = server.requests.length;
      server.items = [
        ...server.items,
        FakeEmbyItem(
          id: 'series-fresh',
          name: '刚更新',
          type: 'Series',
          parentId: 'view-tv',
          dateCreated: DateTime.utc(2026, 10, 1),
          dateLastContentAdded: DateTime.utc(2026, 10, 2),
        ),
      ];
      await tester.runAsync(() => catalog.reload(showCachedFirst: false));
      await _until(tester, find.text('刚更新'));

      expect(server.requests.length, greaterThan(before));
      expect(
        tester.getTopLeft(find.text('刚更新')).dy,
        lessThan(tester.getTopLeft(find.text('最近更新')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _names(BuildContext context, LibraryLatestSnapshot snapshot) {
  return Column(children: [for (final item in snapshot.items) Text(item.name)]);
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}
