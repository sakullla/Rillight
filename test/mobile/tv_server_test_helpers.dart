import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';

import '../helpers/settle.dart';

FocusNode tvTarget(WidgetTester tester, Key key) => tester
    .widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(key),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    )
    .focusNode!;

Future<void> tvPress(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  tvTarget(tester, key).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await settle(tester);
}

Future<void> tvEdit(WidgetTester tester, Key key, String text) async {
  await tvPress(tester, key);
  await tester.enterText(find.byKey(const Key('tv-input-editor')), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await settle(tester);
}

Future<void> tvBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settle(tester);
}

Future<void> tvOpenEditor(WidgetTester tester, String id) async {
  await tvPress(tester, Key('server-more-$id'));
  await tvPress(tester, const Key('server-more-edit'));
}
