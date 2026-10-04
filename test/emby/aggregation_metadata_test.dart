import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';

void main() {
  test(
    'ProviderIds and LastPlayedDate are facts, links and positions are not identities/timestamps',
    () {
      final item = EmbyItem.fromJson({
        'Id': '1',
        'Name': 'Movie',
        'Type': 'Movie',
        'ProviderIds': {
          'Tmdb': 42,
          'Imdb': ' tt123 ',
          'Empty': '',
          'Null': null,
        },
        'UserData': {
          'PlaybackPositionTicks': 123,
          'LastPlayedDate': '2026-01-02T03:04:05Z',
        },
      });
      expect(item.providerIds, {'Tmdb': '42', 'Imdb': 'tt123'});
      expect(item.userData.lastPlayedDate, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(
        item
            .copyWith(userData: item.userData.copyWith(played: true))
            .providerIds,
        item.providerIds,
      );
      expect(
        item.userData.copyWith(played: true).lastPlayedDate,
        item.userData.lastPlayedDate,
      );
      final missing = EmbyItem.fromJson({
        'Id': '2',
        'ExternalUrls': [
          {'Name': 'IMDb', 'Url': 'https://imdb.com/title/tt123'},
        ],
        'UserData': {'PlaybackPositionTicks': 999, 'LastPlayedDate': 'invalid'},
      });
      expect(missing.providerIds, isEmpty);
      expect(missing.userData.lastPlayedDate, isNull);
      expect(EmbyUserData.fromJson(null).lastPlayedDate, isNull);
    },
  );

  test(
    'media versions parse comparison/language fields without fabricated defaults',
    () {
      final source = ItemMediaSource.fromJson({
        'Id': 'version',
        'RunTimeTicks': 900,
        'Size': 1234,
        'Bitrate': 4500,
        'MediaStreams': [
          {
            'Index': 4,
            'Type': 'Video',
            'Codec': 'hevc',
            'Width': 3840,
            'Height': 2160,
            'VideoRangeType': 'HDR10',
            'Profile': 'Main 10',
            'AverageFrameRate': 23.976,
          },
          {
            'Index': 8,
            'Type': 'Audio',
            'Language': 'zho',
            'DisplayTitle': '中文',
            'Channels': 6,
            'ChannelLayout': '5.1',
            'SampleRate': 48000,
            'IsDefault': false,
          },
          {
            'Index': 9,
            'Type': 'Subtitle',
            'Language': 'eng',
            'IsForced': true,
            'IsExternal': true,
          },
        ],
      });
      expect(source.runTimeTicks, 900);
      expect(source.streams.first.profile, 'Main 10');
      expect(source.streams.first.averageFrameRate, 23.976);
      expect(source.audioStreams.single.language, 'zho');
      expect(source.audioStreams.single.label, '中文');
      expect(source.audioStreams.single.isDefault, isFalse);
      expect(source.audioStreams.single.sampleRate, 48000);
      expect(source.subtitleStreams.single.isForced, isTrue);
      expect(source.subtitleStreams.single.isExternal, isTrue);
      final unknown = ItemMediaSource.fromJson({
        'Id': 'unknown',
        'MediaStreams': [
          {'Index': 0, 'Type': 'Audio'},
        ],
      });
      expect(unknown.runTimeTicks, isNull);
      expect(unknown.bitrate, isNull);
      expect(unknown.streams.single.language, isNull);
      expect(unknown.streams.single.isDefault, isNull);
      expect(unknown.streams.single.isForced, isNull);
      expect(unknown.streams.single.channels, isNull);
    },
  );

  test(
    'normal detail request asks for identities/user data and retains media streams',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final queries = <Map<String, String>>[];
      final subscription = server.listen((request) async {
        queries.add(request.uri.queryParameters);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'Id': 'movie',
            'Name': 'Movie',
            'Type': 'Movie',
            'ProviderIds': {'Tmdb': '42'},
            'UserData': {'LastPlayedDate': '2026-01-01T00:00:00Z'},
            'MediaSources': [
              {
                'Id': 'v',
                'MediaStreams': [
                  {'Index': 0, 'Type': 'Video', 'Codec': 'av1'},
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });
      final client =
          EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'test',
              deviceId: 'test',
              version: '1',
            ),
          )..attachSession(
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            accessToken: 'synthetic',
            userId: 'u',
          );
      try {
        final item = await client.getItem('movie');
        expect(item.providerIds, {'Tmdb': '42'});
        expect(item.userData.lastPlayedDate, DateTime.utc(2026));
        expect(item.mediaSources.single.streams.single.codec, 'av1');
        expect(queries.single['Fields'], contains('ProviderIds'));
        expect(queries.single['Fields'], contains('UserData'));
        expect(queries.single['Fields'], contains('MediaSources'));
        for (final fields in [
          EmbyClient.gridFields,
          EmbyClient.homePosterFields,
        ]) {
          expect(fields, contains('ProviderIds'));
          expect(fields, contains('UserData'));
          expect(fields, isNot(contains('MediaSources')));
        }
      } finally {
        client.clearSession();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
