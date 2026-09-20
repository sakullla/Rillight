import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rillight/player/cache/session_byte_cache.dart';

// A real Dart child process, also executable directly on Linux/macOS. Protocol
// output contains only synthetic offsets, sizes and cache counters.
Future<void> main(List<String> arguments) async {
  if (arguments.first == 'lock') {
    final file = File(
      '${arguments[1]}/quota.lock',
    ).openSync(mode: FileMode.append);
    file.lockSync(FileLock.exclusive);
    stdout.writeln('ready');
    await stdin.first;
    file.closeSync();
    return;
  }
  final cache = await SessionByteCache.open(
    root: Directory(arguments[0]),
    diskLimitBytes: int.parse(arguments[1]),
    memoryLimitBytes: 0,
  );
  stdout.writeln(jsonEncode(cache.diagnostics));
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final command = jsonDecode(line) as Map;
    switch (command['op']) {
      case 'put':
        await cache.put(
          resource: 'fixture',
          generation: 1,
          offset: command['offset'] as int,
          bytes: Uint8List.fromList(
            List.filled(command['length'] as int, command['value'] as int),
          ),
        );
        stdout.writeln(jsonEncode(cache.diagnostics));
      case 'read':
        final result = await cache.read(
          resource: 'fixture',
          generation: 1,
          offset: command['offset'] as int,
        );
        stdout.writeln(jsonEncode({'bytes': result?.bytes.toList()}));
      case 'close':
        await cache.close();
        stdout.writeln(jsonEncode(cache.diagnostics));
        exit(0);
    }
  }
  await cache.close();
}
