import 'package:rillight/player/player_process_protocol.dart';

class PlayerHostOpenItemCommand {
  const PlayerHostOpenItemCommand({required this.itemId, this.seasonId});
  final String itemId;
  final String? seasonId;
}

/// Commands use the originating process mailbox, never a shared global file.
class PlayerHostOpenItem {
  const PlayerHostOpenItem._();

  static Future<void> write(
    String itemId, {
    required PlayerProcessProtocol protocol,
    String? seasonId,
  }) async {
    final id = itemId.trim();
    if (id.isEmpty) return;
    await protocol.write('open-item', {
      'itemId': id,
      if (seasonId != null && seasonId.trim().isNotEmpty)
        'seasonId': seasonId.trim(),
    });
  }

  static Future<PlayerHostOpenItemCommand?> consume({
    required PlayerProcessProtocol protocol,
    required int expectedPid,
  }) async {
    final message = await protocol.read('open-item');
    if (message == null || message['pid'] != expectedPid) return null;
    final id = message['itemId'];
    final season = message['seasonId'];
    if (id is! String ||
        id.trim().isEmpty ||
        (season != null && season is! String)) {
      return null;
    }
    return PlayerHostOpenItemCommand(
      itemId: id.trim(),
      seasonId: season as String?,
    );
  }
}
