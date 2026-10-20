import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/widgets/liquid_glass.dart';

void main() {
  testWidgets('LiquidGlass blurs content behind it', (tester) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: const CupertinoPageScaffold(
          child: Stack(
            children: [
              ColoredBox(color: Color(0xffff3b30), child: SizedBox.expand()),
              Center(
                child: LiquidGlass(
                  kind: LiquidGlassKind.panel,
                  padding: EdgeInsets.all(16),
                  child: Text('玻璃'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('玻璃'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('LiquidGlass skips blur when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: CupertinoTestApp(
          theme: AppUiTheme.dark(),
          home: const CupertinoPageScaffold(
            child: LiquidGlass(child: Text('实色')),
          ),
        ),
      ),
    );
    expect(find.text('实色'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('LiquidGlassBackdrop can disable blur', (tester) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: const CupertinoPageScaffold(
          child: LiquidGlassBackdrop(
            enabled: false,
            child: LiquidGlass(child: Text('播放器')),
          ),
        ),
      ),
    );
    expect(find.text('播放器'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('LiquidGlass keeps blur and tint without specular or edge', (
    tester,
  ) async {
    for (final theme in [AppUiTheme.dark(), AppUiTheme.light()]) {
      for (final kind in LiquidGlassKind.values) {
        await tester.pumpWidget(
          CupertinoTestApp(
            theme: theme,
            home: CupertinoPageScaffold(
              child: Center(
                child: LiquidGlass(kind: kind, child: const Text('玻璃')),
              ),
            ),
          ),
        );
        expect(find.byType(BackdropFilter), findsOneWidget);
        final decorations = [
          for (final box in tester.widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(LiquidGlass),
              matching: find.byType(DecoratedBox),
            ),
          ))
            box.decoration as BoxDecoration,
        ];
        expect(decorations, hasLength(1), reason: '$kind');
        final face = decorations.single;
        expect(face.gradient, isNull, reason: '$kind specular');
        expect(face.border, isNull, reason: '$kind edge light');
        expect(face.color, isNotNull);
        expect(face.color!.a, greaterThan(0));
        expect(face.color!.a, lessThan(1));
      }
    }
  });
}
