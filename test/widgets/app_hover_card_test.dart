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

void main() {
  testWidgets('hover scales the card up and shows a shadow', (tester) async {
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

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(AppHoverCard)));
    await tester.pump();

    expect(_scale(tester).scale, 1.04);
    expect((_decoration(tester).boxShadow!.single.color.a), greaterThan(0));

    await gesture.moveTo(Offset.zero);
    await tester.pump();

    expect(_scale(tester).scale, 1.0);
  });

  testWidgets('keyboard focus shows a focus ring', (tester) async {
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

    final border = _foregroundDecoration(tester).border! as Border;
    expect(border.top.color, theme.colorScheme.primary);
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
