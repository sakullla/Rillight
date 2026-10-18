import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/aggregation/history/history_store.dart';
import 'package:rillight/app/android_bootstrap.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/startup_failure.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/startup_recovery.dart';

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

Future<ConfigurationUpgradeFailure> _historyFailure(
  Directory dir, {
  required bool backupExists,
}) async {
  final file = File('${dir.path}/watch-history.json');
  await file.writeAsString(
    backupExists
        ? jsonEncode({'version': 1, 'records': [], 'preferences': []})
        : '{private-secret-invalid-json',
  );
  if (backupExists) await Directory('${file.path}.next').create();
  try {
    final store = await FileHistoryStore.open(file);
    await store.close();
    throw StateError('Expected startup recovery error');
  } on ConfigurationUpgradeFailure catch (error) {
    return error;
  }
}

void main() {
  for (final backupExists in [false, true]) {
    testWidgets(
      'desktop history recovery shows actual original and backup availability=$backupExists',
      (tester) async {
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('startup-history-ui-'),
        ))!;
        addTearDown(() => dir.delete(recursive: true));
        final error = (await tester.runAsync(
          () => _historyFailure(dir, backupExists: backupExists),
        ))!;
        var retries = 0;
        await tester.pumpWidget(
          StartupFailureApp(
            upgrade: error,
            retry: () async {
              retries++;
            },
          ),
        );
        await settle(tester);
        expect(find.textContaining('private-secret'), findsNothing);
        expect(find.textContaining(error.originalPath!), findsWidgets);
        if (backupExists) {
          expect(find.textContaining(error.backupPath!), findsWidgets);
        } else {
          expect(error.backupPath, isNull);
          expect(
            find.textContaining('${error.originalPath!}.pre-source-v2'),
            findsNothing,
          );
        }
        expect(find.text('重试'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await settle(tester);
        expect(retries, 1);
        expect(
          await tester.runAsync(() => File(error.originalPath!).exists()),
          isTrue,
        );
      },
      tags: ['integration'],
    );
  }

  testWidgets(
    'Android runtime history failure shows recovery and retry can initialize',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('android-history-ui-'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      final error = (await tester.runAsync(
        () => _historyFailure(dir, backupExists: true),
      ))!;
      var attempts = 0;
      await tester.pumpWidget(
        AndroidBootstrap(
          resolveEnvironment: () async => PresentationEnvironment.phone,
          createAuth: () async => AuthController.memory(),
          createRuntime: (_) async {
            if (++attempts == 1) throw error;
            return null;
          },
        ),
      );
      await settle(tester);
      expect(find.textContaining(error.originalPath!), findsWidgets);
      expect(find.textContaining(error.backupPath!), findsWidgets);
      expect(find.text('无法初始化应用，请重试。'), findsNothing);
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(attempts, 2);
      expect(find.byType(AndroidConnectPage), findsOneWidget);
      expect(
        await tester.runAsync(() => File(error.originalPath!).exists()),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    tags: ['integration'],
  );
}
