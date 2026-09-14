import 'dart:convert';
import 'dart:io';

import 'package:rillight/player/playback_models.dart';

export 'package:rillight/player/playback_models.dart'
    show PlaybackSessionSnapshot;

/// 会话快照的持久化入口。
///
/// 播放进程在 Playing 与每次 Progress 成功后写入、Stopped 成功后删除;
/// 宿主在播放进程被终止或意外退出后读取并代发 Stopped。
abstract class PlaybackSessionSnapshotStore {
  Future<void> write(PlaybackSessionSnapshot snapshot);

  /// 不存在或内容无效时返回 null。
  Future<PlaybackSessionSnapshot?> read();

  /// 不存在时为无操作。
  Future<void> delete();
}

/// 内存实现,供播放器与宿主测试共用;记录写入/删除次数便于断言。
class MemoryPlaybackSessionSnapshotStore
    implements PlaybackSessionSnapshotStore {
  MemoryPlaybackSessionSnapshotStore([this.snapshot]);

  PlaybackSessionSnapshot? snapshot;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<void> write(PlaybackSessionSnapshot snapshot) async {
    writeCount += 1;
    this.snapshot = snapshot;
  }

  @override
  Future<PlaybackSessionSnapshot?> read() async => snapshot;

  @override
  Future<void> delete() async {
    deleteCount += 1;
    snapshot = null;
  }
}

/// 文件实现:`%TEMP%/rillight-player-session-<pid>.json`。
///
/// 播放进程以自身 pid 命名([forCurrentProcess]);宿主以其拉起的播放
/// 进程 pid 定位同一文件([forPid])。IO 失败一律吞掉——快照是尽力而为
/// 的兜底,不允许影响播放与关窗。
class FilePlaybackSessionSnapshotStore implements PlaybackSessionSnapshotStore {
  FilePlaybackSessionSnapshotStore(this.file);

  factory FilePlaybackSessionSnapshotStore.forPid(
    int pid, {
    Directory? directory,
  }) {
    return FilePlaybackSessionSnapshotStore(fileFor(pid, directory: directory));
  }

  factory FilePlaybackSessionSnapshotStore.forCurrentProcess() {
    return FilePlaybackSessionSnapshotStore.forPid(pid);
  }

  static const String filePrefix = 'rillight-player-session-';

  /// 缺省目录为 [Directory.systemTemp](Windows 即 `%TEMP%`)。
  static File fileFor(int pid, {Directory? directory}) {
    final root = directory ?? Directory.systemTemp;
    return File('${root.path}${Platform.pathSeparator}$filePrefix$pid.json');
  }

  final File file;

  @override
  Future<void> write(PlaybackSessionSnapshot snapshot) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    } catch (_) {}
  }

  @override
  Future<PlaybackSessionSnapshot?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return PlaybackSessionSnapshot.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> delete() async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
