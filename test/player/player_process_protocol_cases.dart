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

      // 另一会话的消息被拒绝。
      await File(
        '${first.directory.path}/ready.json',
      ).writeAsString(jsonEncode({'sessionId': second.sessionId, 'pid': pid}));
      expect(await first.read('ready'), isNull);
    },
  );

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

  test('heartbeat write succeeds while the previous file is open', () async {
    await first.heartbeat();
    final file = File('${first.directory.path}/heartbeat.json');
    RandomAccessFile? handle = await file.open(mode: FileMode.read);
    try {
      final write = first.heartbeat();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await handle.close();
      handle = null;
      await write;
    } finally {
      await handle?.close();
    }
    final decoded = jsonDecode(await file.readAsString()) as Map;
    expect(decoded['sessionId'], first.sessionId);
    expect(decoded['at'], isA<int>());
  });

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
