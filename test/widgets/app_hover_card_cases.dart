import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: Center(child: child)),
  );
}

AnimatedScale _scale(WidgetTester tester) {
  return tester.widget<AnimatedScale>(find.byType(AnimatedScale));
}

BoxDecoration _decoration(WidgetTester tester) {
  return tester
          .widget<AnimatedContainer>(find.byType(AnimatedContainer))
          .decoration!
      as BoxDecoration;
}

BoxDecoration _foregroundDecoration(WidgetTester tester) {
  return tester
          .widget<AnimatedContainer>(find.byType(AnimatedContainer))
          .foregroundDecoration!
      as BoxDecoration;
}

Border _ring(WidgetTester tester) {
  return _foregroundDecoration(tester).border! as Border;
}

Future<TestGesture> _hoverCard(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(AppHoverCard)));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('hover scales the card up and shows the focus ring', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () {},
          child: const SizedBox(width: 120, height: 180),
        ),
      ),
    );
    expect(_scale(tester).scale, 1.0);
    expect((_decoration(tester).boxShadow!.single.color.a), 0);
    expect(_ring(tester).top.color, Colors.transparent);

    final gesture = await _hoverCard(tester);

    expect(_scale(tester).scale, 1.04);
    expect((_decoration(tester).boxShadow!.single.color.a), greaterThan(0));
    expect(_ring(tester).top.color, theme.colorScheme.primary);
    expect(_ring(tester).top.width, 2);

    await gesture.moveTo(Offset.zero);
    await tester.pump();

    expect(_scale(tester).scale, 1.0);
    expect(_ring(tester).top.color, Colors.transparent);
  });

  testWidgets('keyboard focus shows the same focus ring without scaling', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () {},
          autofocus: true,
          child: const SizedBox(width: 120, height: 180),
        ),
      ),
    );
    await tester.pump();

    expect(_scale(tester).scale, 1.0);
    expect(_ring(tester).top.color, theme.colorScheme.primary);
    expect(_ring(tester).top.width, 2);
  });

  testWidgets(
    'reduced motion keeps a default-scale card at scale 1 with the focus ring',
    (tester) async {
      final theme = AppTheme.dark();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _wrap(
            AppHoverCard(
              onTap: () {},
              child: const SizedBox(width: 120, height: 180),
            ),
          ),
        ),
      );
      expect(find.byType(AnimatedScale), findsNothing);

      await _hoverCard(tester);

      expect(find.byType(AnimatedScale), findsNothing);
      expect(tester.getSize(find.byType(AppHoverCard)), const Size(120, 180));
      expect(_ring(tester).top.color, theme.colorScheme.primary);
    },
  );

  testWidgets('hoverScale of 1 shows the ring without enlarging', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () {},
          hoverScale: 1,
          child: const SizedBox(width: 120, height: 180),
        ),
      ),
    );
    expect(find.byType(AnimatedScale), findsNothing);

    await _hoverCard(tester);

    expect(find.byType(AnimatedScale), findsNothing);
    expect(_ring(tester).top.color, theme.colorScheme.primary);
    expect(_ring(tester).top.width, 2);
  });

  testWidgets('hover and focus notify onHighlighted', (tester) async {
    final highlights = <bool>[];
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () {},
          onHighlighted: highlights.add,
          child: const SizedBox(width: 120, height: 180),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(AppHoverCard)));
    await tester.pump();
    expect(highlights, [true]);

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(highlights, [true, false]);
  });

  testWidgets('autofocus notifies onHighlighted', (tester) async {
    final highlights = <bool>[];
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () {},
          autofocus: true,
          onHighlighted: highlights.add,
          child: const SizedBox(width: 120, height: 180),
        ),
      ),
    );
    await tester.pump();
    expect(highlights, [true]);
  });

  testWidgets('tap forwards to onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        AppHoverCard(
          onTap: () => taps++,
          child: const SizedBox(width: 120, height: 180, child: Text('卡片')),
        ),
      ),
    );

    await tester.tap(find.text('卡片'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
