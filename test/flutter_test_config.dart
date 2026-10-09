import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // Pure HTTP suites must not initialize a widget binding: that installs
    // Flutter's HTTP mock. testWidgets initializes it during registration.
    if (BindingBase.debugBindingType() == null) return;
    // flutter_tester has no phone activity. Complete system UI/orientation
    // requests inside the test zone, including restoration during disposal.
    // Native platform replies otherwise race the fake-clock timer checks.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method.startsWith('SystemChrome.') ||
              call.method.startsWith('HapticFeedback.')) {
            return null;
          }
          throw MissingPluginException(
            'Unmocked platform call: ${call.method}',
          );
        });
  });
  await testMain();
}
