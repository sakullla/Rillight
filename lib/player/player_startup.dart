import 'dart:async';

import 'package:dio/dio.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/player_process_protocol.dart';

/// Fresh, launch-scoped metadata, fetched while the desktop child boots.
/// PlaybackInfo still runs in the child after applying its current settings.
class PlayerStartupData {
  const PlayerStartupData(this.item, this.user);
  final EmbyItem item;
  final EmbyUser? user;

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
        if (message['itemId'] != itemId || message['userId'] != userId) {
          return null;
        }
        final failure = message['failure'];
        if (failure is String) {
          throw EmbyException(
            EmbyFailureKind.values.firstWhere(
              (kind) => kind.name == failure,
              orElse: () => EmbyFailureKind.unknown,
            ),
          );
        }
        final rawItem = message['item'];
        if (rawItem is! Map) return null;
        try {
          final item = EmbyItem.fromJson(Map<String, dynamic>.from(rawItem));
          if (item.id != itemId) return null;
          final rawUser = message['user'];
          final user = rawUser is Map
              ? EmbyUser.fromJson(Map<String, dynamic>.from(rawUser))
              : null;
          if (user != null && user.id != userId) return null;
          return PlayerStartupData(item, user);
        } catch (_) {
          return null;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // A missing mailbox is a transport failure, not invalid media. Fall back
    // to the normal child requests; never use an earlier launch's metadata.
    return null;
  }
}

class PlayerStartupPreparation {
  PlayerStartupPreparation(EmbyClient client, String itemId) {
    final userId = client.userId;
    final base = client.baseUrl;
    final token = client.accessToken;
    payload = () async {
      try {
        final results = await Future.wait<Map<String, dynamic>?>([
          client.getJson(
            '/Users/$userId/Items/$itemId',
            queryParameters: {
              'Fields': EmbyClient.itemFields,
              'EnableImageTypes': EmbyClient.detailImageTypes,
            },
            cancelToken: _cancel,
          ),
          client
              .getJson('/Users/$userId', cancelToken: _cancel)
              .then<Map<String, dynamic>?>((value) {
                // Carry playback preferences only, not the user's full policy.
                final user = EmbyUser.fromJson(value);
                return {
                  'Id': user.id,
                  'Name': user.name,
                  'Configuration': {
                    'EnableNextEpisodeAutoPlay': user.enableNextEpisodeAutoPlay,
                    'ResumeRewindSeconds': user.resumeRewindSeconds,
                  },
                };
              })
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
          'failure': error is EmbyException ? error.kind.name : 'unknown',
        };
      }
    }();
  }

  final _cancel = CancelToken();
  late final Future<Map<String, dynamic>> payload;
  void cancel() => _cancel.cancel();
}
