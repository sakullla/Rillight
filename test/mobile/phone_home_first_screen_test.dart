import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';

import '../helpers/cupertino_test_app.dart';

/// 首屏续播:头图之后的第一行必须完整落在 360/412 的可视区内，
/// 横向卡片可以直接点开详情。
void main() {
  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets('resume row is visible and tappable on the first screen', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final auth = AuthController.memory();
      final catalog = CatalogController(auth: auth);
      addTearDown(catalog.dispose);
      addTearDown(auth.dispose);
      catalog
        ..resume = CatalogRowState(
          items: [
            MediaItem(
              id: 'ep-1',
              name: '第 1 集',
              type: 'Episode',
              seriesName: '示例剧',
              seriesId: 'series-demo',
              seriesPrimaryImageTag: 'series-poster',
              parentIndexNumber: 1,
              indexNumber: 1,
              userData: const MediaUserData(
                playbackPosition: Duration(minutes: 12),
                playedPercentage: 40,
              ),
            ),
          ],
        )
        ..nextUp = const CatalogRowState(hidden: true)
        // 轮播只吃最近入库:让横幅排在继续观看之上,验证最不利的首屏。
        ..latestMovies = const CatalogRowState(
          items: [
            MediaItem(
              id: 'hero-1',
              name: '新片一',
              type: 'Movie',
              primaryImageTag: 'poster-1',
            ),
            MediaItem(
              id: 'hero-2',
              name: '新片二',
              type: 'Movie',
              primaryImageTag: 'poster-2',
            ),
          ],
        )
        ..latestSeries = const CatalogRowState(hidden: true)
        ..libraries = const [
          MediaItem(
            id: 'view-movies',
            name: '电影',
            type: 'CollectionFolder',
            collectionType: 'movies',
          ),
        ]
        ..librariesLoading = false;

      await tester.pumpWidget(_homeApp(catalog));
      await tester.pump();

      final row = find.byKey(CatalogKeys.resumeRow);
      expect(row, findsOneWidget);
      final rowRect = tester.getRect(row);
      expect(rowRect.top, greaterThanOrEqualTo(0));
      expect(rowRect.top, lessThan(size.height));

      final navTop = tester.getTopLeft(find.byType(PhoneBottomNav)).dy;
      final card = find.byKey(CatalogKeys.item('ep-1'));
      expect(card, findsOneWidget);
      expect(card.hitTestable(), findsOneWidget);
      expect(tester.widget<MobilePressable>(card).onTap, isNotNull);
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(navTop + 0.5));
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);
  }

  testWidgets(
    'latest rows loading keeps the skeleton instead of the empty state',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthController.memory();
      final catalog = CatalogController(auth: auth);
      addTearDown(catalog.dispose);
      addTearDown(auth.dispose);
      // 冷启动:续播和下一集已经回来且为空,最近入库与片库列表还在请求。
      catalog
        ..resume = const CatalogRowState()
        ..nextUp = const CatalogRowState()
        ..latestMovies = const CatalogRowState(loading: true)
        ..latestSeries = const CatalogRowState(loading: true)
        ..librariesLoading = false;

      await tester.pumpWidget(_homeApp(catalog));
      await tester.pump();

      expect(find.byKey(MobileLoadingPlaceholder.homeKey), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);
      expect(find.text('这个服务器还没有内容'), findsNothing);

      // 最近入库返回空、片库列表仍在路上:仍然保持骨架。
      catalog
        ..latestMovies = const CatalogRowState()
        ..latestSeries = const CatalogRowState()
        ..librariesLoading = true
        ..notifyListeners();
      await tester.pump();
      expect(find.byKey(MobileLoadingPlaceholder.homeKey), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);

      // 全部落定且确实没有内容,才换成空态。
      catalog
        ..librariesLoading = false
        ..notifyListeners();
      await tester.pump();
      expect(find.byType(MobileEmptyState), findsOneWidget);
      expect(find.text('这个服务器还没有内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'latest row failures classify the whole page while resume rows are empty',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthController.memory();
      final catalog = CatalogController(auth: auth);
      addTearDown(catalog.dispose);
      addTearDown(auth.dispose);
      // 续播和下一集都空:最近入库行的失败仍应给出整页失败,而不是「空库」。
      catalog
        ..resume = const CatalogRowState()
        ..nextUp = const CatalogRowState()
        ..latestMovies = CatalogRowState(
          error: MediaServerException(
            MediaServerFailureKind.unreachable,
            cause: const OSError('network down', 101),
          ),
        )
        ..latestSeries = const CatalogRowState(hidden: true)
        ..librariesLoading = false;

      await tester.pumpWidget(_homeApp(catalog));
      await tester.pump();

      expect(find.byType(MobileFailureState), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);
      expect(find.text('设备未联网'), findsOneWidget);
      expect(find.text('这个服务器还没有内容'), findsNothing);
      expect(find.text('重试'), findsOneWidget);

      // 服务器拒绝连接:同一位置换成服务器离线文案。
      catalog
        ..latestMovies = CatalogRowState(
          error: MediaServerException(
            MediaServerFailureKind.unreachable,
            cause: const OSError('connection refused', 61),
          ),
        )
        ..notifyListeners();
      await tester.pump();
      expect(find.byType(MobileFailureState), findsOneWidget);
      expect(find.text('无法连接服务器'), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);

      // 最近入库落定、确实没有内容且没有片库时,才回到空态。
      catalog
        ..latestMovies = const CatalogRowState()
        ..librariesLoading = false
        ..notifyListeners();
      await tester.pump();
      expect(find.byType(MobileEmptyState), findsOneWidget);
      expect(find.byType(MobileFailureState), findsNothing);
      expect(find.text('这个服务器还没有内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

Widget _homeApp(CatalogController catalog) {
  return CupertinoTestApp(
    theme: AppUiTheme.dark(),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: [
      AppLocalizations.delegate,
      ...GlobalCupertinoLocalizations.delegates,
    ],
    home: CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: Color(0x00000000),
        middle: Text('首页'),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AuthScope(
            controller: catalog.auth,
            child: CatalogScope(controller: catalog, child: const PhoneHome()),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: PhoneBottomNav(index: 0, floating: true, onSelected: (_) {}),
          ),
        ],
      ),
    ),
  );
}
