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
    diskTimeout: Duration(
      milliseconds: arguments.length > 2 ? int.parse(arguments[2]) : 750,
    ),
  );
  CacheRangeLease? protection;
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
      case 'seed-files':
        // Synthetic historical/capacity fixtures are created only in the test
        // process's isolated cache root. This does not exercise a production
        // bypass API, and allows testing >8192 entries without O(n^2) writes.
        final directory = Directory(
          arguments[0],
        ).listSync().whereType<Directory>().single;
        final target = command['entries'] as int;
        final kind = command['kind'] as String;
        final template = kind == 'block'
            ? directory.listSync().whereType<File>().firstWhere(
                (file) => file.path.endsWith('.block'),
              )
            : null;
        final suffix = template?.uri.pathSegments.last.substring(32);
        final data = template?.readAsBytesSync() ?? <int>[0];
        var count = directory.listSync(followLinks: false).length;
        for (var i = 0; count < target; i++) {
          final nonce = i.toRadixString(16).padLeft(32, '0');
          final name = kind == 'block' ? '$nonce$suffix' : '$nonce.partial';
          final file = File('${directory.path}/$name');
          if (file.existsSync()) continue;
          file.writeAsBytesSync(data);
          count++;
        }
        stdout.writeln(jsonEncode({'entries': count}));
      case 'protect':
        protection = await cache.protectRange(
          resource: 'fixture',
          generation: 1,
          offset: command['offset'] as int,
          length: command['length'] as int,
        );
        stdout.writeln(
          jsonEncode({'protected': protection != null, ...cache.diagnostics}),
        );
      case 'protected-read':
        final result = await protection?.read(command['offset'] as int);
        stdout.writeln(jsonEncode({'bytes': result?.bytes.toList()}));
      case 'unprotect':
        await protection?.close();
        protection = null;
        stdout.writeln(jsonEncode(cache.diagnostics));
      case 'close':
        await cache.close();
        stdout.writeln(jsonEncode(cache.diagnostics));
        exit(0);
    }
  }
  await cache.close();
}
