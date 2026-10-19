import '../helpers/cupertino_test_app.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../emby/fake_emby_server.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/media_server/device.dart';

const _statusKey = Key('aggregation-search-status');
const _headerKey = Key('aggregation-search-header');
const _keywordKey = Key('aggregation-keyword');

class _Harness {
  _Harness(this.server, this.auth, this.catalog);

  final FakeEmbyServer server;
  final AuthController auth;
  final CatalogController catalog;
}

Future<_Harness> _open(
  WidgetTester tester, {
  required PresentationEnvironment presentation,
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final server = FakeEmbyServer(
    serverId: 'search-server',
    serverName: '搜索来源',
    items: [FakeEmbyItem(id: 'search-film', name: 'Film One', type: 'Movie')],
  );
  final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
  final auth = AuthController.memory(
    client: EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'search-surface',
        deviceId: 'search-surface',
        version: '1',
      ),
      dio: dio,
    ),
  );
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
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    catalog.dispose();
    auth.dispose();
  });

  // 固定焦点节点:避免自动聚焦的光标闪烁让 pumpAndSettle 永不收敛。
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: CatalogScope(
        controller: catalog,
        child: CupertinoTestApp(
          theme: AppUiTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          home: PresentationScope(
            environment: presentation,
            child: CupertinoPageScaffold(
              child: AggregationPage(search: true, searchFocusNode: focus),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
  return _Harness(server, auth, catalog);
}

Future<void> _submitSearch(WidgetTester tester, String term) async {
  await tester.enterText(find.byKey(_keywordKey), term);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await settle(tester);
}

void _expectHeaderBar(WidgetTester tester) {
  final header = tester.widget<DecoratedBox>(find.byKey(_headerKey));
  final decoration = header.decoration as BoxDecoration;
  expect(decoration.color, isNotNull);
  final border = decoration.border as Border;
  expect(border.bottom.style, BorderStyle.solid);
  expect(border.bottom.color, AppEdge.of(Brightness.dark));
}

void _expectStatusCard(WidgetTester tester, String message) {
  final status = find.byKey(_statusKey);
  expect(status, findsOneWidget);
  expect(
    find.descendant(of: status, matching: find.text(message)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: status, matching: find.byIcon(AppIcons.error)),
    findsOneWidget,
  );
  final card = tester.widget<DecoratedBox>(
    find.descendant(of: status, matching: find.byType(DecoratedBox)).first,
  );
  expect(
    (card.decoration as BoxDecoration).color,
    AppUiTheme.dark().colorScheme.errorContainer,
  );
}

void main() {
  setUp(isolateImageCache);

  testWidgets(
    'desktop production search uses the unified bar and failure card',
    (tester) async {
      final h = await _open(
        tester,
        presentation: PresentationEnvironment.desktop,
        size: const Size(1280, 800),
      );
      _expectHeaderBar(tester);
      expect(find.text('想看点什么？'), findsOneWidget);

      await _submitSearch(tester, 'Film');
      expect(find.text(h.server.serverName), findsOneWidget);
      expect(find.byType(MediaShelf), findsOneWidget);

      h.server.searchStatus = 500;
      await _submitSearch(tester, 'Film');
      _expectStatusCard(tester, '所选来源全部失败，请逐来源重试');
      expect(find.textContaining('HTTP 500'), findsWidgets);
    },
    tags: ['integration'],
  );

  testWidgets(
    'phone production search keeps segmented results and the failure card',
    (tester) async {
      final h = await _open(
        tester,
        presentation: PresentationEnvironment.phone,
        size: const Size(360, 800),
      );
      _expectHeaderBar(tester);
      expect(find.text('想看点什么？'), findsOneWidget);

      await _submitSearch(tester, 'Film');
      // 搜索结果按 SavedServer.id 分段,不是服务器自带 id。
      final savedId = h.auth.sources.project().first.id;
      final section = find.byKey(ValueKey('aggregation-search-$savedId'));
      expect(section, findsOneWidget);
      expect(
        find.descendant(of: section, matching: find.text('1 个结果')),
        findsOneWidget,
      );

      h.server.searchStatus = 503;
      await _submitSearch(tester, 'Film');
      _expectStatusCard(tester, '所选来源全部失败，请逐来源重试');
    },
    tags: ['integration'],
  );

  testWidgets('tv production search uses the same failure card', (
    tester,
  ) async {
    final h = await _open(
      tester,
      presentation: PresentationEnvironment.tv,
      size: const Size(1920, 1080),
    );

    await tester.tap(find.byKey(_keywordKey));
    await settle(tester);
    final editor = find.byKey(const Key('tv-input-editor'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'Film');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    final savedId = h.auth.sources.project().first.id;
    expect(find.byKey(ValueKey('aggregation-search-$savedId')), findsOneWidget);

    h.server.searchStatus = 500;
    await tester.tap(find.byKey(_keywordKey));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('tv-input-editor')), 'Film');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    _expectStatusCard(tester, '所选来源全部失败，请逐来源重试');
  }, tags: ['integration']);
}
