import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_check_in.dart';

void main() {
  test('Playing then Progress is allowed until Stopped', () {
    final machine = PlaybackCheckInMachine();
    expect(machine.canProgress, isFalse);
    machine.start();
    expect(machine.isStarted, isTrue);
    expect(machine.canProgress, isTrue);
    expect(machine.stop(), isTrue);
    expect(machine.isStopped, isTrue);
    expect(machine.canProgress, isFalse);
    expect(machine.stop(), isFalse);
  });

  test(
    'Progress is rejected after Stopped even if start is not called again',
    () {
      final machine = PlaybackCheckInMachine();
      machine.start();
      machine.stop();
      expect(machine.canProgress, isFalse);
    },
  );
}
