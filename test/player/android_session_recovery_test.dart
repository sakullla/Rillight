import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/playback_session_snapshot.dart';

void main() {
  late HttpServer server;
  late EmbyClient client;
  late MemoryPlaybackSessionSnapshotStore store;
  late List<Map<String, dynamic>> reports;
  bool reject = false;
  Completer<void>? userHold;
  late Completer<void> userRequested;
  setUp(() async {
    reports = [];
    reject = false;
    userHold = null;
    userRequested = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.contains('/Stopped')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        reports.add(Map<String, dynamic>.from(body));
        request.response.statusCode = reject ? 503 : 204;
      } else {
        if (!userRequested.isCompleted) userRequested.complete();
        await userHold?.future;
        request.response.write(
          jsonEncode({'Id': 'user-a', 'Name': 'synthetic'}),
        );
      }
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    client =
        EmbyClient(
          device: const EmbyDeviceInfo(
            clientName: 'test',
            deviceName: 'test',
            deviceId: 'recovery',
            version: '1',
          ),
        )..attachSession(
          baseUrl: base,
          userId: 'user-a',
          accessToken: 'synthetic-a',
        );
    store = MemoryPlaybackSessionSnapshotStore(
      PlaybackSessionSnapshot(
        itemId: 'movie',
        mediaSourceId: 'source',
        playSessionId: 'interrupted',
        positionTicks: 420000000,
        baseUrl: base.toString(),
        userId: 'user-a',
        timestamp: DateTime.now(),
      ),
    );
  });
  tearDown(() async {
    if (userHold != null && !userHold!.isCompleted) userHold!.complete();
    await server.close(force: true);
  });
  test(
    'interrupted session verifies user then sends one paused stopped report',
    () async {
      expect(await recoverAndroidSession(client, store), isTrue);
      expect(reports.single['PositionTicks'], 420000000);
      expect(reports.single['IsPaused'], isTrue);
      expect(store.snapshot, isNull);
      expect(await recoverAndroidSession(client, store), isFalse);
      expect(reports, hasLength(1));
    },
  );
  test('failed compensation retains snapshot for explicit retry', () async {
    reject = true;
    await expectLater(recoverAndroidSession(client, store), throwsA(anything));
    expect(store.snapshot, isNotNull);
    reject = false;
    expect(await recoverAndroidSession(client, store), isTrue);
    expect(store.snapshot, isNull);
  });
  test('different user discards old snapshot without network report', () async {
    client.attachSession(
      baseUrl: client.baseUrl!,
      userId: 'user-b',
      accessToken: 'synthetic-b',
    );
    expect(await recoverAndroidSession(client, store), isFalse);
    expect(reports, isEmpty);
    expect(store.snapshot, isNull);
  });
  test(
    'identity change during verification cannot forward old progress',
    () async {
      userHold = Completer<void>();
      final recovering = recoverAndroidSession(client, store);
      await userRequested.future;
      client.attachSession(
        baseUrl: client.baseUrl!,
        userId: 'user-b',
        accessToken: 'synthetic-b',
      );
      userHold!.complete();
      expect(await recovering, isFalse);
      expect(reports, isEmpty);
    },
  );
}
