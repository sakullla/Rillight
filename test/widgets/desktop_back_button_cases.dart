import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/widgets/desktop_back_button.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/home/catalog_keys.dart';

void main() {
  Future<AnimatedContainer> pump(
    WidgetTester tester, {
    required AppUiThemeData theme,
    required bool overArtwork,
  }) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: theme,
        home: CupertinoPageScaffold(
          child: Center(
            child: DesktopBackButton(
              tooltip: '返回',
              onPressed: () {},
              icon: CupertinoIcons.chevron_left,
              label: '返回',
              overArtwork: overArtwork,
            ),
          ),
        ),
      ),
    );
    return tester.widget<AnimatedContainer>(find.byKey(CatalogKeys.back));
  }

  ShapeDecoration decorationOf(AnimatedContainer box) =>
      box.decoration! as ShapeDecoration;

  testWidgets('back chip follows theme and artwork surface', (tester) async {
    final light = await pump(
      tester,
      theme: AppUiTheme.light(),
      overArtwork: true,
    );
    expect(find.byType(ScrimIconButton), findsNothing);
    expect(
      decorationOf(light).color,
      AppUiTheme.light().colorScheme.surfaceContainerLowest,
    );
    expect(tester.getSize(find.byKey(CatalogKeys.back)).height, 36);
    expect(find.text('返回'), findsOneWidget);
    final dark = await pump(
      tester,
      theme: AppUiTheme.dark(),
      overArtwork: true,
    );
    expect(
      decorationOf(dark).color,
      isNot(AppUiTheme.dark().colorScheme.surfaceContainerHigh),
    );
    expect(decorationOf(dark).color!.a, greaterThan(0.4));
    final solid = await pump(
      tester,
      theme: AppUiTheme.dark(),
      overArtwork: false,
    );
    expect(
      decorationOf(solid).color,
      AppUiTheme.dark().colorScheme.surfaceContainerHigh,
    );
  });
}
