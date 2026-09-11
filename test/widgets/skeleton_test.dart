import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: child),
  );
}

BoxDecoration _blockDecoration(WidgetTester tester, Finder block) {
  return tester
          .widget<DecoratedBox>(
            find.descendant(of: block, matching: find.byType(DecoratedBox)),
          )
          .decoration
      as BoxDecoration;
}

double _gradientOffsetX(BoxDecoration decoration) {
  final transform = (decoration.gradient! as LinearGradient).transform!;
  return transform.transform(const Rect.fromLTWH(0, 0, 100, 50))!.storage[12];
}

void main() {
  testWidgets('SkeletonBlock renders a rounded shimmering block', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const Center(child: SkeletonBlock(width: 120, height: 180))),
    );

    final block = find.byType(SkeletonBlock);
    expect(block, findsOneWidget);

    final decoration = _blockDecoration(tester, block);
    expect(decoration.borderRadius, isNotNull);
    expect(decoration.gradient, isA<LinearGradient>());

    final before = _gradientOffsetX(decoration);
    await tester.pump(const Duration(milliseconds: 160));
    final after = _gradientOffsetX(_blockDecoration(tester, block));
    expect(after, isNot(before));
  });

  testWidgets('SkeletonShelfRow renders poster and label skeletons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const SkeletonShelfRow(itemCount: 4, posterWidth: 100)),
    );

    expect(
      find.descendant(
        of: find.byType(SkeletonShelfRow),
        matching: find.byType(SkeletonBlock),
      ),
      findsNWidgets(8),
    );
  });

  testWidgets('SkeletonPosterGrid renders grid skeletons', (tester) async {
    await tester.pumpWidget(_wrap(const SkeletonPosterGrid(itemCount: 6)));

    expect(
      find.descendant(
        of: find.byType(SkeletonPosterGrid),
        matching: find.byType(SkeletonBlock),
      ),
      findsNWidgets(6),
    );
  });
}
