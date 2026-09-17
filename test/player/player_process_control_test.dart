import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/spawn_player_process.dart';

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue);
}

void main() {
  test('platform factory never selects Win32 control for macOS or Linux', () {
    expect(
      createPlayerProcessControl(operatingSystem: 'windows'),
      isA<WindowsPlayerProcessControl>(),
    );
    expect(
      createPlayerProcessControl(operatingSystem: 'macos'),
      isA<PosixPlayerProcessControl>(),
    );
    expect(
      createPlayerProcessControl(operatingSystem: 'linux'),
      isA<PosixPlayerProcessControl>(),
    );
    expect(
      () => createPlayerProcessControl(operatingSystem: 'android'),
      throwsUnsupportedError,
    );
  });

  test('spawn requires matching ready identity and pid', () async {
    final control = _ControlledProcess();
    addTearDown(control.clean);
    final spawning = control.spawn(executable: 'test', arguments: '{}');
    await _until(() => control.endpoint != null);
    var completed = false;
    spawning.then((_) => completed = true);
    await control.ready(processId: 999);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(completed, isFalse);
    await control.ready();
    expect(await spawning, 42);
  });

  test(
    'startup timeout terminates the child and preserves its snapshot for reconciliation',
    () async {
      final control = _ControlledProcess(
        startupTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(control.clean);
      await expectLater(
        control.spawn(executable: 'test', arguments: '{}'),
        throwsA(
          isA<PlayerProcessStartupException>().having(
            (e) => e.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(control.alive, isFalse);
      expect(control.killed, 1);
      expect(control.activePids, [42]);
    },
  );

  test(
    'cancelPendingSpawns interrupts readiness wait and kills only its child',
    () async {
      final control = _ControlledProcess();
      addTearDown(control.clean);
      final spawning = control.spawn(executable: 'test', arguments: '{}');
      final failure = expectLater(
        spawning,
        throwsA(isA<PlayerProcessStartupException>()),
      );
      await _until(() => control.endpoint != null);
      control.cancelPendingSpawns();
      await failure;
      expect(control.alive, isFalse);
      expect(control.killed, 1);
    },
  );

  test(
    'an actual child process acknowledges ready, routes a command, and exits on close',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'rillight-process-test-',
      );
      final script = File('${root.path}/child.dart');
      final protocolUri = File(
        'lib/player/player_process_protocol.dart',
      ).absolute.uri.toString();
      await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
import ${jsonEncode(protocolUri)};
Future<void> main(List<String> args) async {
  final launch = File(args.last);
  final endpoint = PlayerProcessProtocol.fromJson(jsonDecode(await launch.readAsString()));
  await launch.delete();
  await endpoint.write('ready');
  await endpoint.write('open-item', {'itemId': 'series-test'});
  while (await endpoint.read('close') == null) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
''');
      final control = _ActualChildProcess(script.path);
      addTearDown(() async {
        await control.terminateAll();
        for (final pid in control.activePids) {
          await control.release(pid);
        }
        await root.delete(recursive: true);
      });
      final child = await control.spawn(
        executable: _dartExecutable(),
        arguments: '{}',
      );
      expect(control.isAlive(child), isTrue);
      var command = await control.consumeOpenItem(child);
      for (var i = 0; i < 50 && command == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        command = await control.consumeOpenItem(child);
      }
      expect(command?.itemId, 'series-test');
      expect(
        await control.requestClose(child, const Duration(seconds: 2)),
        isTrue,
      );
      expect(control.isAlive(child), isFalse);
      await control.release(child);
    },
  );
}

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  final name = Platform.isWindows ? 'dartvm.exe' : 'dartvm';
  for (var i = 0; i < 7; i++) {
    for (final path in [
      '${directory.path}/$name',
      '${directory.path}/dart-sdk/bin/$name',
    ]) {
      if (File(path).existsSync()) return path;
    }
    directory = directory.parent;
  }
  throw StateError('Dart SDK executable not found');
}

class _ControlledProcess extends DesktopPlayerProcessControl {
  _ControlledProcess({super.startupTimeout = const Duration(seconds: 2)})
    : super(pollInterval: const Duration(milliseconds: 1));
  PlayerProcessProtocol? endpoint;
  bool alive = false;
  int killed = 0;
  @override
  Future<int> launch(String executable, String payloadPath) async {
    endpoint = PlayerProcessProtocol.fromJson(
      jsonDecode(await File(payloadPath).readAsString()),
    );
    alive = true;
    return 42;
  }

  Future<void> ready({int processId = 42}) =>
      File('${endpoint!.directory.path}/ready.json').writeAsString(
        jsonEncode({'sessionId': endpoint!.sessionId, 'pid': processId}),
      );
  @override
  bool isAlive(int pid) => alive;
  @override
  Future<void> terminate(int pid) async {
    alive = false;
    killed++;
  }

  Future<void> clean() async {
    await terminateAll();
    for (final pid in activePids) {
      await release(pid);
    }
  }
}

class _ActualChildProcess extends DesktopPlayerProcessControl {
  _ActualChildProcess(this.script)
    : super(
        pollInterval: const Duration(milliseconds: 10),
        startupTimeout: const Duration(seconds: 5),
      );
  final String script;
  final children = <int, Process>{};
  @override
  Future<int> launch(String executable, String payloadPath) async {
    final child = await Process.start(
      executable,
      [script, 'player', payloadPath],
      environment: playerProcessEnvironment(),
      includeParentEnvironment: false,
    );
    children[child.pid] = child;
    unawaited(child.stdout.drain<void>());
    unawaited(child.stderr.drain<void>());
    unawaited(child.exitCode.then((_) => children.remove(child.pid)));
    return child.pid;
  }

  @override
  bool isAlive(int pid) => children.containsKey(pid);
  @override
  Future<void> terminate(int pid) async {
    final child = children[pid];
    if (child == null) return;
    child.kill();
    await child.exitCode;
    children.remove(pid);
  }
}
