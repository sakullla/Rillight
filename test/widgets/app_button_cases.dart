import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/app_icons.dart';
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

  testWidgets(
    'filled is a solid accent without glow; selected follows primary',
    (tester) async {
      for (final theme in [
        AppUiTheme.dark(),
        AppUiTheme.light(),
        AppUiTheme.phoneDark(),
        AppUiTheme.phoneLight(),
      ]) {
        final colors = theme.colorScheme;
        await _pump(
          tester,
          AppButton(
            onPressed: () {},
            variant: AppButtonVariant.filled,
            child: const Text('播放'),
          ),
          theme: theme,
        );
        expect(_decoration(tester).gradient, isNull);
        expect(_decoration(tester).shadows, isNull);
        expect(_fill(tester), colors.primary);
        expect(_foreground(tester), colors.onPrimary);

        await _pump(
          tester,
          AppButton(
            onPressed: () {},
            variant: AppButtonVariant.tinted,
            child: const Text('次操作'),
          ),
          theme: theme,
        );
        expect(_fill(tester), colors.primaryContainer);
        expect(_side(tester).color.a, greaterThan(0));

        await _pump(
          tester,
          AppButton(
            onPressed: () {},
            variant: AppButtonVariant.outlined,
            child: const Text('描边'),
          ),
          theme: theme,
        );
        expect(_fill(tester).a, greaterThan(0));
        expect(_side(tester).color, colors.outline);

        // 悬停、按下也只换实底,不出现渐变或色光。
        final pointer = await tester.startGesture(
          tester.getCenter(find.byType(AppButton)),
        );
        await tester.pump();
        expect(_decoration(tester).gradient, isNull);
        expect(_decoration(tester).shadows, isNull);
        await pointer.up();
        await tester.pump();

        for (final variant in [
          AppButtonVariant.plain,
          AppButtonVariant.outlined,
          AppButtonVariant.tinted,
          AppButtonVariant.filled,
        ]) {
          await _pump(
            tester,
            AppButton(
              onPressed: () {},
              variant: variant,
              selected: true,
              child: const Text('第 1 季'),
            ),
            theme: theme,
          );
          expect(_fill(tester), colors.primaryContainer, reason: '$variant');
          expect(
            _side(tester),
            BorderSide(color: colors.primary, width: 2),
            reason: '$variant',
          );
          expect(_foreground(tester), colors.onPrimaryContainer);
        }
      }
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

  testWidgets('secondary actions share one pill height per platform', (
    tester,
  ) async {
    for (final (theme, extent) in [
      (AppUiTheme.dark(), 40.0),
      (AppUiTheme.light(), 40.0),
      (AppUiTheme.phoneDark(), 44.0),
      (AppUiTheme.phoneLight(), 44.0),
    ]) {
      await _pump(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppActionButton(
              key: const Key('a'),
              icon: AppIcons.favorite,
              label: '\u6536\u85cf',
              active: false,
              onPressed: () {},
            ),
            AppActionButton(
              key: const Key('b'),
              icon: AppIcons.play,
              label: '\u4ece\u5934\u64ad\u653e',
              onPressed: () {},
            ),
            AppActionButton(
              key: const Key('c'),
              icon: AppIcons.favorite,
              label: '\u5df2\u6536\u85cf',
              active: true,
              onPressed: () {},
            ),
          ],
        ),
        theme: theme,
      );
      for (final key in ['a', 'b', 'c']) {
        final face = _actionFace(tester, Key(key));
        expect(tester.getSize(face).height, extent, reason: key);
        // \u89e6\u63a7\u533a\u4e0d\u4f4e\u4e8e 44,\u6309\u94ae\u9762\u5728\u5176\u4e2d\u5c45\u4e2d\u3002
        expect(
          tester
              .getSize(
                find.descendant(
                  of: find.byKey(Key(key)),
                  matching: find.byType(AppButton),
                ),
              )
              .height,
          greaterThanOrEqualTo(44),
        );
        final shape =
            _actionDecoration(tester, Key(key)).shape as RoundedRectangleBorder;
        expect(
          shape.borderRadius.resolve(TextDirection.ltr),
          BorderRadius.circular(AppRadii.pill),
        );
        // \u5e26\u56fe\u6807\u548c\u6587\u5b57\u3002
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Icon),
          ),
          findsOneWidget,
        );
      }
    }
  });

  testWidgets('secondary labels wrap instead of showing an ellipsis', (
    tester,
  ) async {
    const label =
        '\u6253\u5f00\u5176\u4ed6\u670d\u52a1\u5668\u4e0a\u7684\u540c\u4e00\u90e8\u5267\u96c6\u6765\u6e90\u5e76\u5207\u6362\u64ad\u653e';
    await _pump(
      tester,
      SizedBox(
        width: 180,
        child: Center(
          child: AppActionButton(
            key: const Key('long'),
            icon: AppIcons.play,
            label: label,
            onPressed: () {},
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.text(label));
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(text.softWrap, isTrue);
    expect(text.maxLines, 2);
    // \u4e24\u884c\u6587\u5b57:\u6309\u94ae\u9762\u9ad8\u4e8e\u5355\u884c\u7684 40\u3002
    expect(tester.getSize(find.text(label)).height, greaterThan(30));
    expect(
      tester.getSize(_actionFace(tester, const Key('long'))).height,
      greaterThan(AppActionButton.desktopExtent),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'active secondary fills primaryContainer with a filled icon and toggles',
    (tester) async {
      final semantics = tester.ensureSemantics();
      for (final theme in [AppUiTheme.dark(), AppUiTheme.phoneLight()]) {
        final colors = theme.colorScheme;
        for (final active in [false, true]) {
          await _pump(
            tester,
            AppActionButton(
              key: const Key('toggle'),
              icon: AppIcons.favorite,
              label: active ? '\u5df2\u6536\u85cf' : '\u6536\u85cf',
              active: active,
              onPressed: () {},
            ),
            theme: theme,
          );
          final decoration = _actionDecoration(tester, const Key('toggle'));
          final side = (decoration.shape as OutlinedBorder).side;
          final icon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('toggle')),
              matching: find.byType(Icon),
            ),
          );
          if (active) {
            expect(decoration.color, colors.primaryContainer);
            expect(side.color, colors.primary);
            expect(icon.fill, AppIcons.filled);
          } else {
            expect(decoration.color, isNot(colors.primaryContainer));
            expect(side.color, isNot(colors.primary));
            expect(icon.fill, AppIcons.outline);
          }
          expect(
            tester.getSemantics(find.byType(AppButton)),
            isSemantics(
              hasToggledState: true,
              isToggled: active,
              isButton: true,
            ),
          );
        }
      }
      semantics.dispose();
    },
    semanticsEnabled: true,
  );

  testWidgets('primary is solid accent; tertiary is text only', (tester) async {
    final colors = AppUiTheme.dark().colorScheme;
    await _pump(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppActionButton(
            key: const Key('primary'),
            tier: AppActionTier.primary,
            icon: AppIcons.play,
            label: '\u64ad\u653e',
            onPressed: () {},
          ),
          AppActionButton(
            key: const Key('secondary'),
            icon: AppIcons.play,
            label: '\u4ece\u5934\u64ad\u653e',
            onPressed: () {},
          ),
          AppActionButton(
            key: const Key('tertiary'),
            tier: AppActionTier.tertiary,
            icon: AppIcons.play,
            label: '\u66f4\u591a',
            onPressed: () {},
          ),
        ],
      ),
    );
    expect(
      _actionDecoration(tester, const Key('primary')).color,
      colors.primary,
    );
    expect(
      tester.getSize(_actionFace(tester, const Key('primary'))).height,
      tester.getSize(_actionFace(tester, const Key('secondary'))).height,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('tertiary')),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    expect(find.text('\u66f4\u591a'), findsOneWidget);
    expect(
      _actionDecoration(tester, const Key('tertiary')).color,
      AppInk.transparent,
    );
  });

  testWidgets('icon-only action uses its tooltip as the semantic label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      AppActionButton.icon(
        icon: AppIcons.favorite,
        tooltip: '\u6536\u85cf',
        active: false,
        onPressed: () {},
      ),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppTooltip && widget.message == '\u6536\u85cf',
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byType(AppButton)),
      isSemantics(label: '\u6536\u85cf', isButton: true),
    );
    semantics.dispose();
  }, semanticsEnabled: true);

  testWidgets('TvAction active rests on primaryContainer; focus unchanged', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final theme = AppUiTheme.tvDark().copyWith(tv: true);
    final colors = theme.colorScheme;
    final node = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
    Future<void> pumpTv(bool? active) => _pump(
      tester,
      TvAction(
        key: const Key('tv'),
        pill: true,
        focusNode: node,
        active: active,
        onPressed: () {},
        child: const Text('\u5df2\u6536\u85cf'),
      ),
      theme: theme,
    );
    BoxDecoration tvDecoration() =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(const Key('tv')),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    double tvScale() => tester
        .widget<AnimatedScale>(
          find.descendant(
            of: find.byKey(const Key('tv')),
            matching: find.byType(AnimatedScale),
          ),
        )
        .scale;

    await pumpTv(null);
    final plain = tvDecoration().color;
    expect(plain, isNot(colors.primaryContainer));

    await pumpTv(true);
    await tester.pumpAndSettle();
    expect(tvDecoration().color, colors.primaryContainer);
    final text = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('tv')),
        matching: find.byType(RichText),
      ),
    );
    expect(text.text.style!.color, colors.onPrimaryContainer);
    expect(
      tester.getSemantics(find.text('已收藏')),
      isSemantics(hasToggledState: true, isToggled: true),
    );
    expect(tvScale(), 1.0);

    node.requestFocus();
    await tester.pumpAndSettle();
    // \u805a\u7126\u4ecd\u6574\u5757\u53cd\u76f8\u3001\u653e\u5927,\u4e0e\u672a\u6fc0\u6d3b\u7684\u6309\u94ae\u4e00\u81f4\u3002
    expect(tvDecoration().color, colors.inverseSurface);
    expect(tvScale(), TvAction.focusedScale);

    await pumpTv(false);
    await tester.pumpAndSettle();
    expect(tvDecoration().color, colors.inverseSurface);
    node.unfocus();
    await tester.pumpAndSettle();
    expect(tvDecoration().color, plain);
    expect(
      tester.getSemantics(find.text('已收藏')),
      isSemantics(hasToggledState: true, isToggled: false),
    );
    semantics.dispose();
  }, semanticsEnabled: true);
}

Finder _actionFace(WidgetTester tester, Key key) {
  final inset = find.descendant(
    of: find.byKey(key),
    matching: find.byKey(AppButton.faceKey),
  );
  if (inset.evaluate().isNotEmpty) return inset;
  return find
      .descendant(of: find.byKey(key), matching: find.byType(AnimatedContainer))
      .first;
}

ShapeDecoration _actionDecoration(WidgetTester tester, Key key) =>
    tester.widget<AnimatedContainer>(_actionFace(tester, key)).decoration!
        as ShapeDecoration;

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

/// 按钮一律实底,没有品牌渐变。
Color _fill(WidgetTester tester) {
  final decoration = _decoration(tester);
  expect(decoration.gradient, isNull);
  return decoration.color!;
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
