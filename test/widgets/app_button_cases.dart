import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

void main() {
  testWidgets('AppButton keeps four emphasis levels and one radius per level', (
    tester,
  ) async {
    expect(AppButtonVariant.values, [
      AppButtonVariant.plain,
      AppButtonVariant.filled,
      AppButtonVariant.tinted,
      AppButtonVariant.outlined,
    ]);

    final themes = <AppUiThemeData>[
      AppUiTheme.dark(),
      AppUiTheme.light(),
      AppUiTheme.phoneDark(),
      AppUiTheme.phoneLight(),
      AppUiTheme.tvDark().copyWith(tv: true),
      AppUiTheme.tvLight().copyWith(tv: true),
    ];
    for (final variant in AppButtonVariant.values) {
      BorderRadius? radius;
      for (final theme in themes) {
        for (final selected in [false, true]) {
          await _pump(
            tester,
            AppButton(
              onPressed: () {},
              variant: variant,
              selected: selected,
              child: const Text('确定'),
            ),
            theme: theme,
          );
          final resolved = _radius(tester);
          radius ??= resolved;
          expect(resolved, radius);
          // 纯文本/图标按钮是圆角矩形,有底色或描边的按钮是胶囊。
          expect(
            resolved,
            BorderRadius.circular(
              variant == AppButtonVariant.plain ? AppRadii.md : AppRadii.pill,
            ),
          );
        }
      }
    }

    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 2; i++)
            AppButton(
              key: Key('plain-$i'),
              onPressed: () {},
              child: const Text('确定'),
            ),
        ],
      ),
    );
    expect(
      _radius(tester, const Key('plain-0')),
      _radius(tester, const Key('plain-1')),
    );
  });

  testWidgets('desktop hover, focus, press, disabled and selected differ', (
    tester,
  ) async {
    final previous = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = previous);
    for (final theme in [AppUiTheme.dark(), AppUiTheme.light()]) {
      for (final variant in AppButtonVariant.values) {
        final resting = await _look(
          tester,
          AppButton(
            onPressed: () {},
            variant: variant,
            child: const Text('确定'),
          ),
          theme: theme,
        );
        final hover = await _look(
          tester,
          AppButton(
            onPressed: () {},
            variant: variant,
            child: const Text('确定'),
          ),
          theme: theme,
          hover: true,
        );
        final focus = await _look(
          tester,
          AppButton(
            onPressed: () {},
            variant: variant,
            child: const Text('确定'),
          ),
          theme: theme,
          focus: true,
        );
        final pressed = await _look(
          tester,
          AppButton(
            onPressed: () {},
            variant: variant,
            child: const Text('确定'),
          ),
          theme: theme,
          press: true,
        );
        final disabled = await _look(
          tester,
          AppButton(variant: variant, child: const Text('确定')),
          theme: theme,
        );
        final selected = await _look(
          tester,
          AppButton(
            onPressed: () {},
            variant: variant,
            selected: true,
            child: const Text('确定'),
          ),
          theme: theme,
        );
        final faces = [resting, hover, focus, pressed, disabled, selected];
        expect(
          faces.toSet(),
          hasLength(faces.length),
          reason: '$theme $variant',
        );
        for (final face in faces.skip(1)) {
          expect(face, isNot(resting));
        }
      }
    }
  });

  testWidgets('keyboard focus and held confirm differ from the resting face', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
    var taps = 0;
    await _pump(
      tester,
      AppButton(
        focusNode: node,
        onPressed: () => taps++,
        child: const Text('确定'),
      ),
    );
    final resting = _signature(tester);
    node.requestFocus();
    await tester.pump();
    final focused = _signature(tester);
    expect(focused, isNot(resting));
    expect(
      _side(tester),
      BorderSide(color: AppUiTheme.dark().colorScheme.primary, width: 2),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_signature(tester), isNot(focused));
    expect(taps, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('TV focus changes fill and scale', (tester) async {
    final node = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
    final theme = AppUiTheme.tvDark().copyWith(tv: true);
    await _pump(
      tester,
      AppButton(focusNode: node, onPressed: () {}, child: const Text('播放')),
      theme: theme,
    );
    expect(_scale(tester), 1);
    expect(_fill(tester), isNot(theme.colorScheme.inverseSurface));
    node.requestFocus();
    await tester.pump();
    expect(_fill(tester), theme.colorScheme.inverseSurface);
    expect(_scale(tester), greaterThan(1));
    expect(_foreground(tester), theme.colorScheme.onInverseSurface);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(_fill(tester), isNot(theme.colorScheme.inverseSurface));
    expect(_scale(tester), isNot(greaterThan(1)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
  });

  testWidgets(
    'hit target stays at least 44 and disabled confirm does nothing',
    (tester) async {
      var taps = 0;
      for (final variant in AppButtonVariant.values) {
        await _pump(
          tester,
          AppButton(
            onPressed: () => taps++,
            variant: variant,
            child: const Text('OK'),
          ),
        );
        final size = tester.getSize(find.byType(AppButton));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
        await tester.tap(find.text('OK'));
        expect(taps, 1);
        taps = 0;
      }

      await _pump(
        tester,
        AppIconButton(
          onPressed: () => taps++,
          icon: const Icon(CupertinoIcons.play_fill),
        ),
      );
      final iconSize = tester.getSize(find.byType(AppIconButton));
      expect(iconSize.width, greaterThanOrEqualTo(44));
      expect(iconSize.height, greaterThanOrEqualTo(44));

      await _pump(
        tester,
        AppButton(
          onPressed: () {},
          style: const AppButtonStyle(
            minimumSize: Size(32, 32),
            padding: EdgeInsets.zero,
          ),
          child: const SizedBox.shrink(),
        ),
      );
      final smallMinimum = tester.getSize(find.byType(AppButton));
      expect(smallMinimum.width, greaterThanOrEqualTo(44));
      expect(smallMinimum.height, greaterThanOrEqualTo(44));

      await _pump(
        tester,
        AppButton(
          onPressed: () {},
          style: const AppButtonStyle(
            minimumSize: Size(40, 40),
            fixedSize: Size(40, 40),
            padding: EdgeInsets.zero,
          ),
          child: const SizedBox.shrink(),
        ),
      );
      final smallFixed = tester.getSize(find.byType(AppButton));
      expect(smallFixed.width, greaterThanOrEqualTo(44));
      expect(smallFixed.height, greaterThanOrEqualTo(44));

      await _pump(
        tester,
        AppIconButton(
          onPressed: () {},
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          icon: const Icon(CupertinoIcons.play_fill),
        ),
      );
      final smallIcon = tester.getSize(find.byType(AppIconButton));
      expect(smallIcon.width, greaterThanOrEqualTo(44));
      expect(smallIcon.height, greaterThanOrEqualTo(44));

      final node = FocusNode();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        node.dispose();
      });
      await _pump(
        tester,
        AppButton(
          focusNode: node,
          onPressed: () => taps++,
          variant: AppButtonVariant.filled,
          child: const Text('确定'),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(taps, 3);

      await _pump(
        tester,
        AppButton(variant: AppButtonVariant.filled, child: const Text('确定')),
      );
      expect(_fill(tester), AppUiTheme.dark().colorScheme.surfaceContainerHigh);
      expect(
        tester.widget<CupertinoButton>(find.byType(CupertinoButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('确定'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(taps, 3);
    },
  );

  testWidgets('explicit fill stays put until focus only adds the focus ring', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
    const swatch = Color(0xFF336699);
    await _pump(
      tester,
      AppButton(
        focusNode: node,
        onPressed: () {},
        color: swatch,
        child: const Text('色'),
      ),
    );
    expect(_fill(tester), swatch);
    node.requestFocus();
    await tester.pump();
    expect(_fill(tester), swatch);
    expect(
      _side(tester),
      BorderSide(color: AppUiTheme.dark().colorScheme.primary, width: 2),
    );
  });
}

Future<void> _pump(WidgetTester tester, Widget child, {AppUiThemeData? theme}) {
  return tester.pumpWidget(
    CupertinoTestApp(
      theme: theme ?? AppUiTheme.dark(),
      builder: (context, routed) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: routed!,
      ),
      home: CupertinoPageScaffold(child: Center(child: child)),
    ),
  );
}

Future<(int, int, double, int, double)> _look(
  WidgetTester tester,
  AppButton button, {
  required AppUiThemeData theme,
  bool hover = false,
  bool focus = false,
  bool press = false,
}) async {
  final node = focus ? FocusNode() : null;
  if (node != null) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
  }
  await _pump(
    tester,
    node == null ? button : _withFocus(button, node),
    theme: theme,
  );
  TestGesture? pointer;
  if (hover) {
    pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(
      location: tester.getCenter(find.byType(AppButton)),
    );
    await tester.pump();
  }
  if (node != null) {
    node.requestFocus();
    // A preceding pointer event reports focus immediately and paints it
    // on the following frame.
    await tester.pump();
    await tester.pump();
  }
  if (press) {
    pointer = await tester.startGesture(
      tester.getCenter(find.byType(AppButton)),
    );
    await tester.pump();
  }
  final signature = _signature(tester);
  if (press) await pointer!.up();
  if (hover && !press) await pointer!.removePointer();
  await tester.pump();
  return signature;
}

AppButton _withFocus(AppButton button, FocusNode node) {
  return AppButton(
    focusNode: node,
    onPressed: button.onPressed,
    variant: button.variant,
    selected: button.selected,
    color: button.color,
    foregroundColor: button.foregroundColor,
    child: button.child,
  );
}

(int, int, double, int, double) _signature(WidgetTester tester) {
  final side = _side(tester);
  return (
    _fill(tester).toARGB32(),
    side.color.toARGB32(),
    side.width,
    _foreground(tester).toARGB32(),
    _scale(tester),
  );
}

/// 实底主按钮铺品牌渐变,以渐变起点作为它的底色。
Color _fill(WidgetTester tester) {
  final decoration = _decoration(tester);
  return decoration.color ??
      (decoration.gradient! as LinearGradient).colors.first;
}

BorderSide _side(WidgetTester tester) =>
    (_decoration(tester).shape as OutlinedBorder).side;

ShapeDecoration _decoration(WidgetTester tester, [Key? key]) {
  final box = key == null
      ? find.descendant(
          of: find.byType(AppButton),
          matching: find.byType(AnimatedContainer),
        )
      : find.descendant(
          of: find.byKey(key),
          matching: find.byType(AnimatedContainer),
        );
  return tester.widget<AnimatedContainer>(box).decoration! as ShapeDecoration;
}

BorderRadius _radius(WidgetTester tester, [Key? key]) {
  final shape = _decoration(tester, key).shape as RoundedRectangleBorder;
  return shape.borderRadius.resolve(TextDirection.ltr);
}

Color _foreground(WidgetTester tester) {
  return tester
      .widget<RichText>(
        find.descendant(
          of: find.byType(AppButton),
          matching: find.byType(RichText),
        ),
      )
      .text
      .style!
      .color!;
}

double _scale(WidgetTester tester) {
  return tester
      .widget<AnimatedScale>(
        find.descendant(
          of: find.byType(AppButton),
          matching: find.byType(AnimatedScale),
        ),
      )
      .scale;
}
