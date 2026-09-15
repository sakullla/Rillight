import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/player/player_window_host.dart';

const _movie = EmbyItem(
  id: 'movie-1',
  name: '可播电影',
  type: 'Movie',
  productionYear: 2020,
  runTimeTicks: 27000000000,
);

const _movieWithPlot = EmbyItem(
  id: 'movie-plot',
  name: '有简介的电影',
  type: 'Movie',
  productionYear: 2021,
  runTimeTicks: 27000000000,
  overview: 'A thief who steals corporate secrets through dream-sharing.',
);

const _series = EmbyItem(
  id: 'series-1',
  name: '剧集系列',
  type: 'Series',
  productionYear: 1994,
);

const _season = EmbyItem(
  id: 'season-1',
  name: '第一季',
  type: 'Season',
  childCount: 12,
);

const _episode = EmbyItem(
  id: 'episode-1',
  name: '试播集',
  type: 'Episode',
  seriesName: '剧集系列',
  indexNumber: 2,
  parentIndexNumber: 1,
);

Widget _wrap({required OverlayPlayerWindowHost host, required Widget child}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: PlayerWindowScope(
      host: host,
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

Future<TestGesture> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  await tester.pump();
  return gesture;
}

void main() {
  late OverlayPlayerWindowHost host;

  setUp(() {
    host = OverlayPlayerWindowHost();
  });

  testWidgets('hover on a playable poster reveals title, meta and play', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movie, onTap: () => taps++),
      ),
    );

    expect(find.byKey(PosterCard.playButtonKey(_movie.id)), findsNothing);
    expect(find.text('2020'), findsNothing);

    await _hover(tester, find.byType(PosterCard));

    expect(find.byKey(PosterCard.playButtonKey(_movie.id)), findsOneWidget);
    expect(find.textContaining('2020'), findsOneWidget);
    expect(find.textContaining('45分钟'), findsOneWidget);
    expect(find.text('可播电影'), findsWidgets);
    expect(find.byTooltip('可播电影'), findsOneWidget);
    expect(taps, 0);
    expect(host.current, isNull);
  });

  testWidgets('hover reveals a two-line overview on the poster', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movieWithPlot, onTap: () {}),
      ),
    );

    expect(
      find.text('A thief who steals corporate secrets through dream-sharing.'),
      findsNothing,
    );

    await _hover(tester, find.byType(PosterCard));

    expect(
      find.text('A thief who steals corporate secrets through dream-sharing.'),
      findsOneWidget,
    );
    expect(find.textContaining('2021'), findsOneWidget);
    expect(find.text('有简介的电影'), findsOneWidget);
  });

  testWidgets('play button opens the player and does not open detail', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movie, onTap: () => taps++),
      ),
    );
    await _hover(tester, find.byType(PosterCard));

    await tester.tap(find.byKey(PosterCard.playButtonKey(_movie.id)));
    await tester.pump();

    expect(host.current?.itemId, _movie.id);
    expect(taps, 0);
  });

  testWidgets('clicking the card body goes to detail, not the player', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movie, onTap: () => taps++),
      ),
    );

    await tester.tap(find.byKey(CatalogKeys.item(_movie.id)));
    await tester.pump();

    expect(taps, 1);
    expect(host.current, isNull);
  });

  testWidgets('series hover does not play and tap goes to detail', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _series, onTap: () => taps++),
      ),
    );
    await _hover(tester, find.byType(PosterCard));

    expect(find.byKey(PosterCard.playButtonKey(_series.id)), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.text('1994'), findsOneWidget);

    await tester.tap(find.byKey(CatalogKeys.item(_series.id)));
    await tester.pump();

    expect(taps, 1);
    expect(host.current, isNull);
  });

  testWidgets('season hover has no play and tap goes to detail', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: SeasonPosterCard(
          item: _season,
          selected: false,
          onTap: () => taps++,
        ),
      ),
    );
    await _hover(tester, find.byType(SeasonPosterCard));

    expect(find.byKey(PosterCard.playButtonKey(_season.id)), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);

    await tester.tap(find.byKey(CatalogKeys.season(_season.id)));
    await tester.pump();

    expect(taps, 1);
    expect(host.current, isNull);
    expect(tester.getSize(find.byType(SeasonPosterCard)).width, 132);
  });

  testWidgets('selected season border does not expand the card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: SeasonPosterCard(item: _season, selected: true, onTap: () {}),
      ),
    );
    expect(tester.getSize(find.byType(SeasonPosterCard)).width, 132);
  });

  testWidgets('episode hover play opens the episode, not a series id', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: EpisodeThumbCard(item: _episode, onTap: () => taps++),
      ),
    );
    await _hover(tester, find.byType(EpisodeThumbCard));

    await tester.tap(find.byKey(PosterCard.playButtonKey(_episode.id)));
    await tester.pump();

    expect(host.current?.itemId, _episode.id);
    expect(taps, 0);
  });

  testWidgets('selected episode uses a frame, not a now-watching badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: EpisodeThumbCard(item: _episode, selected: true, onTap: () {}),
      ),
    );

    expect(find.text('正在观看'), findsNothing);
    expect(find.text('2. 试播集'), findsOneWidget);
  });

  testWidgets('keyboard focus reveals the playable overlay', (tester) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movie, onTap: () {}),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(find.byKey(PosterCard.playButtonKey(_movie.id)), findsOneWidget);
  });

  testWidgets('continue watching episode shows series name and S1E2', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _episode, wide: true, onTap: () {}),
      ),
    );

    expect(find.text('剧集系列'), findsOneWidget);
    expect(find.text('S1E2 · 试播集'), findsOneWidget);
    expect(find.byTooltip('剧集系列'), findsOneWidget);
    expect(find.byTooltip('S1E2 · 试播集'), findsOneWidget);
  });

  testWidgets('continue watching hover can remove from resume', (tester) async {
    EmbyItem? removed;
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(
          item: _episode,
          wide: true,
          showProgress: true,
          onTap: () {},
          onRemoveFromResume: (item) => removed = item,
        ),
      ),
    );
    await _hover(tester, find.byType(PosterCard));
    await tester.tap(find.byKey(CatalogKeys.removeFromResume(_episode.id)));
    await tester.pump();
    expect(removed?.id, _episode.id);
  });
}
