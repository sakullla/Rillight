import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/theme.dart';

void main() {
  test('missing preference keeps the navigation floating', () async {
    final store = MemoryPhoneNavStyleStore();
    final controller = PhoneNavStyleController(store: store);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.floating, isTrue);

    await controller.setFloating(false);
    expect(store.value, isFalse);
    final again = PhoneNavStyleController(store: store);
    addTearDown(again.dispose);
    await again.load();
    expect(again.floating, isFalse);
  });

  testWidgets(
    'floating navigation stays inset and docked navigation is flush',
    (tester) async {
      Future<void> pump(bool floating) {
        return tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              bottomNavigationBar: PhoneBottomNav(
                index: 0,
                floating: floating,
                onSelected: (_) {},
              ),
            ),
          ),
        );
      }

      await pump(true);
      final floatingRect = tester.getRect(find.byType(NavigationBar));
      expect(floatingRect.left, AppMobileNav.floatMargin);
      expect(floatingRect.right, 800 - AppMobileNav.floatMargin);
      expect(floatingRect.bottom, lessThan(600));

      await pump(false);
      final dockedRect = tester.getRect(find.byType(NavigationBar));
      expect(dockedRect.left, 0);
      expect(dockedRect.right, 800);
      expect(dockedRect.bottom, 600);
    },
  );
}
