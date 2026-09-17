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
    'Windows keeps the original process object when its PID is reused',
    () async {
      final original = _FakeWindowsProcess(42);
      var processByPid = original;
      final control = WindowsPlayerProcessControl(
        spawnProcess: ({required executable, required payloadPath}) {
          _readyForWindowsChild(payloadPath, processByPid.pid);
          return processByPid;
        },
      );
      final pid = await control.spawn(executable: 'test', arguments: '{}');
      expect(control.isAlive(pid), isTrue);
      original.alive = false;
      // A PID lookup now resolves to another process. The retained object must
      // still report the original exit and never terminate the replacement.
      final replacement = _FakeWindowsProcess(pid);
      processByPid = replacement;
      expect(control.isAlive(pid), isFalse);
      expect(await control.requestClose(pid, Duration.zero), isTrue);
      await control.kill(pid);
      expect(original.closeCount, 0);
      await control.release(pid);
      await control.release(pid);
      expect(original.closeCount, 1);
      expect(original.terminateCount, 0);
      expect(replacement.alive, isTrue);
      expect(replacement.terminateCount, 0);
      expect(replacement.closeCount, 0);
      expect(control.activePids, isEmpty);
    },
  );

  test(
    'Windows termination waits on the original object and retains it until release',
    () async {
      final child = _FakeWindowsProcess(42)..exitOnTerminate = false;
      final control = WindowsPlayerProcessControl(
        pollInterval: const Duration(milliseconds: 1),
        spawnProcess: ({required executable, required payloadPath}) {
          _readyForWindowsChild(payloadPath, child.pid);
          return child;
        },
      );
      final pid = await control.spawn(executable: 'test', arguments: '{}');
      await expectLater(control.release(pid), throwsStateError);
      expect(control.activePids, [pid]);
      var terminated = false;
      final killing = control.kill(pid).then((_) => terminated = true);
      await Future<void>.delayed(Duration.zero);
      expect(child.terminateCount, 1);
      expect(child.closeCount, 0);
      expect(terminated, isFalse);
      child.alive = false;
      await killing;
      expect(child.closeCount, 0);
      await control.release(pid);
      expect(child.closeCount, 1);
    },
  );

  test(
    'Windows failed startup retains its terminated handle until reconciliation',
    () async {
      final child = _FakeWindowsProcess(42);
      final control = WindowsPlayerProcessControl(
        pollInterval: const Duration(milliseconds: 1),
        startupTimeout: Duration.zero,
        spawnProcess: ({required executable, required payloadPath}) => child,
      );
      await expectLater(
        control.spawn(executable: 'test', arguments: '{}'),
        throwsA(isA<PlayerProcessStartupException>()),
      );
      expect(child.terminateCount, 1);
      expect(child.closeCount, 0);
      expect(child.alive, isFalse);
      expect(control.activePids, [child.pid]);
      await control.release(child.pid);
      expect(child.closeCount, 1);
    },
  );

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
  // STILL_ACTIVE is also a legal exit code; use the process signal to detect exit.
  exit(259);
}

''');
      var executable = _dartExecutable();
      final DesktopPlayerProcessControl control;
      if (Platform.isWindows) {
        executable = '${root.path}/child.exe';
        final compiled = await Process.run(
          '${File(_dartExecutable()).parent.path}/dart.exe',
          ['compile', 'exe', script.path, '-o', executable],
        );
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}\n${compiled.stderr}',
        );
        control = WindowsPlayerProcessControl(
          pollInterval: const Duration(milliseconds: 10),
          startupTimeout: const Duration(seconds: 5),
        );
      } else {
        control = _ActualChildProcess(script.path);
      }
      addTearDown(() async {
        await control.terminateAll();
        for (final pid in control.activePids) {
          await control.release(pid);
        }
        await root.delete(recursive: true);
      });
      final child = await control.spawn(
        executable: executable,
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
      if (Platform.isWindows) {
        // Exercise real TerminateProcess/WaitForSingleObject as well as the
        // graceful protocol path; both must retain ownership until release.
        final secondChild = await control.spawn(
          executable: executable,
          arguments: '{}',
        );
        await control.kill(secondChild);
        expect(control.isAlive(secondChild), isFalse);
        expect(control.activePids, [secondChild]);
        await control.release(secondChild);
        await control.release(secondChild);
        expect(control.activePids, isEmpty);
      }
    },
  );
}

void _readyForWindowsChild(String payloadPath, int pid) {
  final endpoint = PlayerProcessProtocol.fromJson(
    jsonDecode(File(payloadPath).readAsStringSync()),
  );
  File('${endpoint.directory.path}/ready.json').writeAsStringSync(
    jsonEncode({'sessionId': endpoint.sessionId, 'pid': pid}),
  );
}

class _FakeWindowsProcess implements WindowsPlayerProcess {
  _FakeWindowsProcess(this.pid);
  @override
  final int pid;
  bool alive = true;
  bool exitOnTerminate = true;
  int terminateCount = 0;
  int closeCount = 0;
  @override
  bool get isAlive => alive;
  @override
  void terminate() {
    terminateCount++;
    if (exitOnTerminate) alive = false;
  }

  @override
  void close() {
    expect(alive, isFalse);
    closeCount++;
  }
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
