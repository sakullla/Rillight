import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Stateful HTTP fixture checked against the independently frozen OpenAPI paths.
/// It models device-scoped NowPlaying clearing, not only expected call bodies.
class JellyfinFakeServer {
  late HttpServer server;
  late Map<String, dynamic> contract;
  final requests =
      <
        ({
          String method,
          String path,
          Map<String, String> query,
          Map<String, dynamic>? body,
          String? authorization,
        })
      >[];
  final violations = <String>[];
  final watched = <String>{};
  final nowPlaying = <String, String>{};
  final resources = <String, String>{};
  final userData = <String, dynamic>{
    'Played': false,
    'PlaybackPositionTicks': 123456780,
  };
  bool quickEnabled = true, quickAuthorized = false;
  List<int> imageBytes = const [255, 216, 255, 217];
  String serverId = 'server-jellyfin';
  String transcodeOutputQuery = '';
  int? nextStatus;
  Object? nextJson;
  Completer<void>? delay;
  Completer<void>? arrived;
  int _counter = 0;
  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/jf');
  Map<String, dynamic> get item => {
    'Id': 'movie-1',
    'Name': '测试电影',
    'Type': 'Movie',
    'RunTimeTicks': 1200000000,
    'ProviderIds': {'Tmdb': '123'},
    'UserData': userData,
    'ImageTags': {'Primary': 'poster-tag'},
    'MediaSources': [
      {
        'Id': 'version-1',
        'Name': '原版',
        'Container': 'mkv',
        'RunTimeTicks': 1200000000,
        'MediaStreams': [
          {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Language': 'zho'},
        ],
      },
    ],
    'Chapters': [
      {'Name': 'Chapter 1', 'StartPositionTicks': 0, 'ImageTag': 'chapter-tag'},
    ],
    'Trickplay': {
      'version-1': {
        '160': {
          'Width': 160,
          'Height': 90,
          'TileWidth': 2,
          'TileHeight': 2,
          'ThumbnailCount': 6,
          'Interval': 10000,
        },
      },
    },
  };
  Future<void> start() async {
    contract = jsonDecode(
      await File('test/jellyfin/protocol_contract.json').readAsString(),
    ) as Map<String, dynamic>;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      try {
        await _handle(r);
      } catch (e, st) {
        violations.add('$e\n$st');
        r.response.statusCode = 500;
        await r.response.close();
      }
    });
  }

  Future<void> close() => server.close(force: true);
  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path.replaceFirst('/jf', '');
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
    final auth = request.headers.value('authorization');
    requests.add((
      method: request.method,
      path: path,
      query: request.uri.queryParameters,
      body: body,
      authorization: auth,
    ));
    final waiting = delay;
    delay = null;
    arrived?.complete();
    arrived = null;
    if (waiting != null) await waiting.future;
    if (nextStatus != null) {
      request.response.statusCode = nextStatus!;
      nextStatus = null;
      await request.response.close();
      return;
    }
    if (nextJson != null) {
      final value = nextJson;
      nextJson = null;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(value));
      await request.response.close();
      return;
    }
    Map? op;
    final routes = (contract['paths'] as Map).entries.toList()
      ..sort(
        (a, b) =>
            a.key.toString().contains('{') == b.key.toString().contains('{')
            ? 0
            : a.key.toString().contains('{')
            ? 1
            : -1,
      );
    for (final e in routes) {
      final regex = RegExp(
        '^${e.key.toString().replaceAll(RegExp(r'\{[^}]+\}'), '[^/]+')}\$',
      );
      if (regex.hasMatch(path)) {
        op = (e.value as Map)[request.method.toLowerCase()] as Map?;
        break;
      }
    }
    final special =
        path.contains('/Images/') ||
        path.contains('/Subtitles/') ||
        path.contains('/Episodes');
    if (op == null && !special) {
      violations.add('Unspecified route ${request.method} $path');
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    if (op != null) {
      final allowed = (op['parameters'] as List).cast<String>();
      for (final q in request.uri.queryParameters.keys) {
        if (!allowed.contains(q)) violations.add('Unspecified query $path: $q');
      }
    }
    if (op?['bodyProperties'] is List && body != null) {
      for (final key in body.keys) {
        if (!(op!['bodyProperties'] as List).contains(key)) {
          violations.add('Unspecified body $path: $key');
        }
      }
    }
    final public =
        path == '/System/Info/Public' ||
        path.startsWith('/QuickConnect/') ||
        path.startsWith('/Users/Authenticate');
    if (auth == null ||
        !auth.startsWith('MediaBrowser ') ||
        (!public && !auth.contains('Token="fake-token"'))) {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final device = RegExp(r'DeviceId="([^"]+)"').firstMatch(auth)!.group(1)!;
    Object? result;
    switch (path) {
      case '/System/Info/Public':
        result = {
          'Id': serverId,
          'ServerName': 'Independent Jellyfin Fake',
          'Version': '12.2.0-fixture',
        };
      case '/Users/AuthenticateByName':
        if (body?['Username'] != 'alice' || body?['Pw'] != 'password') {
          request.response.statusCode = 401;
          break;
        }
        result = _login;
      case '/QuickConnect/Enabled':
        result = quickEnabled;
      case '/QuickConnect/Initiate':
        result = {
          'Code': '654321',
          'Secret': 'quick-secret',
          'Authenticated': false,
        };
      case '/QuickConnect/Connect':
        if (request.uri.queryParameters['secret'] != 'quick-secret') {
          request.response.statusCode = 404;
          break;
        }
        result = {'Authenticated': quickAuthorized};
      case '/Users/AuthenticateWithQuickConnect':
        if (!quickAuthorized || body?['Secret'] != 'quick-secret') {
          request.response.statusCode = 403;
          break;
        }
        result = _login;
      case '/Users/Me':
        result = {'Id': 'alice-id', 'Name': 'Alice'};
      case '/Users/Password':
      case '/Sessions/Logout':
        request.response.statusCode = 204;
      case '/UserViews':
        result = {
          'Items': [
            {
              'Id': 'library-1',
              'Name': '电影',
              'Type': 'CollectionFolder',
              'CollectionType': 'movies',
            },
          ],
          'TotalRecordCount': 1,
        };
      case '/Items':
      case '/UserItems/Resume':
      case '/Shows/NextUp':
      case '/Items/movie-1/Similar':
        result = {
          'Items': [item],
          'TotalRecordCount': 31,
        };
      case '/Items/Latest':
        result = [item];
      case '/Items/movie-1':
        result = item;
      case '/Items/Counts':
        result = {'MovieCount': 1};
      case '/Items/Filters2':
        result = {
          'Genres': [
            {'Name': '剧情', 'Id': 'genre-1'},
          ],
        };
      case '/MediaSegments/movie-1':
        result = {
          'Items': [
            {
              'ItemId': 'movie-1',
              'Type': 'Intro',
              'StartTicks': 10000000,
              'EndTicks': 30000000,
            },
            {'ItemId': 'movie-1', 'Type': 'Intro', 'StartTicks': 50000000},
          ],
        };
      case '/UserPlayedItems/movie-1':
        if (request.method == 'POST') {
          watched.add('movie-1');
        } else {
          watched.remove('movie-1');
        }
        request.response.statusCode = 204;
      case '/UserItems/movie-1/UserData':
        userData.addAll(body!);
        result = userData;
      case '/Items/movie-1/PlaybackInfo':
        final id = 'raw-session-${++_counter}';
        resources[id] = device;
        result = {
          'PlaySessionId': id,
          'MediaSources': [
            {
              'Id': 'version-1',
              'Container': 'mkv',
              'Bitrate': 24000000,
              'RunTimeTicks': 1200000000,
              'SupportsDirectPlay': body!['EnableDirectPlay'],
              'SupportsDirectStream': true,
              'SupportsTranscoding': true,
              'TranscodingUrl':
                  '/Videos/movie-1/master.m3u8?PlaySessionId=$id&DeviceId=$device&sig=a%2Fb+z$transcodeOutputQuery',
              'MediaStreams': [
                {'Index': 1, 'Type': 'Audio', 'Codec': 'aac'},
                {
                  'Index': 2,
                  'Type': 'Subtitle',
                  'Codec': 'srt',
                  'IsExternal': true,
                },
              ],
            },
          ],
        };
      case '/Sessions/Playing':
      case '/Sessions/Playing/Progress':
        final id = body!['PlaySessionId'] as String;
        if (resources[id] != device) violations.add('wrong playback device');
        nowPlaying[device] = body['ItemId'] as String;
        request.response.statusCode = 204;
      case '/Sessions/Playing/Stopped':
        final id = body!['PlaySessionId'] as String;
        if (resources[id] != device) violations.add('wrong cleanup device');
        resources.remove(id);
        nowPlaying.remove(device);
        if (body['ItemId'] != null && body['PositionTicks'] != null) {
          userData['PlaybackPositionTicks'] = body['PositionTicks'];
        }
        request.response.statusCode = 204;
      default:
        if (path.contains('/Trickplay/') || path.contains('/Images/')) {
          request.response.add(imageBytes);
          await request.response.close();
          return;
        }
        if (path.contains('/Episodes')) {
          result = {
            'Items': [
              {'Id': 'prev', 'Name': '前集', 'Type': 'Episode'},
              {'Id': 'current', 'Name': '本集', 'Type': 'Episode'},
              {'Id': 'next', 'Name': '下集', 'Type': 'Episode'},
            ],
          };
        }
    }
    if (result != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    }
    await request.response.close();
  }

  Map<String, dynamic> get _login => {
    'AccessToken': 'fake-token',
    'ServerId': serverId,
    'User': {'Id': 'alice-id', 'Name': 'Alice'},
  };
}
