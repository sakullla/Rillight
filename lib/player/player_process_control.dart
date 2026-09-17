import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/spawn_player_process.dart';

abstract class PlayerProcessControl {
  Future<int> spawn({required String executable, required String arguments});
  bool isAlive(int pid);
  Future<bool> requestClose(int pid, Duration wait);
  Future<void> kill(int pid);
  Future<PlayerHostOpenItemCommand?> consumeOpenItem(int pid);
  Future<void> heartbeat(int pid);
  Future<void> release(int pid);
  void cancelPendingSpawns();
  Future<void> terminateAll();
  Iterable<int> get activePids;
  PlaybackSessionSnapshotStore snapshotStore(int pid);
}

class PlayerProcessStartupException implements Exception {
  PlayerProcessStartupException(this.pid, this.cause);
  final int pid;
  final Object cause;
  @override
  String toString() => 'Player startup failed: $cause';
}

PlayerProcessControl createPlayerProcessControl({String? operatingSystem}) {
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'windows' => WindowsPlayerProcessControl(),
    'macos' || 'linux' => PosixPlayerProcessControl(),
    final platform => throw UnsupportedError(
      'Unsupported player platform: $platform',
    ),
  };
}

/// A spawn becomes usable only after the actual child entry point acknowledges
/// its window and close handler. Failed or superseded launches are terminated.
abstract class DesktopPlayerProcessControl implements PlayerProcessControl {
  DesktopPlayerProcessControl({
    this.pollInterval = const Duration(milliseconds: 100),
    this.startupTimeout = const Duration(seconds: 20),
  });

  final Duration pollInterval;
  final Duration startupTimeout;
  final Map<int, PlayerProcessProtocol> _endpoints = {};
  int _generation = 0;

  Future<int> launch(String executable, String payloadPath);
  Future<void> terminate(int pid);

  @override
  Future<int> spawn({
    required String executable,
    required String arguments,
  }) async {
    final generation = _generation;
    final endpoint = await PlayerProcessProtocol.create();
    var child = 0;
    try {
      await endpoint.writeLaunch(
        Map<String, dynamic>.from(jsonDecode(arguments) as Map),
      );
      await endpoint.heartbeat();
      if (generation != _generation) {
        throw StateError('Player launch cancelled');
      }
      child = await launch(executable, endpoint.launchFile.path);
      _endpoints[child] = endpoint;
      final deadline = DateTime.now().add(startupTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (generation != _generation) {
          throw StateError('Player launch cancelled');
        }
        if (!isAlive(child)) {
          throw StateError('Player process exited before ready');
        }
        final failure = await endpoint.read('failed');
        if (failure != null) {
          throw StateError('Player window initialization failed');
        }
        final ready = await endpoint.read('ready');
        if (ready?['pid'] == child && generation == _generation) return child;
        await endpoint.heartbeat();
        await Future<void>.delayed(pollInterval);
      }
      throw TimeoutException(
        'Player window did not become ready',
        startupTimeout,
      );
    } catch (error) {
      if (child != 0) {
        await terminate(child);
        // Preserve this endpoint until the host reconciles a possible snapshot.
        throw PlayerProcessStartupException(child, error);
      }
      await endpoint.dispose();
      rethrow;
    }
  }

  @override
  Iterable<int> get activePids => _endpoints.keys.toList();

  @override
  PlaybackSessionSnapshotStore snapshotStore(int pid) {
    final endpoint = _endpoints[pid];
    if (endpoint == null) throw StateError('Unknown player process');
    return FilePlaybackSessionSnapshotStore(
      File('${endpoint.directory.path}/snapshot.json'),
    );
  }

  @override
  void cancelPendingSpawns() => _generation++;

  @override
  Future<bool> requestClose(int pid, Duration wait) async {
    if (!isAlive(pid)) return true;
    final endpoint = _endpoints[pid];
    if (endpoint == null) return false;
    await endpoint.write('close');
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      if (!isAlive(pid)) return true;
      await Future<void>.delayed(pollInterval);
    }
    return !isAlive(pid);
  }

  @override
  Future<void> kill(int pid) => terminate(pid);

  @override
  Future<void> heartbeat(int pid) async => _endpoints[pid]?.heartbeat();

  @override
  Future<PlayerHostOpenItemCommand?> consumeOpenItem(int pid) async {
    final protocol = _endpoints[pid];
    if (protocol == null) return null;
    return PlayerHostOpenItem.consume(protocol: protocol, expectedPid: pid);
  }

  @override
  Future<void> release(int pid) async {
    final endpoint = _endpoints[pid];
    if (endpoint == null) return;
    final keepSnapshot = await snapshotStore(pid).read() != null;
    _endpoints.remove(pid);
    await endpoint.dispose(preserveSnapshot: keepSnapshot);
  }

  @override
  Future<void> terminateAll() async {
    cancelPendingSpawns();
    for (final pid in _endpoints.keys.toList()) {
      await kill(pid);
    }
  }
}

class WindowsPlayerProcessControl extends DesktopPlayerProcessControl {
  WindowsPlayerProcessControl({
    super.pollInterval,
    super.startupTimeout,
    WindowsPlayerProcess Function({
      required String executable,
      required String payloadPath,
    })?
    spawnProcess,
  }) : _spawnProcess = spawnProcess ?? spawnStandalonePlayer;

  final WindowsPlayerProcess Function({
    required String executable,
    required String payloadPath,
  })
  _spawnProcess;
  final Map<int, WindowsPlayerProcess> _children = {};

  @override
  Future<int> launch(String executable, String payloadPath) async {
    final child = _spawnProcess(
      executable: executable,
      payloadPath: payloadPath,
    );
    _children[child.pid] = child;
    return child.pid;
  }

  @override
  bool isAlive(int pid) => _children[pid]?.isAlive ?? false;

  @override
  Future<void> terminate(int pid) async {
    final child = _children[pid];
    if (child == null || !child.isAlive) return;
    child.terminate();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (child.isAlive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
    if (child.isAlive) throw StateError('Player process did not terminate');
  }

  @override
  Future<void> release(int pid) async {
    final child = _children[pid];
    if (child != null && child.isAlive) {
      throw StateError('Cannot release a running player process');
    }
    // Keep the original handle until snapshot/mailbox cleanup completes.
    await super.release(pid);
    child?.close();
    if (identical(_children[pid], child)) _children.remove(pid);
  }
}

class PosixPlayerProcessControl extends DesktopPlayerProcessControl {
  PosixPlayerProcessControl({super.pollInterval, super.startupTimeout});
  final Map<int, Process> _children = {};

  @override
  Future<int> launch(String executable, String payloadPath) async {
    final process = await Process.start(
      executable,
      ['player', payloadPath],
      environment: playerProcessEnvironment(),
      includeParentEnvironment: false,
    );
    _children[process.pid] = process;
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((_) => _children.remove(process.pid)));
    return process.pid;
  }

  @override
  bool isAlive(int pid) => _children.containsKey(pid);

  @override
  Future<void> terminate(int pid) async {
    final process = _children[pid];
    if (process == null) return;
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 2));
    _children.remove(pid);
  }
}
