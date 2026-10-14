import 'package:rillight/app/ui/ui.dart' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_list.dart';

void main() {
  testWidgets('episode cards stay compact enough to scan a season', (
    tester,
  ) async {
    final item = MediaItem(
      id: 'e1',
      name: '勇者的相遇',
      type: 'Episode',
      indexNumber: 1,
      overview: '很长的本集简介。' * 40,
      runtime: Duration(microseconds: (23 * 60 * 10000000) ~/ 10),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...AppLocalizations.localizationsDelegates,
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 300,
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
        builder: (context, child) => ui.AppUiTheme(
          data: Theme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
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

    // 剧照在上，播放落在剧照上，标题与两行简介在下。
    expect(row.height, lessThan(300));
    // 播放圆钮居中压在剧照上，标题在剧照下面。
    final thumbHeight = (row.width - 16) * 9 / 16;
    expect(play.center.dx, closeTo(row.center.dx, 1));
    expect(play.center.dy, closeTo(row.top + 8 + thumbHeight / 2, 1));
    expect(play.width, lessThan(row.width / 2));
    expect(
      tester.getRect(find.text('1. 勇者的相遇')).top,
      greaterThan(row.top + 8 + thumbHeight),
    );
    expect(overview.maxLines, 2);
    expect(find.text('1. 勇者的相遇'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'thumbnail plays directly while the row opens details; watched badge and progress bar show',
    (tester) async {
      var played = 0;
      var opened = 0;
      Widget row(MediaItem item) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...AppLocalizations.localizationsDelegates,
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: EpisodeRow(
                item: item,
                selected: false,
                busyPlayed: false,
                onTap: () => opened++,
                onPlay: () => played++,
                onTogglePlayed: () {},
              ),
            ),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: Theme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      );
      await tester.pumpWidget(
        row(
          const MediaItem(
            id: 'e2',
            name: '半途',
            type: 'Episode',
            indexNumber: 2,
            runtime: Duration(microseconds: (24 * 60 * 10000000) ~/ 10),
            userData: MediaUserData(
              playbackPosition: Duration(
                microseconds: (10 * 60 * 10000000) ~/ 10,
              ),
            ),
          ),
        ),
      );
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(find.text('24分钟'), findsOneWidget);
      expect(find.text('剩余 14 分钟'), findsNothing);
      expect(find.textContaining('已看'), findsNothing);
      expect(find.byKey(const ValueKey('episode-progress-e2')), findsOneWidget);
      expect(find.bySemanticsLabel('已看 42%'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('episode-thumb-play-e2')));
      await tester.pump();
      expect(played, 1);
      expect(opened, 0);
      // 剧照上圆钮以外的位置与卡片其余部分一样进入集详情。
      final card = tester.getRect(find.byType(EpisodeRow));
      await tester.tapAt(card.topLeft + const Offset(24, 24));
      await tester.pump();
      expect(played, 1);
      expect(opened, 1);
      opened = 0;
      await tester.tap(find.text('2. 半途'));
      await tester.pump();
      expect(opened, 1);

      await tester.pumpWidget(
        row(
          const MediaItem(
            id: 'e3',
            name: '看完',
            type: 'Episode',
            indexNumber: 3,
            userData: MediaUserData(played: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(EpisodeWatchedBadge), findsOneWidget);
      expect(find.textContaining('剩余'), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('a resumable episode keeps its premiere date in body color', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...AppLocalizations.localizationsDelegates,
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: EpisodeRow(
                item: MediaItem(
                  id: 'e4',
                  name: '续看',
                  type: 'Episode',
                  indexNumber: 4,
                  premiereDate: DateTime(2024, 5, 2),
                  runtime: Duration(microseconds: (24 * 60 * 10000000) ~/ 10),
                  userData: const MediaUserData(
                    playbackPosition: Duration(
                      microseconds: (10 * 60 * 10000000) ~/ 10,
                    ),
                  ),
                ),
                selected: false,
                busyPlayed: false,
                onTap: () {},
                onPlay: () {},
                onTogglePlayed: () {},
              ),
            ),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: Theme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    final date = tester.widget<Text>(find.text('2024-05-02'));
    final scheme = ui.AppUiTheme.of(tester.element(find.text('2024-05-02')))
        .colorScheme;
    expect(date.style?.color, scheme.onSurfaceVariant);
    expect(date.style?.fontWeight, isNot(FontWeight.w600));
    expect(find.byKey(const ValueKey('episode-progress-e4')), findsOneWidget);
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
      // 网格最窄卡 272（剧照再减两侧 8 的内边距），随阅读缩放放大。
      expect(EpisodeRow.thumbWidthFor(const Size(1920, 1080)), 256);
      expect(
        EpisodeRow.thumbWidthFor(const Size(3840, 2160)),
        closeTo(272 * 1.65 - 16, 0.1),
      );
    },
  );

  testWidgets('episode title grows on a 4K window without doubling the card', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final item = MediaItem(
      id: 'e1',
      name: '相遇',
      type: 'Episode',
      indexNumber: 1,
      overview: '简介',
      runtime: Duration(microseconds: (23 * 60 * 10000000) ~/ 10),
    );

    Future<double> titleHeight(Size view) async {
      tester.view.physicalSize = view;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...AppLocalizations.localizationsDelegates,
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Align(
            alignment: Alignment.topCenter,
            child: AppViewport.readingScope(
              enabled: true,
              child: SizedBox(
                width: EpisodeGridMetrics.minCardWidthFor(view),
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
          builder: (context, child) => ui.AppUiTheme(
            data: Theme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
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
    // 4K 下卡宽与字号同比放大，卡片仍是一张剧照加三四行字的比例。
    final card = tester.getSize(find.byType(EpisodeRow));
    expect(card.height, lessThan(card.width * 1.1));
    expect(tester.takeException(), isNull);
  });
}
