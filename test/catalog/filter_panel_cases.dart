import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_server/models.dart';

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
        CupertinoTestApp(
          theme: AppUiTheme.phoneLight(),
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: ui.AppButton(
                onPressed: () => showAppModalSheet<void>(
                  context: context,
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
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      Future<void> tap(String suffix) async {
        final finder = find.byKey(Key('filter-$suffix'));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle(tester);
      }

      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const Key('filter-phone-sheet')), findsNothing);
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
      await settle(tester);
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
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: ui.AppButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (_) => AppModalFrame(
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
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    final watch = tester.getSize(find.byType(LibraryFilterPanel));
    expect(watch.width, 600);
    expect(watch.height, 420);

    await tester.tap(find.byKey(const Key('filter-section-genre')));
    await settle(tester);
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
        CupertinoTestApp(
          theme: AppUiTheme.dark(),
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: ui.AppButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  builder: (_) => AppModalFrame(
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
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      final watch = tester.getSize(find.byType(LibraryFilterPanel));
      expect(watch.width, closeTo(width, 0.1));
      expect(watch.height, closeTo(compact, 0.1));
      await tester.tap(find.byKey(const Key('filter-section-genre')));
      await settle(tester);
      final genre = tester.getSize(find.byType(LibraryFilterPanel));
      expect(genre.width, closeTo(width, 0.1));
      expect(genre.height, closeTo(tall, 0.1));
      await tester.tap(find.byKey(const Key('filter-cancel')));
      await settle(tester);
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
        CupertinoTestApp(
          theme: AppUiTheme.dark(),
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PresentationScope(
            environment: PresentationEnvironment.phone,
            child: Center(
              child: LibraryFilterPanel(
                television: true,
                keyPrefix: 'tv-filter',
                initial: const ShelfFilters(),
                onApply: (_, _) {},
              ),
            ),
          ),
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await settle(tester);
      final size = tester.getSize(find.byType(LibraryFilterPanel));
      expect(size.width, closeTo(width, 0.1));
      expect(size.height, closeTo(height, 0.1));
      expect(find.byKey(const Key('tv-filter-phone-sheet')), findsNothing);
    }
  });

  test(
    'library and search widths stay two columns at 360 and three at 412',
    () {
      expect(mobileGridColumnCount(360), 2);
      expect(mobileGridColumnCount(412), 3);
      expect(mobileGridColumnCount(360 - 32), 2);
      expect(mobileGridColumnCount(412 - 32), 3);
      expect(mobileGridColumnCount(360, textScale: 2), lessThan(2));
      expect(mobileGridColumnCount(412, textScale: 2), lessThan(3));
    },
  );

  testWidgets('series poster uses seasonCount apart from the rating', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.phoneLight(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Center(
          child: SizedBox(
            width: 160,
            child: PhonePosterCard(
              item: MediaItem(
                id: 'series-2',
                name: '两季剧',
                type: 'Series',
                childCount: 2,
                productionYear: 2020,
                communityRating: 8.4,
              ),
              titleMaxLines: 2,
              seasonCountCaption: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final season = tester.widget<Text>(
      find.byKey(const Key('phone-poster-season-series-2')),
    );
    final title = tester.widget<Text>(find.text('两季剧'));
    expect(season.data, '共2季');
    expect(title.maxLines, 2);
    expect(find.text('8.4'), findsOneWidget);
    expect(season.data, isNot(contains('8.4')));
    expect(find.text('2季'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone filter sheet keeps draft semantics and hides movie-only type',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ShelfFilters? applied;
      var calls = 0;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: AppUiTheme.phoneLight(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: ui.AppButton(
                onPressed: () => showAppModalSheet<void>(
                  context: context,
                  builder: (_) => PresentationScope(
                    environment: PresentationEnvironment.phone,
                    child: LibraryFilterPanel(
                      keyPrefix: 'phone',
                      typeFilterable: false,
                      initial: const ShelfFilters(),
                      years: const [2024, 2020],
                      genres: const ['SciFi', 'Comedy'],
                      onApply: (filters, _) {
                        applied = filters;
                        calls++;
                      },
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
      await settle(tester);
      expect(find.byKey(const Key('phone-phone-sheet')), findsOneWidget);
      expect(find.byKey(const Key('phone-section-type')), findsNothing);
      expect(find.byKey(const Key('phone-section-watch')), findsOneWidget);
      final section = tester.getSize(
        find.byKey(const Key('phone-section-watch')),
      );
      expect(section.height, greaterThanOrEqualTo(48));
      expect(section.width, greaterThanOrEqualTo(48));

      Future<void> tap(String suffix) async {
        final finder = find.byKey(Key('phone-$suffix'));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle(tester);
      }

      await tap('section-year');
      await tap('year-2024');
      await tap('year-2020');
      await tap('section-genre');
      await tap('genre-SciFi');
      await tap('genre-Comedy');
      expect(calls, 0);
      await tap('cancel');
      expect(calls, 0);
      expect(applied, isNull);

      await tester.tap(find.text('open'));
      await settle(tester);
      await tap('section-year');
      await tap('year-2024');
      await tap('year-2020');
      await tap('section-genre');
      await tap('genre-SciFi');
      await tap('genre-Comedy');
      final apply = tester.getRect(find.byKey(const Key('phone-apply')));
      expect(apply.height, greaterThanOrEqualTo(48));
      expect(apply.bottom, lessThanOrEqualTo(800));
      await tap('apply');
      expect(calls, 1);
      expect(applied!.years, [2024, 2020]);
      expect(applied!.genres, ['SciFi', 'Comedy']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single-page filter panel renders all dimensions, collapses historical years and toggles sort order',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 810);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ShelfFilters? appliedFilters;
      CatalogSort? appliedSort;
      String? appliedSortOrder;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: AppUiTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: ui.AppButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  builder: (_) => AppModalFrame(
                    child: LibraryFilterPanel(
                      keyPrefix: 'flat',
                      initial: const ShelfFilters(),
                      sort: CatalogSort.dateUpdated,
                      sortOrder: 'Descending',
                      genres: const ['科幻', '动作'],
                      onApply: (filters, sort) {
                        appliedFilters = filters;
                        appliedSort = sort;
                      },
                      onApplyWithOrder: (filters, sort, sortOrder) {
                        appliedFilters = filters;
                        appliedSort = sort;
                        appliedSortOrder = sortOrder;
                      },
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
      await settle(tester);

      // All dimension sections are simultaneously present in the single-page scroll view.
      expect(find.byKey(const Key('flat-sort-section')), findsOneWidget);
      expect(find.byKey(const Key('flat-type-section')), findsOneWidget);
      expect(find.byKey(const Key('flat-watch-section')), findsOneWidget);
      expect(find.byKey(const Key('flat-genre-section')), findsOneWidget);
      expect(find.byKey(const Key('flat-year-section')), findsOneWidget);

      // Older years (< currentYear - 14) are collapsed by default until expanded.
      expect(find.byKey(const Key('flat-year-1999')), findsNothing);
      final expandYears = find.byKey(const Key('flat-year-expand'));
      expect(expandYears, findsOneWidget);
      await tester.ensureVisible(expandYears);
      await tester.tap(expandYears);
      await settle(tester);
      expect(find.byKey(const Key('flat-year-1999')), findsOneWidget);

      // Sort order can be toggled in the panel and committed on apply.
      final sortOrderBtn = find.byKey(const Key('flat-sort-order'));
      await tester.ensureVisible(sortOrderBtn);
      await tester.tap(sortOrderBtn);
      await settle(tester);

      // Random sort hides the sort order toggle.
      final randomSort = find.byKey(const Key('flat-sort-Random'));
      await tester.ensureVisible(randomSort);
      await tester.tap(randomSort);
      await settle(tester);
      expect(find.byKey(const Key('flat-sort-order')), findsNothing);

      // Switch to premiereDate and flip to Ascending.
      final premiereSort = find.byKey(const Key('flat-sort-PremiereDate'));
      await tester.ensureVisible(premiereSort);
      await tester.tap(premiereSort);
      await settle(tester);
      final sortOrderAfterPremiere = find.byKey(
        const Key('flat-sort-order'),
      );
      expect(sortOrderAfterPremiere, findsOneWidget);
      await tester.ensureVisible(sortOrderAfterPremiere);
      await tester.tap(sortOrderAfterPremiere);
      await settle(tester);

      await tester.tap(find.byKey(const Key('flat-apply')));
      await settle(tester);
      expect(appliedFilters, isNotNull);
      expect(appliedSort, CatalogSort.premiereDate);
      expect(appliedSortOrder, 'Ascending');
    },
  );
}
