import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/cupertino_test_app.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 240), EnginePhase.paint);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump(Duration.zero, EnginePhase.sendSemanticsUpdate);
}

void main() {
  setUp(isolateImageCache);

  // TV 详情头部在 200% 字号下的换行契约：标题与元信息按宽度自然换行，
  // 头部随内容增高，不用省略号截断。这里只泵详情页本体，TV 顶部导航壳层
  // 的 200% 宽度属于导航任务，避免把两件事混在一条断言里。
  testWidgets(
    'long title and meta wrap at 200 percent text instead of clipping',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          ...defaultCatalogItems(),
          FakeEmbyItem(
            id: 'movie-long-title',
            name: '在世界尽头呼唤爱的漫长旅程：导演剪辑特别收藏版',
            type: 'Movie',
            overview: '一段横跨三座城市与两个时代的漫长旅程，所有人都在寻找同一个答案。',
            productionYear: 2024,
            runtime: const Duration(minutes: 158),
            communityRating: 8.7,
            genres: const ['剧情', '奇幻', '冒险'],
          ),
        ],
      );
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final auth = SyntheticSourceAuth(
        adapter: FakeEmbyAdapter([server]),
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'tv',
          deviceId: 'tv-detail-scale',
          version: '1',
        ),
        libraryIds: {'view-movies'},
      );
      addTearDown(auth.dispose);
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      expect(auth.isLoggedIn, isTrue);
      final catalog = CatalogController(auth: auth);
      addTearDown(catalog.dispose);

      await tester.pumpWidget(
        CupertinoTestApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppUiTheme.tvDark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child ?? const SizedBox.shrink(),
          ),
          home: PresentationScope(
            environment: PresentationEnvironment.tv,
            child: AuthScope(
              controller: auth,
              child: CatalogScope(
                controller: catalog,
                child: const TvDetailPage(itemId: 'movie-long-title'),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);

      final title = find.byKey(const Key('tv-detail-title'));
      expect(title, findsOneWidget);
      final titleWidget = tester.widget<Text>(title);
      expect(titleWidget.maxLines, isNull);
      expect(titleWidget.overflow, isNull);
      final titleLine = tester.renderObject<RenderParagraph>(title);
      expect(titleLine.didExceedMaxLines, isFalse);
      expect(
        titleLine.size.height,
        greaterThan(titleLine.getMaxIntrinsicHeight(double.infinity)),
        reason: 'long title should occupy more than one line at 200% text',
      );

      final meta = find.byKey(const Key('tv-detail-meta'));
      expect(meta, findsOneWidget);
      final metaWidget = tester.widget<Text>(meta);
      expect(metaWidget.maxLines, isNull);
      expect(metaWidget.overflow, isNull);
      final metaLine = tester.renderObject<RenderParagraph>(meta);
      expect(metaLine.didExceedMaxLines, isFalse);
      expect(
        metaLine.size.height,
        greaterThan(metaLine.getMaxIntrinsicHeight(double.infinity)),
        reason: 'long meta line should wrap instead of being clipped',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
