import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'synthetic_mailbox.dart';

void main() {
  test(
    'partial or locked messages remain available for the next poll',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rillight-mailbox-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/message.json');
      expect(await consumeSyntheticMessage(file), isNull);

      final writer = await file.open(mode: FileMode.write);
      try {
        await writer.writeString('{"seconds":');
        await writer.flush();
        expect(await consumeSyntheticMessage(file), isNull);
        expect(await file.exists(), isTrue);
        await writer.writeString('11}');
        await writer.flush();
        if (Platform.isWindows) {
          expect(await consumeSyntheticMessage(file), isNull);
          expect(await file.exists(), isTrue);
        }
      } finally {
        await writer.close();
      }
      expect(await consumeSyntheticMessage(file), {'seconds': 11});
      expect(await consumeSyntheticMessage(file), isNull);
    },
  );
}
