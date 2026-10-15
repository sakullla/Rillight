import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/widgets/scrim_icon_button.dart';

const _key = Key('scrim-button');

/// WCAG 对比度。
double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

Future<void> _pump(
  WidgetTester tester,
  Widget button, {
  bool disableAnimations = false,
  bool highContrast = false,
  AppUiThemeData? theme,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        highContrast: highContrast,
      ),
      child: CupertinoTestApp(
        theme: theme ?? AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: Stack(
            children: [
              const ColoredBox(
                color: Color(0xffffffff),
                child: SizedBox.expand(),
              ),
              Center(child: button),
            ],
          ),
        ),
      ),
    ),
  );
}

AppButtonStyle _styleOf(WidgetTester tester) {
  return tester
      .widget<AppIconButton>(
        find.descendant(
          of: find.byKey(_key),
          matching: find.byType(AppIconButton),
        ),
      )
      .style!;
}

void main() {
  testWidgets('ScrimIconButton has solid scrim backing and white icon', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      ScrimIconButton(
        key: _key,
        tooltip: '向左',
        icon: const Icon(CupertinoIcons.chevron_left),
        onPressed: () => taps++,
      ),
    );

    expect(find.byKey(_key), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(findAppTooltip('向左'), findsOneWidget);
    expect(tester.getSize(find.byKey(_key)), const Size(44, 44));

    final scheme = AppUiTheme.dark().colorScheme;
    final style = _styleOf(tester);
    final background = style.backgroundColor!;
    expect(background.a, closeTo(AppScrim.control, 0.01));
    expect(background.withValues(alpha: 1), scheme.scrim.withValues(alpha: 1));
    // 图标固定白色:叠在黑色 scrim 上,不随主题 onSurface 换色。
    expect(style.foregroundColor!, const Color(0xffffffff));
    expect(style.shape!, isA<CircleBorder>());
    final side = style.side!;
    expect(side.width, 1);
    expect(side.color.a, closeTo(AppGlass.edgeLight, 0.01));

    final icon = tester.widget<Icon>(
      find.descendant(of: find.byKey(_key), matching: find.byType(Icon)),
    );
    final iconTheme = IconTheme.of(tester.element(find.byWidget(icon)));
    expect(iconTheme.color, const Color(0xffffffff));
    expect(iconTheme.size, 20);

    await tester.tap(find.byKey(_key));
    expect(taps, 1);
  });

  testWidgets('ScrimIconButton keeps a white icon under the light theme', (
    tester,
  ) async {
    // 浅色主题:底衬仍是黑色 scrim,深色 onSurface 图标会不可读;
    // 前景必须保持白色(对比 ≥ 3:1)。
    await _pump(
      tester,
      ScrimIconButton(
        key: _key,
        icon: const Icon(CupertinoIcons.chevron_left),
        onPressed: () {},
      ),
      theme: AppUiTheme.light(),
    );

    final scheme = AppUiTheme.light().colorScheme;
    final style = _styleOf(tester);
    final background = style.backgroundColor!;
    expect(background.withValues(alpha: 1), scheme.scrim.withValues(alpha: 1));
    final foreground = style.foregroundColor!;
    expect(foreground, const Color(0xffffffff));
    // 白图标与黑色 scrim 底衬的对比度。
    expect(
      _contrast(const Color(0xffffffff), background.withValues(alpha: 1)),
      greaterThan(3),
    );
  });

  testWidgets('ScrimIconButton large size is 48 with a 24 icon', (
    tester,
  ) async {
    await _pump(
      tester,
      ScrimIconButton(
        key: _key,
        size: ScrimIconButtonSize.large,
        icon: const Icon(CupertinoIcons.play_fill),
        onPressed: () {},
      ),
    );
    expect(tester.getSize(find.byKey(_key)), const Size(48, 48));
    final icon = tester.widget<Icon>(
      find.descendant(of: find.byKey(_key), matching: find.byType(Icon)),
    );
    expect(IconTheme.of(tester.element(find.byWidget(icon))).size, 24);
  });

  testWidgets('ScrimIconButton with null onPressed is disabled', (
    tester,
  ) async {
    await _pump(
      tester,
      const ScrimIconButton(
        key: _key,
        icon: Icon(CupertinoIcons.chevron_right),
        onPressed: null,
      ),
    );
    final button = tester.widget<AppIconButton>(
      find.descendant(
        of: find.byKey(_key),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(button.onPressed, isNull);

    final icon = tester.widget<Icon>(
      find.descendant(of: find.byKey(_key), matching: find.byType(Icon)),
    );
    final color = IconTheme.of(tester.element(find.byWidget(icon))).color!;
    expect(color.a, closeTo(AppScrim.controlDisabledIcon, 0.01));
    // 禁用态也是白色图标降 alpha,底衬保持黑色 scrim。
    expect(color.withValues(alpha: 1), const Color(0xffffffff));
    expect(_styleOf(tester).backgroundColor!, isNotNull);
  });

  testWidgets('ScrimIconButton raises backing alpha for high contrast', (
    tester,
  ) async {
    await _pump(
      tester,
      ScrimIconButton(
        key: _key,
        icon: const Icon(CupertinoIcons.arrow_clockwise),
        onPressed: () {},
      ),
      highContrast: true,
    );
    final background = _styleOf(tester).backgroundColor!;
    expect(
      background.a,
      greaterThanOrEqualTo(AppScrim.highContrastAlpha - 0.01),
    );
  });

  testWidgets('reduced motion preserves icon backing transparency', (
    tester,
  ) async {
    await _pump(
      tester,
      ScrimIconButton(
        key: _key,
        icon: const Icon(CupertinoIcons.arrow_clockwise),
        onPressed: () {},
      ),
      disableAnimations: true,
    );
    expect(
      _styleOf(tester).backgroundColor!.a,
      closeTo(AppScrim.control, 0.01),
    );
  });
}
