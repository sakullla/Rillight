import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/serialization.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/player_startup.dart';

// A business fake, with no inheritance from an Emby transport.
class _Client implements MediaServerClient {
  @override
  final baseUrl = Uri.parse('https://synthetic.invalid');
  @override
  String accessToken = 'synthetic';
  @override
  final userId = 'user';
  final item = Completer<MediaItem>();
  final user = Completer<MediaUser>();
  final calls = <String>[];
  final cancellations = <CancelToken>[];
  @override
  Future<MediaItem> getItem(
    String itemId, {
    String? fields,
    CancelToken? cancelToken,
  }) {
    calls.add('item:$itemId');
    if (cancelToken != null) cancellations.add(cancelToken);
    return item.future;
  }

  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) {
    calls.add('user');
    if (cancelToken != null) cancellations.add(cancelToken);
    return user.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const item = MediaItem(
  id: 'item',
  name: 'Movie',
  type: 'Movie',
  userData: MediaUserData(playbackPosition: Duration(microseconds: 12)),
);
const user = MediaUser(id: 'user', name: 'User', resumeRewindSeconds: 5);

void main() {
  test(
    'preparation overlaps business requests and serializes only user preferences',
    () async {
      final client = _Client();
      final preparation = PlayerStartupPreparation(client, 'item');
      expect(client.calls, ['item:item', 'user']);
      client.item.complete(item);
      client.user.complete(user);
      final data = await preparation.payload;
      expect(
        decodeMediaItem(
          Map<String, dynamic>.from(data['item'] as Map),
        ).userData.playbackPosition,
        const Duration(microseconds: 12),
      );
      expect(
        (data['user'] as Map).keys,
        unorderedEquals([
          'id',
          'name',
          'enableNextEpisodeAutoPlay',
          'resumeRewindSeconds',
        ]),
      );
      expect(
        decodeMediaUser(
          Map<String, dynamic>.from(data['user'] as Map),
        ).resumeRewindSeconds,
        5,
      );
    },
  );

  test(
    'cancelled preparation and changed authentication discard late metadata',
    () async {
      for (final cancel in [true, false]) {
        final client = _Client();
        final preparation = PlayerStartupPreparation(client, 'item');
        if (cancel) {
          preparation.cancel();
          expect(client.cancellations, hasLength(2));
          expect(
            client.cancellations.every((token) => token.isCancelled),
            isTrue,
          );
        } else {
          client.accessToken = 'changed';
        }
        client.item.complete(item);
        client.user.complete(user);
        expect((await preparation.payload).containsKey('item'), isFalse);
      }
    },
  );

  test(
    'optional failed user request does not lose fresh item metadata',
    () async {
      final client = _Client();
      final preparation = PlayerStartupPreparation(client, 'item');
      client.item.complete(item);
      client.user.completeError(
        const MediaServerException(MediaServerFailureKind.invalidResponse),
      );
      final data = await preparation.payload;
      expect((data['item'] as Map)['id'], 'item');
      expect(data['user'], isNull);
    },
  );

  test('mailbox validates scope, malformed data and typed failure', () async {
    final protocol = await PlayerProcessProtocol.create();
    addTearDown(protocol.dispose);
    Future<PlayerStartupData?> receive() => PlayerStartupData.receive(
      protocol,
      itemId: 'item',
      userId: 'user',
      timeout: const Duration(milliseconds: 50),
    );
    await protocol.write('startup', {
      'itemId': 'item',
      'userId': 'user',
      'item': encodeMediaItem(item),
      'user': encodeMediaUser(user),
    });
    expect((await receive())?.item.id, 'item');
    await protocol.write('startup', {
      'itemId': 'other',
      'userId': 'user',
      'item': encodeMediaItem(item),
    });
    expect(await receive(), isNull);
    await protocol.write('startup', {
      'itemId': 'item',
      'userId': 'user',
      'item': {},
    });
    expect(await receive(), isNull);
    expect(await receive(), isNull);
    await protocol.write('startup', {
      'itemId': 'item',
      'userId': 'user',
      'failure': 'sessionExpired',
    });
    await expectLater(
      receive(),
      throwsA(
        isA<MediaServerException>().having(
          (e) => e.kind,
          'kind',
          MediaServerFailureKind.sessionExpired,
        ),
      ),
    );
  });
}
