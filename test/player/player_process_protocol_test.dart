import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_process_protocol.dart';

void main() {
  late PlayerProcessProtocol first;
  late PlayerProcessProtocol second;
  setUp(() async {
    first = await PlayerProcessProtocol.create();
    second = await PlayerProcessProtocol.create();
  });
  tearDown(() async {
    await first.dispose();
    await second.dispose();
  });

  test(
    'launch credentials and commands are isolated between processes',
    () async {
      await first.writeLaunch({'accessToken': 'first'});
      await second.writeLaunch({'accessToken': 'second'});
      expect(first.sessionId, isNot(second.sessionId));
      expect(first.directory.path, isNot(second.directory.path));
      expect(
        jsonDecode(await first.launchFile.readAsString())['accessToken'],
        'first',
      );
      await first.write('close');
      expect(await second.read('close'), isNull);
      expect(await first.read('close'), isNotNull);
      expect(await first.read('close'), isNull);
    },
  );

  test('a message from another session is rejected', () async {
    await File(
      '${first.directory.path}/ready.json',
    ).writeAsString(jsonEncode({'sessionId': second.sessionId, 'pid': pid}));
    expect(await first.read('ready'), isNull);
  });

  test(
    'a child can use its endpoint but cannot delete the host directory',
    () async {
      final child = PlayerProcessProtocol.fromJson(first.fields);
      await child.write('ready');
      expect((await first.read('ready'))?['pid'], pid);
      await expectLater(child.dispose(), throwsStateError);
      expect(await first.directory.exists(), isTrue);
    },
  );

  test('heartbeat expiry detects a vanished host', () async {
    await first.heartbeat();
    expect(await first.parentExpired(), isFalse);
    await first.write('heartbeat', {
      'at': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
    });
    expect(await first.parentExpired(), isTrue);
  });

  test(
    'failed-report snapshot survives mailbox cleanup without launch credentials',
    () async {
      await first.writeLaunch({'accessToken': 'secret'});
      final snapshot = File('${first.directory.path}/snapshot.json');
      await snapshot.writeAsString('{}');
      await first.dispose(preserveSnapshot: true);
      expect(await snapshot.exists(), isTrue);
      expect(await first.launchFile.exists(), isFalse);
    },
  );

  test(
    'invalid session IDs and malformed messages do not become commands',
    () async {
      expect(
        () => PlayerProcessProtocol(
          directory: first.directory,
          sessionId: '../other',
        ),
        throwsFormatException,
      );
      await File('${first.directory.path}/close.json').writeAsString('{');
      expect(await first.read('close'), isNull);
    },
  );
}
