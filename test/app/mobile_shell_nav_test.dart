import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/ui/ui.dart';

import '../helpers/cupertino_test_app.dart';

void main() {
  Widget host({
    required AppUiThemeData theme,
    required int index,
    required bool floating,
    ValueChanged<int>? onSelected,
  }) {
    return CupertinoTestApp(
      theme: theme,
      home: CupertinoPageScaffold(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const SizedBox.expand(),
            Align(
              alignment: Alignment.bottomCenter,
              child: PhoneBottomNav(
                index: index,
                floating: floating,
                onSelected: onSelected ?? (_) {},
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration pillDecoration(WidgetTester tester) =>
      tester.widget<DecoratedBox>(find.byKey(PhoneBottomNav.pillKey)).decoration
          as BoxDecoration;

  testWidgets('selected pill uses accent fill with 1.5dp accent border', (
    tester,
  ) async {
    for (final theme in [AppUiTheme.phoneDark(), AppUiTheme.phoneLight()]) {
      await tester.pumpWidget(host(theme: theme, index: 1, floating: false));
      final scheme = theme.colorScheme;
      final decoration = pillDecoration(tester);

      expect(decoration.color, scheme.primaryContainer);
      final border = decoration.border! as Border;
      expect(border.top.color, scheme.primary);
      expect(border.top.width, AppSelectionDecoration.borderWidth);
      expect(AppSelectionDecoration.borderWidth, 1.5);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppMobileNav.pillRadius),
      );
    }
  });

  testWidgets('pill tracks each of the three destinations', (tester) async {
    var selected = -1;
    await tester.pumpWidget(
      host(
        theme: AppUiTheme.phoneDark(),
        index: 0,
        floating: false,
        onSelected: (value) => selected = value,
      ),
    );
    final nav = find.byType(CupertinoTabBar);
    expect(tester.widget<CupertinoTabBar>(nav).items, hasLength(3));

    final bar = tester.getRect(nav);
    final itemWidth = bar.width / 3;
    for (var index = 0; index < 3; index++) {
      await tester.pumpWidget(
        host(
          theme: AppUiTheme.phoneDark(),
          index: index,
          floating: false,
          onSelected: (value) => selected = value,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      final pill = tester.getRect(find.byKey(PhoneBottomNav.pillKey));
      expect(pill.center.dx, moreOrLessEquals((index + 0.5) * itemWidth));
      expect(pill.width, moreOrLessEquals(itemWidth - AppSpacing.xs * 2));
    }

    final l = AppLocalizations.of(tester.element(nav));
    await tester.tap(find.text(l.aggregation));
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating pill keeps its inset inside the capsule bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(theme: AppUiTheme.phoneDark(), index: 2, floating: true),
    );
    final bar = tester.getRect(find.byType(CupertinoTabBar));
    final pill = tester.getRect(find.byKey(PhoneBottomNav.pillKey));

    expect(bar.left, AppMobileNav.floatMargin);
    expect(pill.left, greaterThan(bar.left));
    expect(pill.right, lessThan(bar.right));
    expect(pill.top, bar.top + AppSpacing.xs);
    expect(pill.bottom, lessThanOrEqualTo(bar.bottom - AppSpacing.xs));
  });
}
