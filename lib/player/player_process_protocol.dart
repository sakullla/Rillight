import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One private mailbox directory per launched player. No process shares a
/// launch or command file, and every message carries the launch identity.
class PlayerProcessProtocol {
  PlayerProcessProtocol({required this.directory, required this.sessionId}) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(sessionId)) {
      throw const FormatException('Invalid player process session');
    }
  }

  bool _ownsDirectory = false;
  DateTime _lastHeartbeat = DateTime.now();
  final Directory directory;
  final String sessionId;
  File get launchFile => File('${directory.path}/launch.json');

  static Future<PlayerProcessProtocol> create({Directory? parent}) async {
    final directory = await (parent ?? Directory.systemTemp).createTemp(
      'rillight-player-',
    );
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return PlayerProcessProtocol(directory: directory, sessionId: id)
      .._ownsDirectory = true;
  }

  factory PlayerProcessProtocol.fromJson(Map<String, dynamic> json) {
    final path = json['processDirectory'];
    final id = json['processSessionId'];
    if (path is! String || path.isEmpty || id is! String) {
      throw const FormatException('Missing player process endpoint');
    }
    return PlayerProcessProtocol(directory: Directory(path), sessionId: id);
  }

  Map<String, dynamic> get fields => {
    'processDirectory': directory.path,
    'processSessionId': sessionId,
  };

  Future<void> writeLaunch(Map<String, dynamic> payload) async {
    await launchFile.writeAsString(
      jsonEncode({...payload, ...fields}),
      flush: true,
    );
  }

  File _file(String kind) {
    if (!const {
      'ready',
      'failed',
      'close',
      'open-item',
      'heartbeat',
    }.contains(kind)) {
      throw ArgumentError.value(kind, 'kind');
    }
    return File('${directory.path}/$kind.json');
  }

  Future<void> write(
    String kind, [
    Map<String, dynamic> data = const {},
  ]) async {
    final payload = jsonEncode({...data, 'sessionId': sessionId, 'pid': pid});
    await _replace(_file(kind), payload);
  }

  /// Windows 上 mailbox 文件常被子进程或杀毒软件短时间锁住,delete+rename
  /// 会抛 errno 32,表现为第一次点播放失败、再点一次才行。
  Future<void> _replace(File target, String payload) async {
    FileSystemException? last;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        await _replaceOnce(target, payload);
        return;
      } on FileSystemException catch (error) {
        last = error;
        await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
      }
    }
    throw last!;
  }

  Future<void> _replaceOnce(File target, String payload) async {
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    try {
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } on FileSystemException {
      await target.writeAsString(payload, flush: true);
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // 下次写入会覆盖残留的 tmp。
      }
    }
  }

  Future<Map<String, dynamic>?> read(String kind, {bool consume = true}) async {
    final target = _file(kind);
    try {
      final decoded = jsonDecode(await target.readAsString());
      if (consume) {
        try {
          await target.delete();
        } on FileSystemException {
          // 已读入内存;Windows 上文件可能仍被对方打开。
        }
      }
      if (decoded is! Map || decoded['sessionId'] != sessionId) return null;
      return Map<String, dynamic>.from(decoded);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> heartbeat() =>
      write('heartbeat', {'at': DateTime.now().millisecondsSinceEpoch});

  Future<bool> parentExpired({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final message = await read('heartbeat', consume: false);
    final stamp = message?['at'];
    if (stamp is int) {
      _lastHeartbeat = DateTime.fromMillisecondsSinceEpoch(stamp);
    }
    return DateTime.now().difference(_lastHeartbeat) > timeout;
  }

  Future<void> dispose({bool preserveSnapshot = false}) async {
    // The directory comes only from create() in the owning host. Child
    // endpoints never delete the directory supplied in a launch payload.
    if (!_ownsDirectory) {
      throw StateError('Only the launching host owns this mailbox');
    }
    if (preserveSnapshot &&
        await File('${directory.path}/snapshot.json').exists()) {
      for (final name in [
        'launch',
        'ready',
        'failed',
        'close',
        'open-item',
        'heartbeat',
      ]) {
        for (final suffix in ['.json', '.json.tmp']) {
          final file = File('${directory.path}/$name$suffix');
          if (await file.exists()) await file.delete();
        }
      }
      return;
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
