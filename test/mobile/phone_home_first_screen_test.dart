import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home.dart';
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
