import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';

PlaybackSessionSnapshot _snapshot({int positionTicks = 12345678}) {
  return PlaybackSessionSnapshot(
    itemId: 'movie-up',
    mediaSourceId: 'source-up',
    playSessionId: 'play-1',
    playMethod: PlayMethod.transcode,
    positionTicks: positionTicks,
    baseUrl: 'https://emby.example.com/',
    userId: 'user-alice',
    timestamp: DateTime.utc(2026, 9, 14, 12, 30),
  );
}

void main() {
  group('PlaybackSessionSnapshot', () {
    test('json round-trip keeps every field', () {
      final original = _snapshot();
      final decoded = PlaybackSessionSnapshot.fromJson(original.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.itemId, original.itemId);
      expect(decoded.mediaSourceId, original.mediaSourceId);
      expect(decoded.playSessionId, original.playSessionId);
      expect(decoded.playMethod, PlayMethod.transcode);
      expect(decoded.positionTicks, original.positionTicks);
      expect(decoded.baseUrl, original.baseUrl);
      expect(decoded.userId, original.userId);
      expect(decoded.timestamp, original.timestamp);
    });

    test('missing session identity makes the snapshot invalid', () {
      final json = _snapshot().toJson()..remove('playSessionId');
      expect(PlaybackSessionSnapshot.fromJson(json), isNull);
      expect(PlaybackSessionSnapshot.fromJson(const {}), isNull);
    });

    test('unknown play method falls back to DirectStream', () {
      final json = _snapshot().toJson()..['playMethod'] = 'Bogus';
      expect(
        PlaybackSessionSnapshot.fromJson(json)!.playMethod,
        PlayMethod.directStream,
      );
    });
  });

  group('PlaybackReport.fromSnapshot', () {
    test('produces a Stopped payload consistent with toJson', () {
      final report = PlaybackReport.fromSnapshot(_snapshot());
      final json = report.toJson();
      expect(json['ItemId'], 'movie-up');
      expect(json['MediaSourceId'], 'source-up');
      expect(json['PlaySessionId'], 'play-1');
      expect(json['PlayMethod'], 'Transcode');
      expect(json['PositionTicks'], 12345678);
      expect(json['IsPaused'], isTrue);
      expect(json.containsKey('EventName'), isFalse);
    });
  });

  group('MemoryPlaybackSessionSnapshotStore', () {
    test('write, read and delete round-trip', () async {
      final store = MemoryPlaybackSessionSnapshotStore();
      expect(await store.read(), isNull);
      await store.write(_snapshot());
      expect((await store.read())!.itemId, 'movie-up');
      expect(store.writeCount, 1);
      await store.delete();
      expect(await store.read(), isNull);
      expect(store.deleteCount, 1);
    });
  });

  group('FilePlaybackSessionSnapshotStore', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('rillight-snapshot-');
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('names the file by pid inside the temp directory', () {
      final file = FilePlaybackSessionSnapshotStore.fileFor(
        4242,
        directory: directory,
      );
      expect(file.path, startsWith(directory.path));
      expect(file.uri.pathSegments.last, 'rillight-player-session-4242.json');

      final current = FilePlaybackSessionSnapshotStore.forCurrentProcess();
      expect(current.file.path, startsWith(Directory.systemTemp.path));
      expect(
        current.file.uri.pathSegments.last,
        'rillight-player-session-$pid.json',
      );
    });

    test(
      'write creates the file, read restores it, delete removes it',
      () async {
        final store = FilePlaybackSessionSnapshotStore.forPid(
          4242,
          directory: directory,
        );
        expect(await store.read(), isNull);

        await store.write(_snapshot(positionTicks: 99));
        expect(await store.file.exists(), isTrue);
        final restored = await store.read();
        expect(restored, isNotNull);
        expect(restored!.itemId, 'movie-up');
        expect(restored.positionTicks, 99);
        expect(restored.baseUrl, 'https://emby.example.com/');
        expect(restored.userId, 'user-alice');

        // 覆盖写:最新位置生效。
        await store.write(_snapshot(positionTicks: 100));
        expect((await store.read())!.positionTicks, 100);

        await store.delete();
        expect(await store.file.exists(), isFalse);
        expect(await store.read(), isNull);

        // 重复删除为无操作。
        await store.delete();
        expect(await store.file.exists(), isFalse);
      },
    );

    test('corrupt content reads as null instead of throwing', () async {
      final store = FilePlaybackSessionSnapshotStore.forPid(
        7,
        directory: directory,
      );
      await store.file.writeAsString('not json');
      expect(await store.read(), isNull);
      await store.file.writeAsString('[1, 2, 3]');
      expect(await store.read(), isNull);
    });
  });
}
