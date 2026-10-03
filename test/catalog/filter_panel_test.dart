import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/library/shelf_sort.dart';

void main() {
  test('panel scale follows the logical window, not a second DPI pass', () {
    expect(AppViewport.scaleOf(const Size(1920, 1080)), 1);
    expect(AppViewport.scaleOf(const Size(1440, 810)), 1);
    expect(AppViewport.scaleOf(const Size(2560, 1440)), 4 / 3);
    expect(AppViewport.scaleOf(const Size(3840, 2160)), 2);
    expect(AppViewport.scaleOf(const Size(5120, 2880)), 2);
  });

  testWidgets(
    'filter selections are staged, combined, reset and applied once',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ShelfFilters? applied;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.phoneLight(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => LibraryFilterPanel(
                    keyPrefix: 'filter',
                    initial: const ShelfFilters(),
                    sort: CatalogSort.initial,
                    genres: const ['动画'],
                    loadGenres: () async => ['动画', '科幻'],
                    onApply: (filters, _) {
                      applied = filters;
                      calls++;
                    },
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      Future<void> tap(String suffix) async {
        final finder = find.byKey(Key('filter-$suffix'));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tap('section-genre');
      await tap('genre-动画');
      await tap('genre-科幻');
      await tap('section-year');
      await tap('year-2025');
      await tap('year-2024');
      expect(calls, 0);
      final apply = tester.getRect(find.byKey(const Key('filter-apply')));
      expect(apply.bottom, lessThanOrEqualTo(800));
      await tap('apply');
      expect(calls, 1);
      expect(applied!.genres, ['动画', '科幻']);
      expect(applied!.years, [2025, 2024]);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tap('section-watch');
      await tap('watch-IsFavorite');
      await tap('clear');
      expect(calls, 1);
      await tap('cancel');
      expect(calls, 1);
    },
  );

  testWidgets('desktop filter dialog stays within the library window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 810);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: LibraryFilterPanel(
                    keyPrefix: 'filter',
                    typeFilterable: false,
                    initial: const ShelfFilters(),
                    onApply: (_, _) {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final watch = tester.getSize(find.byType(LibraryFilterPanel));
    expect(watch.width, 600);
    expect(watch.height, 420);

    await tester.tap(find.byKey(const Key('filter-section-genre')));
    await tester.pumpAndSettle();
    final genre = tester.getSize(find.byType(LibraryFilterPanel));
    expect(genre.width, 600);
    expect(genre.height, 520);
  });

  testWidgets('desktop filter grows with 1080p, 2K and 4K windows', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    const cases = <(Size, double, double, double)>[
      (Size(1920, 1080), 600, 420, 520),
      (Size(2560, 1440), 800, 560, 520 * 4 / 3),
      (Size(3840, 2160), 1200, 840, 1040),
    ];
    for (final (view, width, compact, tall) in cases) {
      tester.view.physicalSize = view;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: LibraryFilterPanel(
                      keyPrefix: 'filter',
                      typeFilterable: false,
                      initial: const ShelfFilters(),
                      onApply: (_, _) {},
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final watch = tester.getSize(find.byType(LibraryFilterPanel));
      expect(watch.width, closeTo(width, 0.1));
      expect(watch.height, closeTo(compact, 0.1));
      await tester.tap(find.byKey(const Key('filter-section-genre')));
      await tester.pumpAndSettle();
      final genre = tester.getSize(find.byType(LibraryFilterPanel));
      expect(genre.width, closeTo(width, 0.1));
      expect(genre.height, closeTo(tall, 0.1));
      await tester.tap(find.byKey(const Key('filter-cancel')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('television filter keeps its 1080p size and doubles at 4K', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final (view, width, height) in const [
      (Size(1920, 1080), 980.0, 760.0),
      (Size(3840, 2160), 1960.0, 1520.0),
    ]) {
      tester.view.physicalSize = view;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Center(
            child: LibraryFilterPanel(
              television: true,
              keyPrefix: 'tv-filter',
              initial: const ShelfFilters(),
              onApply: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byType(LibraryFilterPanel));
      expect(size.width, closeTo(width, 0.1));
      expect(size.height, closeTo(height, 0.1));
    }
  });
}
