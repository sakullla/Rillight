import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/playback.dart';
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

  test('handoff preparation carries negotiated versions losslessly', () async {
    const source = PlaybackMediaSource(
      id: 'ms',
      name: '4K HDR',
      container: 'mkv',
      protocol: 'File',
      path: '/srv/movie.mkv',
      supportsDirectPlay: true,
      supportsDirectStream: true,
      isInfiniteStream: false,
      directStreamUrl: '/stream?ms=1',
      bitrate: 42000000,
      size: 8123456789,
      width: 3840,
      height: 2160,
      runtime: Duration(seconds: 5400),
      defaultAudioStreamIndex: 2,
      mediaStreams: [
        MediaStreamInfo(
          index: 1,
          type: 'Video',
          codec: 'hevc',
          width: 3840,
          height: 2160,
          bitRate: 40000000,
          videoRange: 'HDR',
          videoRangeType: 'DOVI',
        ),
        MediaStreamInfo(
          index: 2,
          type: 'Audio',
          codec: 'eac3',
          language: 'chi',
          displayTitle: '中文 TrueHD Atmos',
          channels: 8,
          isDefault: true,
        ),
        MediaStreamInfo(
          index: 3,
          type: 'Subtitle',
          codec: 'ass',
          language: 'chi',
          isExternal: true,
          isTextSubtitleStream: true,
          deliveryMethod: 'External',
          deliveryUrl: '/sub/3',
          playbackIndex: 5,
        ),
      ],
    );
    final protocol = await PlayerProcessProtocol.create();
    addTearDown(protocol.dispose);
    final preparation = PlayerStartupPreparation.handoff(
      userId: 'user',
      itemId: 'item',
      item: item,
      user: user,
      versions: const [source],
    );
    await protocol.write('startup', await preparation.payload);
    final data = await PlayerStartupData.receive(
      protocol,
      itemId: 'item',
      userId: 'user',
      timeout: const Duration(milliseconds: 50),
    );
    expect(data, isNotNull);
    expect(data!.fetchedAt, isNotNull);
    final versions = data.versions!;
    expect(versions, hasLength(1));
    final decoded = versions.single;
    expect(decoded.id, source.id);
    expect(decoded.container, source.container);
    expect(decoded.protocol, source.protocol);
    expect(decoded.path, source.path);
    expect(decoded.supportsDirectPlay, isTrue);
    expect(decoded.supportsDirectStream, isTrue);
    expect(decoded.supportsTranscoding, isFalse);
    expect(decoded.isInfiniteStream, isFalse);
    expect(decoded.directStreamUrl, source.directStreamUrl);
    expect(decoded.transcodingUrl, isNull);
    expect(decoded.bitrate, source.bitrate);
    expect(decoded.size, source.size);
    expect(decoded.width, source.width);
    expect(decoded.height, source.height);
    expect(decoded.runtime, source.runtime);
    expect(decoded.defaultAudioStreamIndex, 2);
    expect(decoded.mediaStreams, hasLength(3));
    final video = decoded.mediaStreams[0];
    expect(video.type, 'Video');
    expect(video.codec, 'hevc');
    expect(video.width, 3840);
    expect(video.bitRate, 40000000);
    expect(video.videoRangeType, 'DOVI');
    final audio = decoded.mediaStreams[1];
    expect(audio.codec, 'eac3');
    expect(audio.language, 'chi');
    expect(audio.displayTitle, '中文 TrueHD Atmos');
    expect(audio.channels, 8);
    expect(audio.isDefault, isTrue);
    final subtitle = decoded.mediaStreams[2];
    expect(subtitle.isExternal, isTrue);
    expect(subtitle.isTextSubtitleStream, isTrue);
    expect(subtitle.deliveryMethod, 'External');
    expect(subtitle.deliveryUrl, '/sub/3');
    expect(subtitle.playbackIndex, 5);
  });

  test('handoff without versions still completes a usable payload', () async {
    final preparation = PlayerStartupPreparation.handoff(
      userId: 'user',
      itemId: 'item',
      item: item,
    );
    final payload = await preparation.payload;
    expect(payload['itemId'], 'item');
    expect(payload['userId'], 'user');
    expect((payload['item'] as Map)['id'], 'item');
    expect(payload.containsKey('user'), isFalse);
    expect(payload.containsKey('versions'), isFalse);
  });
}
