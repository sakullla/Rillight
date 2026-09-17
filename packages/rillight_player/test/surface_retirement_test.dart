import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/src/surface_retirement.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rillight_retirement_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'detach acknowledgement and raster completion both precede disposal',
    () async {
      final detached = Completer<bool>();
      final raster = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'detach' ? detached.future : null;
      });
      final retired = retireSurface(
        channel: channel,
        handle: 42,
        needsRasterBarrier: true,
        rasterBarrier: () {
          calls.add('raster');
          return raster.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['detach']);
      detached.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['detach', 'raster']);
      raster.complete();
      await retired;
      expect(calls, ['detach', 'raster', 'dispose']);
    },
  );

  for (final stage in ['detach', 'raster']) {
    for (final timeout in [false, true]) {
      test(
        '$stage ${timeout ? 'timeout' : 'failure'} never authorizes cleanup, including late completion',
        () async {
          final calls = <String>[];
          final late = Completer<Object?>();
          Future<Object?> fail() => timeout
              ? late.future
              : Future<Object?>.error(StateError('Injected $stage failure'));
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'detach') {
              return stage == 'detach' ? fail() : true;
            }
            return null;
          });
          final retired = retireSurface(
            channel: channel,
            handle: 42,
            needsRasterBarrier: true,
            timeout: const Duration(milliseconds: 20),
            rasterBarrier: () async {
              calls.add('raster');
              await fail();
            },
          );
          await expectLater(
            retired,
            throwsA(
              timeout
                  ? isA<TimeoutException>()
                  : stage == 'detach'
                  ? isA<PlatformException>()
                  : isA<StateError>(),
            ),
          );
          if (timeout) late.complete(true);
          await Future<void>.delayed(Duration.zero);
          expect(calls, isNot(contains('dispose')));
        },
      );
    }
  }

  test(
    'a failed create with no registered surface needs no raster work',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'detach' ? false : null;
      });
      await retireSurface(
        channel: channel,
        handle: 42,
        needsRasterBarrier: true,
        rasterBarrier: () async => fail('No registered texture to retire'),
      );
      expect(calls, ['detach', 'dispose']);
    },
  );

  test('missing detach acknowledgement cannot authorize disposal', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    await expectLater(
      retireSurface(channel: channel, handle: 42, needsRasterBarrier: true),
      throwsStateError,
    );
    expect(calls, ['detach']);
  });

  test(
    'platforms with a native retirement callback use that callback',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      await retireSurface(
        channel: channel,
        handle: 42,
        needsRasterBarrier: false,
      );
      expect(calls, ['dispose']);
    },
  );

  test(
    'real raster task completes without a mounted widget or scheduled frame',
    () async {
      await waitForRasterRetirement().timeout(const Duration(seconds: 5));
    },
  );
}
