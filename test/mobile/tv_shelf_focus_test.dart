import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/emby/emby_models.dart';

void main() {
  testWidgets('focused TV poster keeps its node when refreshed order changes', (
    tester,
  ) async {
    const first = EmbyItem(id: 'first', name: 'First', type: 'Movie');
    const second = EmbyItem(id: 'second', name: 'Second', type: 'Movie');
    const third = EmbyItem(id: 'third', name: 'Third', type: 'Movie');
    const metrics = TvGridMetrics(
      columns: 2,
      imageMaxWidth: 200,
      childAspectRatio: 0.7,
    );
    Widget page(List<EmbyItem> items) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CustomScrollView(
          slivers: [TvPosterSliver(items: items, metrics: metrics)],
        ),
      ),
    );
    Finder focusable(String id) => find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byType(FocusableActionDetector),
    );

    await tester.pumpWidget(page([first, second]));
    final node = tester
        .widget<FocusableActionDetector>(focusable('second'))
        .focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);

    await tester.pumpWidget(page([second, first]));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FocusableActionDetector>(focusable('second')).focusNode,
      same(node),
    );
    expect(node.hasFocus, isTrue);

    await tester.pumpWidget(page([first, third, second]));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FocusableActionDetector>(focusable('second')).focusNode,
      same(node),
    );
    expect(node.hasFocus, isTrue);
  });
}
