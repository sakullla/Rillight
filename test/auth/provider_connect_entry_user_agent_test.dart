import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/provider_connect_dialog.dart';
import 'package:rillight/auth/tv_connect_page.dart';

void main() {
  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} forwards draft UA into editable Plex login',
      (tester) async {
        tester.view.physicalSize = environment.isTv
            ? const Size(960, 540)
            : environment.isDesktop
            ? const Size(1024, 768)
            : const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = AuthController.memory()
          ..connectDraft = (ConnectDraft(addingAnother: false)
            ..userAgent = 'Draft-UA/1');
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => switch (environment.presentation) {
                AppPresentation.desktop => const ConnectPage(),
                AppPresentation.androidPhone => const AndroidConnectPage(),
                AppPresentation.androidTv => const TvConnectPage(),
              },
            ),
          ],
        );
        try {
          await tester.pumpWidget(
            PresentationScope(
              environment: environment,
              child: AuthScope(
                controller: auth,
                child: MaterialApp.router(
                  routerConfig: router,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final entry = find.byKey(
            Key(switch (environment.presentation) {
              AppPresentation.desktop => 'connect-provider-entry',
              AppPresentation.androidPhone => 'android-provider-entry',
              AppPresentation.androidTv => 'tv-provider-entry',
            }),
          );
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('provider-type')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Plex').last);
          await tester.pumpAndSettle();
          final input = find.byKey(const Key('provider-user-agent'));
          expect(input, findsOneWidget);
          final controller =
              tester
                      .widget<ListenableBuilder>(
                        find
                            .descendant(
                              of: find.byType(ProviderConnectDialog),
                              matching: find.byType(ListenableBuilder),
                            )
                            .first,
                      )
                      .listenable
                  as ProviderConnectController;
          expect(controller.userAgent, 'Draft-UA/1');
          for (final value in ['Edited-UA/2', '']) {
            await tester.ensureVisible(input);
            if (environment.isTv) {
              expect(tester.widget(input), isA<TvInput>());
              await tester.tap(input);
              await tester.pumpAndSettle();
              await tester.enterText(
                find.byKey(const Key('tv-input-editor')),
                value,
              );
              await tester.testTextInput.receiveAction(TextInputAction.done);
            } else {
              await tester.enterText(input, value);
            }
            await tester.pumpAndSettle();
            expect(controller.userAgent, value);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          router.dispose();
          auth.dispose();
        }
      },
      tags: ['integration'],
    );
  }
}
