import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/player/player_window_host.dart';

const _movie = MediaItem(
  id: 'movie-1',
  name: '可播电影',
  type: 'Movie',
  productionYear: 2020,
  runtime: Duration(microseconds: (27000000000) ~/ 10),
);

Widget _wrap({
  required OverlayPlayerWindowHost host,
  required Widget child,
  AppUiThemeData? theme,
}) {
  return CupertinoTestApp(
    theme: theme ?? AppUiTheme.dark(),
    localizationsDelegates: [
      AppLocalizations.delegate,
      ...GlobalCupertinoLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: PlayerWindowScope(
      host: host,
      child: CupertinoPageScaffold(child: Center(child: child)),
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

  testWidgets('grid captions fit fractional widths and mixed fallback fonts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scale in [1.0, 1.25, 1.5]) {
      for (final width in [723.5, 987.25, 1537.0]) {
        await tester.pumpWidget(
          _wrap(
            host: host,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: SizedBox(
                width: width,
                height: 550,
                child: Builder(
                  builder: (context) {
                    return GridView.builder(
                      gridDelegate: ShelfGridPage.gridDelegateFor(
                        screenWidth: width,
                        availableWidth: width,
                        labelExtent: MediaShelf.posterLabelExtentFor(context),
                      ),
                      itemCount: 12,
                      itemBuilder: (context, index) => ShelfGridPage.gridCard(
                        context,
                        MediaItem(
                          id: 'grid-$index',
                          name: '中文 日本語 Ag 🎬 Ⅰ $index',
                          type: 'Series',
                        ),
                        onTap: () {},
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$width at $scale');
      }
    }
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
    expect(findAppTooltip('可播电影'), findsOneWidget);
    expect(taps, 0);
    expect(host.current, isNull);
  });

  testWidgets('light hover keeps the title and uses the accent play control', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        theme: AppUiTheme.light(),
        child: PosterCard(item: _movie, onTap: () {}),
      ),
    );
    await _hover(tester, find.byType(PosterCard));

    final title = tester.getRect(find.text('可播电影'));
    final card = tester.getRect(find.byType(PosterCard));
    expect(title.bottom, lessThanOrEqualTo(card.bottom + 0.5));
    expect(
      find.descendant(
        of: find.byType(AnimatedScale),
        matching: find.text('可播电影'),
      ),
      findsNothing,
    );
    final play = tester.widget<AppIconButton>(
      find.byKey(PosterCard.playButtonKey(_movie.id)),
    );
    expect(play.style?.backgroundColor, AppUiTheme.light().colorScheme.primary);
    expect(
      play.style?.foregroundColor,
      AppUiTheme.light().colorScheme.onPrimary,
    );
  });

  testWidgets('light hover remove control uses the paper chip', (tester) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        theme: AppUiTheme.light(),
        child: PosterCard(
          item: _movie,
          onTap: () {},
          onRemoveFromResume: (_) {},
        ),
      ),
    );
    await _hover(tester, find.byType(PosterCard));
    final close = tester.widget<AppIconButton>(
      find.byKey(CatalogKeys.removeFromResume(_movie.id)),
    );
    final scheme = AppUiTheme.light().colorScheme;
    expect(close.style?.backgroundColor, scheme.surfaceContainerLowest);
    expect(close.style?.foregroundColor, scheme.onSurface);
  });

  testWidgets('dark hover keeps the white play control', (tester) async {
    await tester.pumpWidget(
      _wrap(
        host: host,
        child: PosterCard(item: _movie, onTap: () {}),
      ),
    );
    await _hover(tester, find.byType(PosterCard));
    final play = tester.widget<AppIconButton>(
      find.byKey(PosterCard.playButtonKey(_movie.id)),
    );
    expect(play.style?.backgroundColor, const Color(0xffffffff));
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

  testWidgets(
    'keyboard focus reveals play and Enter activates only that action',
    (tester) async {
      var detailTaps = 0;
      await tester.pumpWidget(
        _wrap(
          host: host,
          child: PosterCard(item: _movie, onTap: () => detailTaps++),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(PosterCard.playButtonKey(_movie.id)), findsOneWidget);
      expect(host.current, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(host.current?.itemId, _movie.id);
      expect(detailTaps, 0);
    },
  );
}
