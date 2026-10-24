import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/season_switcher.dart';
import 'package:rillight/media_server/models.dart';

List<MediaItem> _seasons(int count, {String Function(int)? name}) => [
  for (var i = 1; i <= count; i++)
    MediaItem(id: 's$i', name: name?.call(i) ?? '第 $i 季', type: 'Season'),
];

Future<void> _pump(
  WidgetTester tester, {
  required List<MediaItem> seasons,
  String? currentId = 's1',
  ValueChanged<String>? onSelected,
  AppUiThemeData? theme,
  double width = 600,
  FocusNode? Function(String id)? focusNodeFor,
}) {
  return tester.pumpWidget(
    CupertinoTestApp(
      theme: theme ?? AppUiTheme.dark(),
      builder: (context, routed) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: routed!,
      ),
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SeasonSwitcher(
                seasons: seasons,
                currentId: currentId,
                onSelected: onSelected ?? (_) {},
                focusNodeFor: focusNodeFor,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a single season renders nothing', (tester) async {
    await _pump(tester, seasons: _seasons(1));
    expect(find.byKey(CatalogKeys.seasonPicker), findsNothing);
    expect(find.byKey(CatalogKeys.seasonTab('s1')), findsNothing);
    expect(find.text('第 1 季'), findsNothing);
  });

  testWidgets('seasons that fit show as tabs on desktop and phone', (
    tester,
  ) async {
    for (final theme in [AppUiTheme.dark(), AppUiTheme.phoneLight()]) {
      final picked = <String>[];
      await _pump(
        tester,
        seasons: _seasons(2),
        theme: theme,
        onSelected: picked.add,
      );
      expect(find.byKey(CatalogKeys.seasonPicker), findsNothing);
      expect(find.byKey(const Key('season-switcher-tabs')), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonTab('s1')), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonTab('s2')), findsOneWidget);
      expect(
        tester
            .widget<AppButton>(
              find.descendant(
                of: find.byKey(CatalogKeys.seasonTab('s1')),
                matching: find.byType(AppButton),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(CatalogKeys.seasonTab('s2')));
      await tester.pump();
      expect(picked, ['s2']);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('desktop folds overflowing seasons into an anchored menu', (
    tester,
  ) async {
    final picked = <String>[];
    await _pump(
      tester,
      seasons: _seasons(8),
      currentId: 's3',
      width: 360,
      onSelected: picked.add,
    );
    expect(find.byKey(CatalogKeys.seasonTab('s1')), findsNothing);
    expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
    expect(
      tester
          .widget<AppButton>(
            find.descendant(
              of: find.byKey(CatalogKeys.seasonPicker),
              matching: find.byType(AppButton),
            ),
          )
          .selected,
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.seasonPicker),
        matching: find.text('第 3 季'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(CatalogKeys.seasonPicker));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-menu-content')), findsOneWidget);
    for (var i = 1; i <= 8; i++) {
      expect(find.byKey(CatalogKeys.seasonOption('s$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(CatalogKeys.seasonOption('s5')));
    await tester.pumpAndSettle();
    expect(picked, ['s5']);
    expect(find.byKey(const Key('app-menu-content')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone folds overflowing seasons into a single-choice sheet', (
    tester,
  ) async {
    final picked = <String>[];
    await _pump(
      tester,
      seasons: _seasons(6),
      currentId: 's2',
      width: 320,
      theme: AppUiTheme.phoneDark(),
      onSelected: picked.add,
    );
    expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
    await tester.tap(find.byKey(CatalogKeys.seasonPicker));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('season-switcher-sheet')), findsOneWidget);
    expect(find.byKey(const Key('app-menu-content')), findsNothing);
    final current = tester.widget<AppListTile>(
      find.descendant(
        of: find.byKey(CatalogKeys.seasonOption('s2')),
        matching: find.byType(AppListTile),
      ),
    );
    expect(current.selected, isTrue);
    await tester.tap(find.byKey(CatalogKeys.seasonOption('s4')));
    await tester.pumpAndSettle();
    expect(picked, ['s4']);
    expect(find.byKey(const Key('season-switcher-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV shows focusable tabs, folding into a focusable list', (
    tester,
  ) async {
    final theme = AppUiTheme.tvDark().copyWith(tv: true);
    final nodes = <String, FocusNode>{};
    addTearDown(() {
      for (final node in nodes.values) {
        node.dispose();
      }
    });
    FocusNode nodeFor(String id) => nodes.putIfAbsent(id, FocusNode.new);

    final picked = <String>[];
    await _pump(
      tester,
      seasons: _seasons(2),
      theme: theme,
      onSelected: picked.add,
      focusNodeFor: nodeFor,
    );
    expect(find.byKey(CatalogKeys.seasonTab('s1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.seasonTab('s2')),
        matching: find.byType(TvAction),
      ),
      findsOneWidget,
    );
    nodes['s2']!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, ['s2']);

    picked.clear();
    await _pump(
      tester,
      seasons: _seasons(8),
      currentId: 's6',
      width: 360,
      theme: theme,
      onSelected: picked.add,
    );
    expect(find.byKey(CatalogKeys.seasonTab('s1')), findsNothing);
    await tester.tap(find.byKey(CatalogKeys.seasonPicker));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('season-switcher-tv-list')), findsOneWidget);
    // 当前季获得焦点,遥控器按「下」逐项移动后确认。
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.ancestor(
        of: find.byElementPredicate((e) => e == focused),
        matching: find.byKey(CatalogKeys.seasonOption('s6')),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, ['s7']);
    expect(find.byKey(const Key('season-switcher-tv-list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long season names stay on one line with a full-name tooltip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const long = '第一季：漫长的夏天与那些再也回不来的午后时光';
    await _pump(
      tester,
      seasons: _seasons(2, name: (i) => i == 1 ? long : '第 2 季'),
      width: 900,
    );
    expect(find.byKey(CatalogKeys.seasonTab('s1')), findsOneWidget);
    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, 1);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppTooltip && widget.message == long,
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byKey(CatalogKeys.seasonTab('s1')),
          matching: find.byType(AppButton),
        ),
      ),
      isSemantics(label: long, isButton: true, isSelected: true),
    );

    // 折叠入口同样只占一行,完整名称在 tooltip 与语义 label 里。
    await _pump(
      tester,
      seasons: _seasons(6, name: (i) => i == 1 ? long : '第 $i 季'),
      width: 300,
    );
    expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppTooltip && widget.message == long,
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byKey(CatalogKeys.seasonPicker),
          matching: find.byType(AppButton),
        ),
      ),
      isSemantics(label: '切换季，当前为$long', isButton: true),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  }, semanticsEnabled: true);
}
