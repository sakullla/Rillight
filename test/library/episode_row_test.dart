import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_list.dart';

void main() {
  testWidgets('episode rows stay short enough to scan a season', (
    tester,
  ) async {
    final item = EmbyItem(
      id: 'e1',
      name: '勇者的相遇',
      type: 'Episode',
      indexNumber: 1,
      overview: '很长的本集简介。' * 40,
      runTimeTicks: 23 * 60 * 10000000,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 1200,
              child: EpisodeRow(
                item: item,
                selected: false,
                busyPlayed: false,
                onTap: () {},
                onPlay: () {},
                onTogglePlayed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final row = tester.getRect(find.byType(EpisodeRow));
    final play = tester.getRect(find.byKey(CatalogKeys.episodePlay('e1')));
    final overview = tester.widget<Text>(
      find.descendant(
        of: find.byType(EpisodeRow),
        matching: find.textContaining('很长的本集简介'),
      ),
    );

    expect(row.height, lessThan(150));
    expect(row.right - play.right, lessThan(28));
    expect(overview.maxLines, 2);
    expect(find.text('1. 勇者的相遇'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'series reading scale stays flat through 1080p and trails the panel scale',
    () {
      expect(AppViewport.readingScaleOf(const Size(1920, 1080)), 1);
      expect(
        AppViewport.readingScaleOf(const Size(2560, 1440)),
        closeTo(1.2167, 0.001),
      );
      expect(
        AppViewport.readingScaleOf(const Size(3840, 2160)),
        closeTo(1.65, 0.001),
      );
      expect(
        AppViewport.readingScaleOf(const Size(3840, 2160)),
        lessThan(AppViewport.scaleOf(const Size(3840, 2160))),
      );
      expect(EpisodeRow.thumbWidthFor(const Size(1920, 1080)), 200);
      expect(
        EpisodeRow.thumbWidthFor(const Size(3840, 2160)),
        closeTo(330, 0.1),
      );
    },
  );

  testWidgets('episode title grows on a 4K window without doubling the row', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final item = EmbyItem(
      id: 'e1',
      name: '相遇',
      type: 'Episode',
      indexNumber: 1,
      overview: '简介',
      runTimeTicks: 23 * 60 * 10000000,
    );

    Future<double> titleHeight(Size view) async {
      tester.view.physicalSize = view;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Align(
            alignment: Alignment.topCenter,
            child: AppViewport.readingScope(
              enabled: true,
              child: EpisodeRow(
                item: item,
                selected: false,
                busyPlayed: false,
                onTap: () {},
                onPlay: () {},
                onTogglePlayed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.text('1. 相遇')).height;
    }

    final hd = await titleHeight(const Size(1920, 1080));
    final uhd = await titleHeight(const Size(3840, 2160));
    expect(uhd, greaterThan(hd * 1.4));
    expect(uhd, lessThan(hd * 2));
    final row = tester.getSize(find.byType(EpisodeRow));
    expect(row.height, lessThan(360));
    expect(tester.takeException(), isNull);
  });
}
