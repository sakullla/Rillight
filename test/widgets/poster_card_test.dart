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
}
