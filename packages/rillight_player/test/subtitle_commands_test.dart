import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/src/core_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rillight/android_core');
  const events = MethodChannel('rillight/android_core/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'external loading and both slot selections share one command queue',
    () async {
      final calls = <MethodCall>[];
      final loading = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'subtitleUri') return loading.future;
        return <String, dynamic>{};
      });
      final player = AndroidCorePlayer();
      final first = player.command('subtitleUri', {
        'url': 'local.srt',
        'slot': 1,
      });
      final second = player.command('subtitle', {'nativeIndex': 3, 'slot': 0});
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['subtitleUri']);
      loading.complete({'secondarySubtitleNativeIndex': 1000000});
      expect((await first)['secondarySubtitleNativeIndex'], 1000000);
      await second;
      expect(calls.map((c) => c.method), ['subtitleUri', 'subtitle']);
      expect(calls.last.arguments['slot'], 0);
      await player.dispose();
    },
  );

  test(
    'a failed subtitle load releases the queue without changing its target slot',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'subtitleUri') {
          throw PlatformException(code: 'invalid');
        }
        return <String, dynamic>{};
      });
      final player = AndroidCorePlayer();
      final first = player.command('subtitleUri', {
        'url': 'invalid.srt',
        'slot': 1,
      });
      final failed = expectLater(first, throwsA(isA<PlatformException>()));
      final second = player.command('subtitleOff', {'slot': 0});
      await failed;
      await second;
      expect(calls.map((c) => c.method), ['subtitleUri', 'subtitleOff']);
      expect(calls.last.arguments['slot'], 0);
      await player.dispose();
    },
  );

  test(
    'reopening the same media session revokes queued old native indices',
    () async {
      final loading = Completer<Map<String, dynamic>>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'subtitleUri') return loading.future;
        return <String, dynamic>{};
      });
      final player = AndroidCorePlayer();
      final request = CorePlayerOpen(
        url: Uri.parse('http://127.0.0.1/media'),
        session: 'same',
      );
      await player.open(request);
      final first = player.command('subtitleUri', {'url': 'local.srt'});
      final revoked = expectLater(first, throwsStateError);
      final old = player.command('subtitle', {
        'nativeIndex': 1000000,
        'slot': 1,
      });
      final rejected = expectLater(old, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await player.open(request);
      loading.complete({});
      await revoked;
      await rejected;
      // The queued selection is never sent; its native index expired with the
      // replaced session, and the in-flight load result is revoked as well.
      expect(calls.where((c) => c == 'subtitle'), isEmpty);
      await player.dispose();
    },
  );
}
