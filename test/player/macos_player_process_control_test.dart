import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_process_control.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rillight/player_process');
  late MacOSPlayerProcessControl control;
  late List<MethodCall> calls;

  Future<void> exited(int pid) async {
    final completed = Completer<void>();
    binding.channelBuffers.push(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('exited', pid)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUp(() {
    calls = [];
    control = MacOSPlayerProcessControl(
      channel: channel,
      pollInterval: const Duration(milliseconds: 1),
      startupTimeout: const Duration(seconds: 1),
    );
  });

  tearDown(() async {
    for (final pid in control.activePids) {
      await exited(pid);
      await control.release(pid);
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test(
    'macOS launches an app instance and retains the ready/close protocol',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method != 'launch') return null;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final environment = Map<String, String>.from(
          args['environment'] as Map,
        );
        expect(
          environment.keys.any((key) => key.startsWith('FLUTTER')),
          isFalse,
        );
        final launch = File(args['payloadPath'] as String);
        expect(launch.isAbsolute, isTrue);
        final payload = jsonDecode(await launch.readAsString()) as Map;
        await File('${launch.parent.path}/ready.json').writeAsString(
          jsonEncode({'sessionId': payload['processSessionId'], 'pid': 42}),
        );
        return 42;
      });
      final child = await control.spawn(
        executable: '/app/rillight',
        arguments: '{}',
      );
      expect(child, 42);
      expect(control.isAlive(child), isTrue);
      await expectLater(control.release(child), throwsStateError);
      final launch = File(
        (calls.single.arguments as Map)['payloadPath'] as String,
      );
      final closing = control.requestClose(child, const Duration(seconds: 1));
      while (!await File('${launch.parent.path}/close.json').exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await exited(child);
      expect(await closing, isTrue);
      await control.release(child);
      expect(control.activePids, isEmpty);
      expect(calls.last.method, 'release');
      expect(await launch.parent.exists(), isFalse);
    },
  );

  test(
    'exit before launch reply fails startup without killing a reused PID',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'launch') {
          await exited(42);
          return 42;
        }
        return null;
      });
      await expectLater(
        control.spawn(executable: '/app/rillight', arguments: '{}'),
        throwsA(isA<PlayerProcessStartupException>()),
      );
      expect(control.isAlive(42), isFalse);
      expect(calls.where((call) => call.method == 'terminate'), isEmpty);
      await control.release(42);
      expect(control.activePids, isEmpty);
    },
  );

  test(
    'termination waits for app exit and does not repeat after exit',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'launch') return 42;
        return null;
      });
      final child = await control.launch('/app/rillight', '/tmp/launch.json');
      var terminated = false;
      final killing = control.kill(child).then((_) => terminated = true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(terminated, isFalse);
      await exited(child);
      await killing;
      await control.kill(child);
      expect(calls.where((call) => call.method == 'terminate').length, 1);
      await control.release(child);
    },
  );
}
