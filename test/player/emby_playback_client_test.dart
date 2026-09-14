import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_models.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-playback',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late EmbyClient client;

  setUp(() async {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = await client.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    client.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
  });

  test(
    'PlaybackInfo sends mpv DeviceProfile and returns Direct Stream',
    () async {
      final info = await client.getPlaybackInfo(itemId: 'movie-inception');
      expect(info.playSessionId, isNotEmpty);
      expect(info.primarySource?.supportsDirectStream, isTrue);
      expect(info.primarySource?.directStreamUrl, contains('static=true'));
      expect(server.lastDeviceProfile, isNotNull);
      final direct =
          (server.lastDeviceProfile!['DirectPlayProfiles'] as List).first
              as Map;
      expect(direct['Container'].toString(), contains('mkv'));
      expect(direct['VideoCodec'].toString(), contains('hevc'));
      expect(direct['AudioCodec'].toString(), contains('ac3'));
    },
  );

  test('forced transcode source exposes TranscodingUrl', () async {
    final info = await client.getPlaybackInfo(itemId: 'movie-transcode');
    expect(info.primarySource?.supportsDirectStream, isFalse);
    expect(info.primarySource?.transcodingUrl, contains('master.m3u8'));
  });

  test('PGS subtitle request stays direct with Embed declaration', () async {
    // 设备声明 pgs/pgssub 为文档值 Embed 后,直连场景服务端不强制烧录,
    // 仍返回 DirectStream,由 mpv 本地渲染内嵌位图轨道。
    final info = await client.getPlaybackInfo(
      itemId: 'movie-pgs',
      subtitleStreamIndex: 2,
    );
    expect(info.primarySource?.supportsDirectStream, isTrue);
    expect(info.primarySource?.transcodingUrl, isNull);
    expect(info.primarySource?.directStreamUrl, isNotNull);
    final subs = (server.lastDeviceProfile!['SubtitleProfiles'] as List).map(
      (item) => Map<String, dynamic>.from(item as Map),
    );
    expect(
      subs.any(
        (item) => item['Format'] == 'pgssub' && item['Method'] == 'Embed',
      ),
      isTrue,
    );
    expect(subs.any((item) => item['Method'] == 'Embedded'), isFalse);
  });

  test('dvdsub bitmap subtitle still burns in via transcode', () async {
    // 设备未声明可本地渲染的位图格式(如 dvdsub)仍走烧录转码。
    server.items = [
      ...defaultCatalogItems(),
      FakeEmbyItem(
        id: 'movie-pgs-dvd',
        name: 'DVD字幕片',
        type: 'Movie',
        parentId: 'view-movies',
        productionYear: 2016,
        runTimeTicks: 10000000 * 80,
        mediaStreams: const [
          FakeMediaStream(
            index: 0,
            type: 'Video',
            codec: 'h264',
            displayTitle: '1080p',
          ),
          FakeMediaStream(
            index: 1,
            type: 'Audio',
            codec: 'aac',
            language: 'eng',
            displayTitle: 'English',
            isDefault: true,
          ),
          FakeMediaStream(
            index: 2,
            type: 'Subtitle',
            codec: 'dvdsub',
            language: 'chi',
            displayTitle: 'DVD字幕',
            isDefault: true,
            isTextSubtitleStream: false,
          ),
        ],
      ),
    ];
    final info = await client.getPlaybackInfo(
      itemId: 'movie-pgs-dvd',
      subtitleStreamIndex: 2,
    );
    expect(info.primarySource?.supportsDirectStream, isFalse);
    expect(
      info.primarySource?.transcodingUrl,
      contains('SubtitleStreamIndex=2'),
    );
  });

  test('next episode follows series order', () async {
    final current = await client.getItem('episode-friends-s1e1');
    final next = await client.getNextEpisode(current);
    expect(next?.id, 'episode-friends-s1e2');
    expect(await client.getNextEpisode(next!), isNull);
  });

  test('Playing Progress Stopped payloads include PlayMethod', () async {
    const report = PlaybackReport(
      itemId: 'movie-inception',
      mediaSourceId: 'movie-inception',
      playSessionId: 'play-1',
      playMethod: PlayMethod.directStream,
      positionTicks: 10000000,
    );
    await client.reportPlaying(report);
    await client.reportProgress(report.copyWith(eventName: 'TimeUpdate'));
    await client.reportStopped(report);
    expect(server.playbackEvents.map((event) => event.kind), [
      'Playing',
      'Progress',
      'Stopped',
    ]);
    expect(server.playbackEvents.first.body['PlayMethod'], 'DirectStream');
    expect(server.playbackEvents.map((event) => event.userAgent).toList(), [
      'Rillight/0.1.0',
      'Rillight/0.1.0',
      'Rillight/0.1.0',
    ]);
  });

  test(
    'Playing Progress Stopped events carry the configured User-Agent',
    () async {
      client.setUserAgent('PlaybackUA/3');
      expect(client.customUserAgent, 'PlaybackUA/3');
      const report = PlaybackReport(
        itemId: 'movie-inception',
        mediaSourceId: 'movie-inception',
        playSessionId: 'play-1',
        playMethod: PlayMethod.directStream,
        positionTicks: 10000000,
      );
      await client.reportPlaying(report);
      await client.reportProgress(report.copyWith(eventName: 'TimeUpdate'));
      await client.reportStopped(report);
      expect(server.playbackEvents.map((event) => event.userAgent).toList(), [
        'PlaybackUA/3',
        'PlaybackUA/3',
        'PlaybackUA/3',
      ]);
    },
  );
}
