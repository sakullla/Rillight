import 'package:rillight/media_server/serialization.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_process_protocol.dart';

/// Fresh, launch-scoped metadata, fetched while the desktop child boots.
/// PlaybackInfo still runs in the child after applying its current settings.
class PlayerStartupData {
  const PlayerStartupData(
    this.item,
    this.user, {
    this.versions,
    this.fetchedAt,
  });
  final MediaItem item;
  final MediaUser? user;

  /// Negotiated media versions the parent already fetched for this launch.
  /// Only consumed once, while still fresh; later reopens negotiate again.
  final List<PlaybackMediaSource>? versions;
  final DateTime? fetchedAt;

  /// Validates and decodes one startup message. Returns null for scope
  /// mismatch or malformed data; a typed failure throws. Shared by the
  /// mailbox receiver and the embedded launch handoff.
  static PlayerStartupData? decode(
    Map<String, dynamic> message, {
    required String itemId,
    required String userId,
  }) {
    if (message['itemId'] != itemId || message['userId'] != userId) {
      return null;
    }
    final failure = message['failure'];
    if (failure is String) {
      throw MediaServerException(
        MediaServerFailureKind.values.firstWhere(
          (kind) => kind.name == failure,
          orElse: () => MediaServerFailureKind.unknown,
        ),
      );
    }
    final rawItem = message['item'];
    if (rawItem is! Map) return null;
    try {
      final item = decodeMediaItem(Map<String, dynamic>.from(rawItem));
      if (item.id != itemId) return null;
      final rawUser = message['user'];
      final user = rawUser is Map
          ? decodeMediaUser(Map<String, dynamic>.from(rawUser))
          : null;
      if (user != null && user.id != userId) return null;
      List<PlaybackMediaSource>? versions;
      final rawVersions = message['versions'];
      if (rawVersions is List && rawVersions.isNotEmpty) {
        versions = [
          for (final value in rawVersions)
            decodePlaybackMediaSource(Map<String, dynamic>.from(value as Map)),
        ];
      }
      return PlayerStartupData(
        item,
        user,
        versions: versions,
        fetchedAt: DateTime.tryParse(message['fetchedAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<PlayerStartupData?> receive(
    PlayerProcessProtocol protocol, {
    required String itemId,
    required String userId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final message = await protocol.read('startup');
      if (message != null) {
        return decode(
          Map<String, dynamic>.from(message),
          itemId: itemId,
          userId: userId,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // A missing mailbox is a transport failure, not invalid media. Fall back
    // to the normal child requests; never use an earlier launch's metadata.
    return null;
  }
}

class PlayerStartupPreparation {
  PlayerStartupPreparation(MediaServerClient client, String itemId) {
    final userId = client.userId;
    final base = client.baseUrl;
    final token = client.accessToken;
    payload = () async {
      try {
        final results = await Future.wait<Map<String, dynamic>?>([
          client.getItem(itemId, cancelToken: _cancel).then(encodeMediaItem),
          client
              .getUser(cancelToken: _cancel)
              .then<Map<String, dynamic>?>(encodeMediaUser)
              .catchError((Object _) => null),
        ], eagerError: true);
        if (_cancel.isCancelled ||
            client.baseUrl != base ||
            client.userId != userId ||
            client.accessToken != token) {
          return {'itemId': itemId, 'userId': userId};
        }
        return {
          'itemId': itemId,
          'userId': userId,
          'item': results[0],
          'user': results[1],
        };
      } catch (error) {
        return {
          'itemId': itemId,
          'userId': userId,
          'failure': error is MediaServerException
              ? error.kind.name
              : 'unknown',
        };
      }
    }();
  }

  /// Hand already-negotiated data to the child without further network IO.
  PlayerStartupPreparation.handoff({
    required String userId,
    required String itemId,
    required MediaItem item,
    MediaUser? user,
    List<PlaybackMediaSource>? versions,
  }) : payload = Future.value({
         'itemId': itemId,
         'userId': userId,
         'item': encodeMediaItem(item),
         if (user != null) 'user': encodeMediaUser(user),
         if (versions != null && versions.isNotEmpty)
           'versions': versions.map(encodePlaybackMediaSource).toList(),
         'fetchedAt': DateTime.now().toUtc().toIso8601String(),
       });

  final _cancel = CancelToken();
  late final Future<Map<String, dynamic>> payload;
  void cancel() => _cancel.cancel();
}
