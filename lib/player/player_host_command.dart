import 'dart:convert';
import 'dart:io';

/// 播放进程请主窗口打开的条目详情。
class PlayerHostOpenItemCommand {
  const PlayerHostOpenItemCommand({required this.itemId, this.seasonId});

  final String itemId;
  final String? seasonId;
}

/// 播放进程写、主进程读:请主窗口打开条目详情。
///
/// 独立播放进程不是 `desktop_multi_window` 子窗,WindowMethodChannel
/// 到不了宿主;与启动载荷、会话快照一样走 `%TEMP%` 文件。
class PlayerHostOpenItem {
  const PlayerHostOpenItem._();

  static const fileName = 'rillight-player-open-item.json';
  static const maxAge = Duration(seconds: 30);

  static File file({Directory? directory}) {
    final root = directory ?? Directory.systemTemp;
    return File('${root.path}${Platform.pathSeparator}$fileName');
  }

  static Future<void> write(
    String itemId, {
    String? seasonId,
    Directory? directory,
  }) async {
    final id = itemId.trim();
    if (id.isEmpty) {
      return;
    }
    final season = seasonId?.trim() ?? '';
    final target = file(directory: directory);
    await target.writeAsString(
      jsonEncode({
        'itemId': id,
        if (season.isNotEmpty) 'seasonId': season,
        'pid': pid,
      }),
      flush: true,
    );
  }

  /// 读取并删除请求。过期或损坏的文件丢弃,返回 null。
  static Future<PlayerHostOpenItemCommand?> consume({
    Directory? directory,
    Duration maxAge = maxAge,
  }) async {
    final target = file(directory: directory);
    try {
      if (!await target.exists()) {
        return null;
      }
      final stat = await target.stat();
      final raw = await target.readAsString();
      await target.delete();
      if (DateTime.now().difference(stat.modified) > maxAge) {
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final id = decoded['itemId']?.toString().trim() ?? '';
      if (id.isEmpty) {
        return null;
      }
      final season = decoded['seasonId']?.toString().trim() ?? '';
      return PlayerHostOpenItemCommand(
        itemId: id,
        seasonId: season.isEmpty ? null : season,
      );
    } catch (_) {
      return null;
    }
  }
}
