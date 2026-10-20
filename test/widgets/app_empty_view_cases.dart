import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/login_widgets.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/media_server/models.dart';

void main() {
  testWidgets('AppEmptyView shows icon, message and optional action', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: const CupertinoPageScaffold(
          child: AppEmptyView(message: '这里什么都没有', actionLabel: '刷新'),
        ),
      ),
    );
    expect(find.text('这里什么都没有'), findsOneWidget);
    expect(find.byIcon(AppIcons.empty), findsOneWidget);
    // 未提供 onAction 时不渲染按钮。
    expect(find.byType(AppButton), findsNothing);

    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: AppEmptyView(
            message: '这里什么都没有',
            actionLabel: '刷新',
            onAction: () => actions++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('刷新'));
    expect(actions, 1);
  });

  testWidgets('decorative fills without artwork are solid surfaces', (
    tester,
  ) async {
    const placeholderKey = Key('library-placeholder');
    for (final theme in [AppUiTheme.dark(), AppUiTheme.light()]) {
      final colors = theme.colorScheme;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          home: CupertinoPageScaffold(
            child: SingleChildScrollView(
              child: Column(
                children: const [
                  SizedBox(height: 260, child: AppEmptyView(message: '空')),
                  SizedBox(width: 120, height: 180, child: PosterPlaceholder()),
                  SizedBox(
                    width: 320,
                    height: 180,
                    child: PhoneLibraryTile(
                      library: MediaItem(
                        id: 'library-movies',
                        name: '电影',
                        type: 'CollectionFolder',
                        collectionType: 'movies',
                      ),
                      placeholderKey: placeholderKey,
                    ),
                  ),
                  Center(child: LoginBrandMark()),
                  Center(
                    child: HeroDots(
                      index: 0,
                      count: 3,
                      onSelect: null,
                      onScrim: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      BoxDecoration decorationIn(Finder scope) => tester
          .widgetList<DecoratedBox>(
            find.descendant(of: scope, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.color != null);

      final empty = decorationIn(find.byType(AppEmptyView));
      expect(empty.gradient, isNull);
      expect(empty.color, colors.surfaceContainerHigh);

      final poster = decorationIn(find.byType(PosterPlaceholder));
      expect(poster.gradient, isNull);
      expect(poster.color, colors.surfaceContainerHigh);

      final tile =
          tester.widget<DecoratedBox>(find.byKey(placeholderKey)).decoration
              as BoxDecoration;
      expect(tile.gradient, isNull);
      // 无封面磁贴两种主题都是深底白字,取深色表面阶梯的实色。
      expect(tile.color, AppPalette.darkTones.surfaceHigh);

      final mark =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(LoginBrandMark),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(mark.gradient, isNull);
      expect(mark.boxShadow, isNull);
      expect(mark.color, colors.primary);

      // 页面上(不压图)的轮播选中长条跟随 primary,不再用 secondary。
      final pill = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(HeroDots),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(pill.color, colors.primary);
    }
  });
}
