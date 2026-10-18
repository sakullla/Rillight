import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/library/shelf_grid_page.dart';

Widget _wrap(Widget child) {
  return CupertinoTestApp(
    theme: AppUiTheme.dark(),
    home: CupertinoPageScaffold(child: child),
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

  testWidgets(
    'SkeletonPosterGrid honours an explicit column count and extent',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 1392,
            child: SkeletonPosterGrid(
              itemCount: 6,
              crossAxisCount: 4,
              mainAxisExtent: 331,
            ),
          ),
        ),
      );

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
      expect(delegate.mainAxisExtent, 331);
      // mainAxisExtent 决定行高,此时宽高比不再参与布局。
      expect(delegate.childAspectRatio, 1);
    },
  );

  testWidgets('SkeletonPosterGrid keeps skeleton cells on the result grid', (
    tester,
  ) async {
    // 骨架与结果网格必须同列数、同行高,否则加载完成时会跳列、错高。
    const screenWidth = 1440.0;
    final available = screenWidth - AppSpacing.page * 2;
    final geometry = ShelfGridPage.gridGeometryFor(
      screenWidth: screenWidth,
      availableWidth: available,
      labelExtent: 54,
    );
    final delegate = ShelfGridPage.gridDelegateFor(
      screenWidth: screenWidth,
      availableWidth: available,
      labelExtent: 54,
    ) as SliverGridDelegateWithFixedCrossAxisCount;

    expect(delegate.crossAxisCount, geometry.crossAxisCount);
    expect(delegate.mainAxisExtent, geometry.mainAxisExtent);
    // 列宽乘列数加回列间距,正好等于可用宽度。
    expect(
      geometry.crossAxisCount * geometry.cellWidth +
          (geometry.crossAxisCount - 1) * geometry.spacing,
      closeTo(available, 0.01),
    );
  });

  testWidgets('skeleton cells tile a row exactly as the result grid does', (
    tester,
  ) async {
    const screenWidth = 1440.0;
    final available = screenWidth - AppSpacing.page * 2;
    final geometry = ShelfGridPage.gridGeometryFor(
      screenWidth: screenWidth,
      availableWidth: available,
      labelExtent: 54,
    );

    // 真实视口宽度,让脚手架按 1440 布局,而不是测试默认的 800。
    tester.view.physicalSize = const Size(screenWidth, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        SkeletonPosterGrid(
          itemCount: geometry.crossAxisCount,
          crossAxisCount: geometry.crossAxisCount,
          mainAxisExtent: geometry.mainAxisExtent,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        ),
      ),
    );

    final blocks = find.descendant(
      of: find.byType(SkeletonPosterGrid),
      matching: find.byType(SkeletonBlock),
    );
    final first = tester.getRect(blocks.first);
    final second = tester.getRect(blocks.at(1));
    // 同一行相邻两格的间距等于网格列间距,首格贴住内容左缘。
    expect(second.left - first.right, closeTo(geometry.spacing, 0.01));
    expect(first.left, closeTo(AppSpacing.page, 0.01));
    expect(first.width, closeTo(geometry.cellWidth, 0.01));
    expect(first.height, closeTo(geometry.mainAxisExtent, 0.01));
  });
}
