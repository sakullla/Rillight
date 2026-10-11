import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';

/// Independent synthetic account + PMS fixture. Protocol baseline: official PMS
/// OpenAPI 1.2.3, JWK/PIN/JWT documentation retrieved 2026-10-11; fixture v2.
/// This does not assert an actual PMS version or real upstream compatibility.
class FakePlex {
  late HttpServer server;
  Uri get url =>
      Uri.parse('http://${server.address.address}:${server.port}/prefix');
  final requests =
      <
        ({String path, String method, Map<String, String> query, String? token})
      >[];
  Map<String, dynamic>? jwk;
  bool authorized = false,
      sharedDenied = false,
      homeDenied = false,
      transcodeDenied = false,
      missingPartDuration = false;
  int? errorStatus;
  String? errorMessage;
  Completer<void>? pollGate, metadataGate;
  int refreshes = 0, stops = 0;
  String? redirectTo;
  String pinToken = cloudToken;
  bool expireCloud = false;
  bool failStops = false;
  bool expireHome = false;
  String secondAudioCodec = 'aac';
  String secondAudioLanguage = 'eng';
  bool additionalUnsupportedAudio = false;
  String subtitleCodec = 'srt';
  String? subtitleDecision;
  String? subtitleLocation;
  bool defaultSubtitleSelected = false;
  int? decisionBitrateKbps = 8000;
  List<Map<String, dynamic>>? mediaVersions;
  List<Map<String, dynamic>>? catalog;
  final Map<String, Map<String, int>> selectedStreams = {};
  final sessions = <String>{};
  static const cloudToken = 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiIxIn0.synthetic';
  static const refreshedToken =
      'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiIxIn0.refreshed';
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await _handle(request);
      } catch (error, stack) {
        request.response.statusCode = 500;
        request.response.write('$error\n$stack');
        await request.response.close();
      }
    });
  }

  Future<void> close() => server.close(force: true);
  Future<void> _json(HttpRequest r, Object value, {int status = 200}) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path.replaceFirst('/prefix', '');
    final q = r.uri.queryParameters;
    final token = r.headers.value('x-plex-token');
    requests.add((
      path: path,
      method: r.method,
      query: Map.from(q),
      token: token,
    ));
    if (errorStatus != null) {
      return _json(r, {
        'error': errorMessage ?? 'synthetic failure',
      }, status: errorStatus!);
    }
    if (r.headers.value('accept') != 'application/json') {
      return _json(r, {}, status: 406);
    }
    if (expireCloud && token == cloudToken) return _json(r, {}, status: 498);
    if (expireHome && token == 'home-scoped-token') {
      return _json(r, {}, status: 498);
    }
    if (path == '/api/v2/pins' && r.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
      jwk = body['jwk'] as Map<String, dynamic>?;
      if (jwk?['crv'] != 'Ed25519' ||
          jwk?['alg'] != 'EdDSA' ||
          jwk?['kty'] != 'OKP') {
        return _json(r, {}, status: 422);
      }
      return _json(r, {'id': 11, 'code': 'ABCD', 'expiresIn': 300});
    }
    if (path == '/api/v2/pins/11') {
      if (!await _verify(q['deviceJWT'], nonce: false)) {
        return _json(r, {}, status: 422);
      }
      await pollGate?.future;
      return _json(r, {
        'id': 11,
        'code': 'ABCD',
        'authToken': authorized ? pinToken : null,
      });
    }
    if (path == '/api/v2/auth/nonce') {
      return _json(r, {'nonce': 'single-use-nonce'});
    }
    if (path == '/api/v2/auth/token') {
      final body =
          jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
      if (!await _verify(body['jwt'] as String?, nonce: true)) {
        return _json(r, {}, status: 422);
      }
      refreshes++;
      return _json(r, {'auth_token': refreshedToken});
    }
    if (path == '/api/v2/user') {
      if (token == 'home-scoped-token') {
        return _json(r, {'id': 2, 'username': 'Child'});
      }
      if (![cloudToken, refreshedToken].contains(token)) {
        return _json(r, {}, status: 401);
      }
      return _json(r, {'id': 1, 'username': 'Owner'});
    }
    if (path == '/api/home/users') {
      if (token != cloudToken && token != refreshedToken) {
        return _json(r, {}, status: 401);
      }
      return _json(r, {
        'MediaContainer': {
          'User': [
            {'id': 1, 'title': 'Owner', 'protected': false},
            {'id': 2, 'title': 'Child', 'protected': true},
          ],
        },
      });
    }
    if (path == '/api/home/users/2/switch') {
      if (homeDenied || q['pin'] != '1234') return _json(r, {}, status: 403);
      return _json(r, {
        'id': 2,
        'title': 'Child',
        'authenticationToken': 'home-scoped-token',
      });
    }
    if (path == '/api/v2/resources') {
      if (sharedDenied) return _json(r, {}, status: 403);
      if (![cloudToken, refreshedToken, 'home-scoped-token'].contains(token)) {
        return _json(r, {}, status: 401);
      }
      return _json(r, [
        {
          'name': 'Shared films',
          'clientIdentifier': 'server-a',
          'provides': 'server',
          'owned': false,
          'productVersion': 'synthetic-fixture-v1',
          'accessToken': token == 'home-scoped-token'
              ? 'child-resource'
              : 'owner-resource',
          'connections': [
            {'uri': url.toString(), 'local': true, 'relay': false},
            {'uri': 'https://relay.invalid', 'local': false, 'relay': true},
          ],
        },
      ]);
    }
    if (path == '/api/v2/users/signout' && r.method == 'DELETE') {
      return _json(r, {});
    }
    if (path == '/identity') {
      return _json(r, {
        'MediaContainer': {
          'machineIdentifier': 'server-a',
          'version': 'synthetic-fixture-v1',
        },
      });
    }
    if (!['owner-resource', 'child-resource'].contains(token)) {
      return _json(r, {}, status: 401);
    }
    if (path == '/') {
      return _json(r, {
        'MediaContainer': {'machineIdentifier': 'server-a'},
      });
    }
    if (path == '/redirect' && redirectTo != null) {
      r.response.statusCode = 302;
      r.response.headers.set('location', redirectTo!);
      return r.response.close();
    }
    if (path == '/library/sections') {
      return _json(r, {
        'MediaContainer': {
          'Directory': [
            {'key': '1', 'title': 'Movies', 'type': 'movie'},
            if (token != 'child-resource')
              {'key': '2', 'title': 'TV', 'type': 'show'},
            {'key': '3', 'title': 'Music', 'type': 'artist'},
          ],
        },
      });
    }
    if (path == '/library/metadata/42') {
      await metadataGate?.future;
      return _json(r, {
        'MediaContainer': {
          'Metadata': [movie],
        },
      });
    }
    if (path == '/hubs/search') {
      final matches = _catalog
          .where(
            (row) => '${row['title']}'.toLowerCase().contains(
              (q['query'] ?? '').toLowerCase(),
            ),
          )
          .toList();
      final count = int.tryParse(q['limit'] ?? '3') ?? 3;
      return _json(r, {
        'MediaContainer': {
          'Hub': [
            {
              'type': 'movie',
              'more': matches.length > count,
              'totalSize': matches.length,
              'key':
                  '/library/all?type=1&title=${Uri.encodeQueryComponent(q['query'] ?? '')}',
              'Metadata': matches.take(count).toList(),
            },
          ],
        },
      });
    }
    if (path == '/library/metadata/42/similar' ||
        RegExp(r'^/library/sections/\d+/all$').hasMatch(path) ||
        path == '/library/all' ||
        path == '/library/onDeck') {
      final start = int.tryParse(q['X-Plex-Container-Start'] ?? '0') ?? 0;
      final size = int.tryParse(q['X-Plex-Container-Size'] ?? '20') ?? 20;
      final section = RegExp(
        r'^/library/sections/(\d+)/all$',
      ).firstMatch(path)?.group(1);
      final rows = _catalog.where((row) {
        if (token == 'child-resource' && row['librarySectionID'] != 1) {
          return false;
        }
        if (section != null && '${row['librarySectionID']}' != section) {
          return false;
        }
        if (q['title'] != null &&
            !'${row['title']}'.toLowerCase().contains(
              q['title']!.toLowerCase(),
            )) {
          return false;
        }
        final type = {
          'movie': '1',
          'show': '2',
          'season': '3',
          'episode': '4',
        }[row['type']];
        if (q['type'] != null && !q['type']!.split(',').contains(type)) {
          return false;
        }
        if (q['unwatched'] == '1' && (row['viewCount'] as int? ?? 0) > 0) {
          return false;
        }
        if (q['unwatched'] == '0' && (row['viewCount'] as int? ?? 0) == 0) {
          return false;
        }
        if (q['year'] != null &&
            !q['year']!.split(',').contains('${row['year']}')) {
          return false;
        }
        if (q['genre'] != null &&
            !(row['Genre'] as List).any(
              (genre) => q['genre']!.split(',').contains('${genre['id']}'),
            )) {
          return false;
        }
        return true;
      }).toList();
      return _json(r, {
        'MediaContainer': {
          'offset': start,
          'totalSize': rows.length,
          'Metadata': rows.skip(start).take(size).toList(),
        },
      });
    }
    if (path == '/hubs/continueWatching') {
      return _json(r, {
        'MediaContainer': {
          'Hub': [
            {
              'hubIdentifier': 'home.continue',
              'Metadata': [movie],
            },
          ],
        },
      });
    }
    if (path == '/library/sections/1/genre' ||
        path == '/library/sections/2/genre') {
      return _json(r, {
        'MediaContainer': {
          'Directory': [
            {'key': path.contains('/1/') ? '17' : '27', 'title': 'Drama'},
            if (path.contains('/2/')) {'key': '28', 'title': 'Comedy'},
          ],
        },
      });
    }
    if ([
      '/library/metadata/42/thumb/1',
      '/library/parts/102/indexes/sd/2000',
      '/library/streams/13',
    ].contains(path)) {
      r.response.add([1, 2, 3]);
      return r.response.close();
    }
    if (path == '/video/:/transcode/universal/decision') {
      if (q['session'] == null ||
          int.tryParse(q['mediaIndex'] ?? '') == null ||
          q['partIndex'] == null) {
        return _json(r, {}, status: 400);
      }
      sessions.add(q['session']!);
      final partIndex = int.parse(q['partIndex']!);
      final media =
          (movie['Media'] as List)[int.parse(q['mediaIndex']!)] as Map;
      final parts = media['Part'] as List;
      final part = parts[partIndex] as Map;
      final selection = selectedStreams['${part['id']}'] ?? {};
      final chosenAudio =
          selection['audioStreamID'] ??
          ((part['Stream'] as List).cast<Map>().firstWhere(
                (s) => s['streamType'] == 2,
              )['id']
              as int);
      final chosenSubtitle = q['subtitles'] == 'none'
          ? 0
          : selection['subtitleStreamID'] ??
                (defaultSubtitleSelected && partIndex == 0 ? 13 : 0);
      final output = <Map<String, dynamic>>[];
      for (final source
          in (part['Stream'] as List).cast<Map<String, dynamic>>()) {
        final type = source['streamType'];
        final id = source['id'];
        if (type == 1) {
          output.add({
            ...source,
            'index': 0,
            'codec': 'h264',
            'decision': 'transcode',
            'location': 'segments-video',
          });
        }
        if (type == 2 && id == chosenAudio) {
          output.add({
            ...source,
            'index': 1,
            'codec': q['directStreamAudio'] == '0' ? 'aac' : source['codec'],
            'decision': q['directStreamAudio'] == '0' ? 'transcode' : 'copy',
            'location': 'segments-audio',
          });
        }
        if (type == 3 && id == chosenSubtitle) {
          output.add({
            ...source,
            'index': 2,
            'codec':
                subtitleLocation == 'sidecar-subs' ||
                    subtitleLocation == 'segments-subs'
                ? 'webvtt'
                : source['codec'],
            'decision':
                subtitleDecision ??
                (q['subtitles'] == 'burn' ? 'burn' : 'copy'),
            'location':
                subtitleLocation ??
                (q['subtitles'] == 'burn' ? 'embedded' : 'sidecar-subs'),
            'key': '/transcoded/subtitle.vtt',
          });
        }
      }
      return _json(r, {
        'MediaContainer': {
          'generalDecisionCode': transcodeDenied ? 2000 : 1000,
          'Metadata': [
            {
              'Media': [
                {
                  if (decisionBitrateKbps != null)
                    'bitrate': decisionBitrateKbps,
                  'id': media['id'],
                  'selected': true,
                  'Part': [
                    {
                      'id': part['id'],
                      'selected': true,
                      'decision': 'transcode',
                      'Stream': output,
                    },
                  ],
                },
              ],
            },
          ],
        },
      });
    }
    if (path.startsWith('/library/parts/') && r.method == 'PUT') {
      final partId = path.split('/').last;
      final part = (movie['Media'] as List)
          .cast<Map>()
          .expand((m) => (m['Part'] as List).cast<Map>())
          .firstWhere((part) => '${part['id']}' == partId);
      final streams = (part['Stream'] as List).cast<Map>();
      if (q['audioStreamID'] != null &&
          !streams.any(
            (s) => s['streamType'] == 2 && '${s['id']}' == q['audioStreamID'],
          )) {
        return _json(r, {}, status: 400);
      }
      selectedStreams[partId] = {
        ...?selectedStreams[partId],
        for (final entry in q.entries)
          if (['audioStreamID', 'subtitleStreamID'].contains(entry.key))
            entry.key: int.parse(entry.value),
      };
      return _json(r, {});
    }
    if (path == '/video/:/transcode/universal/stop') {
      if (failStops) return _json(r, {}, status: 503);
      stops++;
      sessions.remove(q['session']);
      return _json(r, {});
    }
    if (path == '/video/:/transcode/universal/start.m3u8') {
      if (!sessions.contains(q['session'])) return _json(r, {}, status: 404);
      r.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      r.response.write(
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
      );
      return r.response.close();
    }
    if ([
      '/:/timeline',
      '/:/scrobble',
      '/:/unscrobble',
      '/actions/removeFromContinueWatching',
    ].contains(path)) {
      return _json(r, {});
    }
    return _json(r, {}, status: 404);
  }

  Future<bool> _verify(String? jwt, {required bool nonce}) async {
    if (jwt == null || jwk == null) return false;
    final parts = jwt.split('.');
    if (parts.length != 3) return false;
    List<int> decode(String s) => base64Url.decode(base64Url.normalize(s));
    final header = jsonDecode(utf8.decode(decode(parts[0]))) as Map;
    final body = jsonDecode(utf8.decode(decode(parts[1]))) as Map;
    if (header['kid'] != jwk!['kid'] ||
        header['alg'] != 'EdDSA' ||
        body['aud'] != 'plex.tv' ||
        body['iss'] != 'test-device') {
      return false;
    }
    if (nonce && body['nonce'] != 'single-use-nonce') return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((body['iat'] as int) > now + 60 || (body['exp'] as int) <= now) {
      return false;
    }
    return Ed25519().verify(
      utf8.encode('${parts[0]}.${parts[1]}'),
      signature: Signature(
        decode(parts[2]),
        publicKey: SimplePublicKey(
          decode(jwk!['x'] as String),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }

  Map<String, dynamic> get movie => {
    'ratingKey': '42',
    'title': 'Synthetic film',
    'type': 'movie',
    'librarySectionID': 1,
    'duration': 120000,
    'viewOffset': 12345,
    'viewCount': 0,
    'thumb': '/library/metadata/42/thumb/1',
    'year': 2026,
    'Guid': [
      {'id': 'tmdb://100'},
      {'id': 'imdb://tt100'},
    ],
    'Genre': [
      {'id': 17, 'tag': 'Drama'},
    ],
    'Marker': [
      {'type': 'intro', 'startTimeOffset': 1000, 'endTimeOffset': 4000},
      {'type': 'intro', 'startTimeOffset': 5000},
    ],
    'Media':
        mediaVersions ??
        [
          {
            'id': 7,
            'container': 'mkv',
            'duration': 120000,
            'bitrate': 20000,
            'Part': [
              {
                'id': 101,
                'key': '/library/parts/101/file.mkv',
                'duration': missingPartDuration ? null : 60000,
                'indexes': 'sd',
                'Stream': [
                  {'id': 11, 'streamType': 1, 'codec': 'h264'},
                  {
                    'id': 12,
                    'streamType': 2,
                    'codec': 'aac',
                    'languageCode': 'eng',
                    'selected': true,
                  },
                  if (additionalUnsupportedAudio)
                    {
                      'id': 14,
                      'streamType': 2,
                      'codec': 'dts',
                      'languageCode': 'jpn',
                    },
                  {
                    'id': 13,
                    'streamType': 3,
                    'codec': subtitleCodec,
                    'selected': defaultSubtitleSelected,
                    'key': '/library/streams/13',
                  },
                ],
              },
              {
                'id': 102,
                'key': '/library/parts/102/file.mkv',
                'duration': 60000,
                'indexes': 'sd',
                'Stream': [
                  {'id': 21, 'streamType': 1, 'codec': 'h264'},
                  {
                    'id': 22,
                    'streamType': 2,
                    'codec': secondAudioCodec,
                    'languageCode': secondAudioLanguage,
                    'selected': true,
                  },
                ],
              },
            ],
          },
        ],
  };

  List<Map<String, dynamic>> get _catalog =>
      catalog ??
      [
        movie,
        {...movie, 'ratingKey': '43', 'title': 'Other film'},
      ];
}
