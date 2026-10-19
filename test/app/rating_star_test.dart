import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme/brand.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_server/models.dart';

import '../helpers/cupertino_test_app.dart';

const _item = MediaItem(
  id: 'rating-item',
  name: '评分条目',
  type: 'Movie',
  productionYear: 2024,
  communityRating: 8.6,
);

Color? _starColor(WidgetTester tester) {
  final icons = tester.widgetList<Icon>(find.byIcon(AppIcons.star)).toList();
  expect(icons, isNotEmpty);
  return icons.first.color;
}

void main() {
  for (final theme in [AppUiTheme.dark(), AppUiTheme.light()]) {
    final brightness = theme.brightness;

    testWidgets('hero rating badge uses brand star in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          home: const Center(child: HeroRatingBadge(rating: 8.6)),
        ),
      );
      // 徽标压在图片遮罩上,即使浅色主题也用亮金。
      final star = tester.widget<Icon>(find.byType(Icon).first);
      expect(star.color, AppBrand.ratingStarDark);
    });

    testWidgets('poster rating meta uses brand star in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          home: Center(
            child: PosterCard(item: _item, onTap: () {}, width: 140),
          ),
        ),
      );
      await tester.pump();
      expect(_starColor(tester), AppBrand.ratingStar(brightness));
    });

    testWidgets('phone poster rating uses brand star in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          home: Center(
            child: SizedBox(
              width: 180,
              child: PhonePosterCard(item: _item, onTap: () {}),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_starColor(tester), AppBrand.ratingStar(brightness));
    });
  }

  testWidgets('rating badge outside the scrim follows the light star', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.light(),
        home: const Center(child: HeroRatingBadge(rating: 8.6, onScrim: false)),
      ),
    );
    final star = tester.widget<Icon>(find.byType(Icon).first);
    expect(star.color, AppBrand.ratingStar(Brightness.light));
  });
}
