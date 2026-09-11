import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_device.dart';

void main() {
  test('authorization header strips non-ASCII so dart:io accepts it', () {
    const device = EmbyDeviceInfo(
      clientName: '灯川 Rillight',
      deviceName: 'windows',
      deviceId: '687f0126-6eb1-450b-bf22-405f3b475aaa',
      version: '0.1.0',
    );

    final header = device.authorizationHeader();
    expect(header, isNot(contains('灯川')));
    expect(header, contains('Client="Rillight"'));
    expect(
      header.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7E),
      isTrue,
    );
  });
}
