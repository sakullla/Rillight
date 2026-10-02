import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/library/shelf_sort.dart';

void main() {
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
}
