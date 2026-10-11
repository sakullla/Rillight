import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('light back button stays a paper chip over artwork', (
    tester,
  ) async {
    final scheme = AppTheme.light().colorScheme;
    final box = await pump(tester, theme: AppTheme.light(), overArtwork: true);
    expect(find.byType(ScrimIconButton), findsNothing);
    expect(decorationOf(box).color, scheme.surfaceContainerLowest);
    expect(tester.getSize(find.byKey(CatalogKeys.back)).height, 36);
    expect(find.text('返回'), findsOneWidget);
  });

  testWidgets('dark back button uses a scrim chip over artwork', (
    tester,
  ) async {
    final scheme = AppTheme.dark().colorScheme;
    final box = await pump(tester, theme: AppTheme.dark(), overArtwork: true);
    expect(decorationOf(box).color, isNot(scheme.surfaceContainerHigh));
    expect(decorationOf(box).color!.a, greaterThan(0.4));
  });

  testWidgets('dark solid bar uses a raised surface chip', (tester) async {
    final scheme = AppTheme.dark().colorScheme;
    final box = await pump(tester, theme: AppTheme.dark(), overArtwork: false);
    expect(decorationOf(box).color, scheme.surfaceContainerHigh);
  });
}
