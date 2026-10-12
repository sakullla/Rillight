import 'dart:async';
import 'dart:io';

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
  // macOS exposes its temporary directory through /var -> /private/var.
  // Cache security intentionally rejects linked roots and their ancestors.
  // Use the real system temp directory for fixtures, keeping explicit symlink
  // rejection tests and the production cache policy intact.
  final temporary = Directory(Directory.systemTemp.resolveSymbolicLinksSync());
  IOOverrides.global = _CanonicalTemporaryDirectory(temporary);
  await testMain();
}

final class _CanonicalTemporaryDirectory extends IOOverrides {
  _CanonicalTemporaryDirectory(this.temporary);

  final Directory temporary;

  @override
  Directory getSystemTempDirectory() => temporary;
}
