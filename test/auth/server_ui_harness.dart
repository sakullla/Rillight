import '../helpers/cupertino_test_app.dart';
import '../helpers/settle.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/server_selection_page.dart';

Future<void> pumpServerSelection(
  WidgetTester tester,
  AuthController auth, {
  bool phone = false,
  double scale = 1,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    CupertinoTestApp(
      theme: dark ? AppUiTheme.dark() : AppUiTheme.light(),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      builder: (context, child) => AppUiTheme(
        data: dark ? AppUiTheme.dark() : AppUiTheme.light(),
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: CupertinoPageScaffold(
        child: Builder(
          builder: (context) => AppButton(
            onPressed: () =>
                showServerSelection(context, auth: auth, phone: phone),
            child: const Text('open-servers'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-servers'));
  await settle(tester);
}

Future<void> serverUiTap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settle(tester);
}

Future<void> openServerEditor(WidgetTester tester, String id) async {
  await serverUiTap(tester, Key('server-more-$id'));
  await serverUiTap(tester, Key('server-action-edit-$id'));
}
