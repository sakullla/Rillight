import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/player_startup.dart';

class _Client extends EmbyClient {
  _Client()
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      ) {
    attachSession(
      baseUrl: Uri.parse('https://synthetic.invalid'),
      accessToken: 'synthetic',
      userId: 'user',
    );
  }
  final calls = <String, Completer<Map<String, dynamic>>>{};
  final cancellations = <CancelToken>[];
  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) {
    if (cancelToken != null) cancellations.add(cancelToken);
    return (calls[path] = Completer<Map<String, dynamic>>()).future;
  }
}

void main() {
  test(
    'preparation overlaps item and user requests and limits user payload',
    () async {
      final client = _Client();
      final preparation = PlayerStartupPreparation(client, 'item');
      expect(client.calls.keys, ['/Users/user/Items/item', '/Users/user']);
      client.calls.values.first.complete({
        'Id': 'item',
        'UserData': {'PlaybackPositionTicks': 123},
      });
      client.calls.values.last.complete({
        'Id': 'user',
        'Policy': {'secret': true},
        'Configuration': {'ResumeRewindSeconds': 5},
      });
      final data = await preparation.payload;
      expect((data['item'] as Map)['UserData'], {'PlaybackPositionTicks': 123});
      expect((data['user'] as Map).containsKey('Policy'), isFalse);
      expect((data['user'] as Map)['Configuration']['ResumeRewindSeconds'], 5);
    },
  );

  test(
    'cancelled preparation and changed authentication discard metadata',
    () async {
      for (final cancel in [true, false]) {
        final client = _Client();
        final preparation = PlayerStartupPreparation(client, 'item');
        if (cancel) {
          preparation.cancel();
          expect(
            client.cancellations.every((token) => token.isCancelled),
            isTrue,
          );
        } else {
          client.attachSession(
            baseUrl: Uri.parse('https://synthetic.invalid'),
            accessToken: 'changed',
            userId: 'user',
          );
        }
        client.calls.values.first.complete({'Id': 'item'});
        client.calls.values.last.complete({'Id': 'user'});
        expect((await preparation.payload).containsKey('item'), isFalse);
      }
    },
  );

  test(
    'optional malformed user does not fail fresh item preparation',
    () async {
      final client = _Client();
      final preparation = PlayerStartupPreparation(client, 'item');
      client.calls.values.first.complete({'Id': 'item'});
      client.calls.values.last.complete({});
      final data = await preparation.payload;
      expect(data['item'], {'Id': 'item'});
      expect(data['user'], isNull);
    },
  );

  test(
    'mailbox validates scope, falls back on invalid data and preserves typed failure',
    () async {
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
        'item': {'Id': 'item'},
        'user': {'Id': 'user'},
      });
      expect((await receive())?.item.id, 'item');
      await protocol.write('startup', {
        'itemId': 'other',
        'userId': 'user',
        'item': {'Id': 'other'},
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
        'failure': 'unauthorized',
      });
      await expectLater(receive(), throwsA(isA<EmbyException>()));
    },
  );
}
