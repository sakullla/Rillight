import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/library_tiles.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/app/theme/tokens.dart';

void main() {
  testWidgets('library rail never restores the outer page vertical offset', (
    tester,
  ) async {
    final page = ScrollController();
    addTearDown(page.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            key: const PageStorageKey('home-scroll'),
            controller: page,
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            children: [
              const SizedBox(height: 800),
              LibraryTiles(
                libraries: [
                  for (var i = 0; i < 8; i++)
                    EmbyItem(
                      id: 'lib-$i',
                      name: '片库$i',
                      type: 'CollectionFolder',
                    ),
                ],
              ),
              const SizedBox(height: 2400),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LibraryTiles), findsNothing);
    page.jumpTo(800);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(CatalogKeys.library('lib-0'))).dx,
      closeTo(AppSpacing.page, .1),
    );
    expect(page.offset, 800);
  });

  testWidgets('library entry stays one horizontal row', (tester) async {
    final libraries = [
      for (var index = 0; index < 8; index++)
        EmbyItem(
          id: 'lib-$index',
          name: '片库$index',
          type: 'CollectionFolder',
          collectionType: 'movies',
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LibraryTiles(libraries: libraries)),
      ),
    );
    await tester.pump();

    expect(find.byType(Wrap), findsNothing);
    final menu = tester.getSize(find.byKey(CatalogKeys.librariesMenu));
    final first = tester.getRect(find.byKey(CatalogKeys.library('lib-0')));
    final second = tester.getRect(find.byKey(CatalogKeys.library('lib-1')));
    expect(second.top, closeTo(first.top, 1));
    expect(second.left, greaterThan(first.right - 1));
    expect(menu.height, lessThan(first.height * 2));
    expect(find.byKey(CatalogKeys.library('lib-7')), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(CatalogKeys.library('lib-7')),
      300,
      scrollable: find.descendant(
        of: find.byKey(CatalogKeys.librariesMenu),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(CatalogKeys.library('lib-7')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(CatalogKeys.library('lib-7'))).top,
      closeTo(first.top, 1),
    );
  });
}
