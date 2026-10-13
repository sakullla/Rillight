import '../helpers/widget_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/desktop_back_button.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/home/catalog_keys.dart';

void main() {
  Future<AnimatedContainer> pump(
    WidgetTester tester, {
    required ThemeData theme,
    required bool overArtwork,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: theme,
        home: Scaffold(
          body: Center(
            child: DesktopBackButton(
              tooltip: '返回',
              onPressed: () {},
              icon: Icons.chevron_left_rounded,
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
      theme: AppTheme.light(),
      overArtwork: true,
    );
    expect(find.byType(ScrimIconButton), findsNothing);
    expect(
      decorationOf(light).color,
      AppTheme.light().colorScheme.surfaceContainerLowest,
    );
    expect(tester.getSize(find.byKey(CatalogKeys.back)).height, 36);
    expect(find.text('返回'), findsOneWidget);
    final dark = await pump(tester, theme: AppTheme.dark(), overArtwork: true);
    expect(
      decorationOf(dark).color,
      isNot(AppTheme.dark().colorScheme.surfaceContainerHigh),
    );
    expect(decorationOf(dark).color!.a, greaterThan(0.4));
    final solid = await pump(
      tester,
      theme: AppTheme.dark(),
      overArtwork: false,
    );
    expect(
      decorationOf(solid).color,
      AppTheme.dark().colorScheme.surfaceContainerHigh,
    );
  });
}
