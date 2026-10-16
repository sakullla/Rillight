import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/ui/app_icons.dart';

void main() {
  test(
    'missing preference docks navigation and keeps an explicit floating choice',
    () async {
      final store = MemoryPhoneNavStyleStore();
      final controller = PhoneNavStyleController(store: store);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.floating, isFalse);

      await controller.setFloating(true);
      expect(store.value, isTrue);
      final again = PhoneNavStyleController(store: store);
      addTearDown(again.dispose);
      await again.load();
      expect(again.floating, isTrue);
    },
  );

  testWidgets(
    'floating navigation stays inset and docked navigation is flush',
    (tester) async {
      Future<void> pump(bool floating) {
        return tester.pumpWidget(
          CupertinoTestApp(
            theme: AppUiTheme.dark(),
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: [
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: CupertinoPageScaffold(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const SizedBox.expand(),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: PhoneBottomNav(
                      index: 0,
                      floating: floating,
                      onSelected: (_) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      await pump(true);
      final floatingRect = tester.getRect(find.byType(CupertinoTabBar));
      expect(floatingRect.left, AppMobileNav.floatMargin);
      expect(floatingRect.right, 800 - AppMobileNav.floatMargin);
      expect(floatingRect.height, AppMobileNav.floatingHeight);
      expect(floatingRect.bottom, lessThan(600));

      await pump(false);
      final dockedRect = tester.getRect(find.byType(CupertinoTabBar));
      expect(dockedRect.left, 0);
      expect(dockedRect.right, 800);
      expect(dockedRect.height, AppMobileNav.dockedHeight);
      expect(dockedRect.bottom, 600);
    },
  );

  testWidgets('floatingOf falls back to false without PhoneNavStyle ancestor', (
    tester,
  ) async {
    late bool fallback;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: Builder(
          builder: (context) {
            fallback = PhoneNavStyle.floatingOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(fallback, isFalse);
  });

  testWidgets('bottom bar keeps home, library, aggregation and search', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.phoneDark(),
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: PhoneBottomNav(
              index: 0,
              floating: false,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CupertinoTabBar), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('媒体库'), findsOneWidget);
    expect(find.text('聚合'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
  });

  testWidgets('phone top bar back and title use phoneLight and phoneDark', (
    tester,
  ) async {
    for (final theme in [AppUiTheme.phoneLight(), AppUiTheme.phoneDark()]) {
      var popped = false;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: AppButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (context) => CupertinoPageScaffold(
                          navigationBar: const PhoneTopBar(title: Text('演职员')),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final bar = find.byType(PhoneTopBar);
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.text('演职员')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.byKey(PhoneTopBar.backKey)),
        findsOneWidget,
      );
      expect(
        tester.widget<ColoredBox>(find.byKey(PhoneTopBar.backgroundKey)).color,
        theme.scaffoldBackgroundColor,
      );
      final titleStyle = DefaultTextStyle.of(tester.element(find.text('演职员')))
          .style;
      expect(titleStyle.color, theme.colorScheme.onSurface);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(PhoneTopBar.backKey),
          matching: find.byIcon(AppIcons.back),
        ),
      );
      expect(
        icon.color ??
            IconTheme.of(
              tester.element(
                find.descendant(
                  of: find.byKey(PhoneTopBar.backKey),
                  matching: find.byIcon(AppIcons.back),
                ),
              ),
            ).color,
        theme.colorScheme.onSurface,
      );
      await tester.tap(find.byKey(PhoneTopBar.backKey));
      await tester.pumpAndSettle();
      expect(find.text('演职员'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      popped = true;
      expect(popped, isTrue);
    }
  });
}
