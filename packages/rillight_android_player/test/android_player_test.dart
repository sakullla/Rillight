import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_android_player/rillight_android_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('android-player-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'sessions are unique; stale events and stale command completions are rejected',
    () async {
      final source = StreamController<dynamic>.broadcast();
      final replies = <String, Completer<Map<String, dynamic>>>{};
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (call.method == 'open') {
          final reply = Completer<Map<String, dynamic>>();
          replies[args['sessionId'] as String] = reply;
          return reply.future;
        }
        return {'sessionId': args['sessionId']};
      });
      final player = AndroidPlayer(channel: channel, events: source.stream);
      final received = <Map<String, dynamic>>[];
      final subscription = player.events.listen(received.add);
      final first = player.open({'url': 'https://example.test/1'});
      final firstRejected = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final old = player.session;
      final second = player.open({'url': 'https://example.test/2'});
      await Future<void>.delayed(Duration.zero);
      expect(player.session, isNot(old));
      replies[old]!.complete({'sessionId': old});
      replies[player.session]!.complete({'sessionId': player.session});
      await firstRejected;
      await second;
      source.add({
        'owner': player.owner,
        'sessionId': old,
        'kind': 'error',
        'value': 'late',
      });
      source.add({
        'owner': 'another-owner',
        'sessionId': player.session,
        'kind': 'playing',
        'value': true,
      });
      source.add({
        'owner': player.owner,
        'sessionId': player.session,
        'kind': 'playing',
        'value': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      await player.dispose();
      await player.dispose();
      await subscription.cancel();
      await source.close();
    },
  );
  test(
    'wrong session replies fail and missing native replies time out',
    () async {
      final source = StreamController<dynamic>.broadcast();
      final player = AndroidPlayer(channel: channel, events: source.stream);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'sessionId': 'wrong'},
      );
      await expectLater(player.command('pause', {}), throwsStateError);
      messenger.setMockMethodCallHandler(
        channel,
        (call) => Completer<Map>().future,
      );
      await expectLater(
        player.command('seek', {}, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'sessionId': player.session},
      );
      await player.dispose();
      await source.close();
    },
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
