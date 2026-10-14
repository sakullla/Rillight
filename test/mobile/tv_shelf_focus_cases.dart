import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/media_server/models.dart';

void main() {
  testWidgets('focused TV poster keeps its node when refreshed order changes', (
    tester,
  ) async {
    const first = MediaItem(id: 'first', name: 'First', type: 'Movie');
    const second = MediaItem(id: 'second', name: 'Second', type: 'Movie');
    const third = MediaItem(id: 'third', name: 'Third', type: 'Movie');
    const metrics = TvGridMetrics(
      columns: 2,
      imageMaxWidth: 200,
      childAspectRatio: 0.7,
    );
    Widget page(List<MediaItem> items) => CupertinoTestApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: CupertinoPageScaffold(
        child: CustomScrollView(
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
    await settle(tester);
    expect(node.hasFocus, isTrue);

    await tester.pumpWidget(page([second, first]));
    await settle(tester);
    expect(
      tester.widget<FocusableActionDetector>(focusable('second')).focusNode,
      same(node),
    );
    expect(node.hasFocus, isTrue);

    await tester.pumpWidget(page([first, third, second]));
    await settle(tester);
    expect(
      tester.widget<FocusableActionDetector>(focusable('second')).focusNode,
      same(node),
    );
    expect(node.hasFocus, isTrue);
  });
}
