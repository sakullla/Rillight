import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/aggregation/history/history_models.dart';

class PlayerHostOpenItemCommand {
  const PlayerHostOpenItemCommand({
    required this.itemId,
    this.seasonId,
    this.source,
    this.libraryId,
    this.accessGeneration,
  });
  final SourceReference? source;
  final String? libraryId;
  final int? accessGeneration;
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
    PlayerHostOpenItemCommand? command,
  }) async {
    final id = itemId.trim();
    if (id.isEmpty) return;
    await protocol.write('open-item', {
      'itemId': id,
      if (command?.source != null) 'source': encodeSource(command!.source!),
      if (command?.libraryId != null) 'libraryId': command!.libraryId,
      if (command?.accessGeneration != null)
        'accessGeneration': command!.accessGeneration,
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
    if (message.containsKey('regionGeneration') ||
        (message['source'] is Map &&
            (message['source'] as Map).containsKey('region'))) {
      return null;
    }
    final id = message['itemId'];
    final season = message['seasonId'];
    if (id is! String ||
        id.trim().isEmpty ||
        (season != null && season is! String)) {
      return null;
    }
    try {
      final source = message['source'] == null
          ? null
          : decodeAuthorizedSource(
              Map<String, dynamic>.from(message['source'] as Map),
            );
      if (source != null &&
          (source.itemId != id.trim() ||
              message['libraryId'] is! String ||
              message['accessGeneration'] is! int)) {
        return null;
      }
      if (source == null &&
          (message.containsKey('libraryId') ||
              message.containsKey('accessGeneration'))) {
        return null;
      }
      return PlayerHostOpenItemCommand(
        itemId: id.trim(),
        seasonId: season as String?,
        source: source,
        libraryId: message['libraryId'] as String?,
        accessGeneration: message['accessGeneration'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}
