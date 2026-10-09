import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

import '../../test/emby/fake_emby_server.dart';
import '../../test/player/danmaku/danmaku_controller_cases.dart'
    show FakeDandanplayClient;

FakeDandanplayClient captureDanmakuClient() => FakeDandanplayClient()
  ..searchResponse = const [
    DanmakuAnime(
      animeId: 10,
      animeTitle: '飞屋环游记',
      type: 'movie',
      episodes: [
        DanmakuEpisode(episodeId: 100, episodeTitle: '剧场版 · 正片'),
        DanmakuEpisode(episodeId: 101, episodeTitle: '加长版 · 幕后花絮'),
      ],
    ),
    DanmakuAnime(
      animeId: 20,
      animeTitle: '飞屋环游记 · 特别篇',
      type: 'movie',
      episodes: [DanmakuEpisode(episodeId: 200, episodeTitle: '特别篇')],
    ),
  ]
  ..commentResponse = const [
    DanmakuComment(
      cid: 1,
      time: 0,
      mode: 1,
      color: 0xffffff,
      text: '一起出发，去看更大的世界',
    ),
    DanmakuComment(cid: 2, time: 0, mode: 5, color: 0xffdca8, text: '这段风景太美了'),
    DanmakuComment(
      cid: 3,
      time: .2,
      mode: 4,
      color: 0xffffff,
      text: '每一次相遇都是新的冒险',
    ),
  ];

/// 密集场景语言表:每种语言生成「内嵌 + 外挂」两条,共 60 条字幕。
const _denseSubtitleSpecs = <(String, String)>[
  ('chi', '简体中文'),
  ('chi', '繁体中文'),
  ('eng', 'English'),
  ('jpn', '日本語'),
  ('kor', '한국어'),
  ('fra', 'Français'),
  ('deu', 'Deutsch'),
  ('spa', 'Español'),
  ('por', 'Português'),
  ('ita', 'Italiano'),
  ('rus', 'Русский'),
  ('ara', 'العربية'),
  ('tha', 'ภาษาไทย'),
  ('vie', 'Tiếng Việt'),
  ('ind', 'Bahasa Indonesia'),
  ('msa', 'Bahasa Melayu'),
  ('nld', 'Nederlands'),
  ('swe', 'Svenska'),
  ('nor', 'Norsk'),
  ('dan', 'Dansk'),
  ('fin', 'Suomi'),
  ('pol', 'Polski'),
  ('ces', 'Čeština'),
  ('tur', 'Türkçe'),
  ('ukr', 'Українська'),
  ('ron', 'Română'),
  ('ell', 'Ελληνικά'),
  ('heb', 'עברית'),
  ('hin', 'हिन्दी'),
  ('fas', 'فارسی'),
];

/// 60 条字幕轨:30 种语言 × 内嵌/外挂,混入 PGS 位图轨。
List<FakeMediaStream> _denseStreams() => [
  const FakeMediaStream(
    index: 0,
    type: 'Video',
    codec: 'hevc',
    displayTitle: '4K HEVC HDR',
    width: 3840,
    height: 2160,
  ),
  const FakeMediaStream(
    index: 1,
    type: 'Audio',
    codec: 'truehd',
    language: 'eng',
    displayTitle: 'English · TrueHD Atmos 7.1',
    isDefault: true,
    channels: 8,
  ),
  const FakeMediaStream(
    index: 2,
    type: 'Audio',
    codec: 'dts',
    language: 'chi',
    displayTitle: '国语 · DTS-HD MA 5.1',
    channels: 6,
  ),
  const FakeMediaStream(
    index: 3,
    type: 'Audio',
    codec: 'aac',
    language: 'jpn',
    displayTitle: '日本語 · AAC 2.0',
    channels: 2,
  ),
  const FakeMediaStream(
    index: 4,
    type: 'Audio',
    codec: 'flac',
    language: 'eng',
    displayTitle: 'English · FLAC commentary',
    channels: 2,
  ),
  for (final (i, spec) in _denseSubtitleSpecs.indexed) ...[
    FakeMediaStream(
      index: 5 + i * 2,
      type: 'Subtitle',
      codec: i % 5 == 4 ? 'pgs' : 'subrip',
      language: spec.$1,
      displayTitle: '${spec.$2} · 内嵌',
      isDefault: i == 0,
      isTextSubtitleStream: i % 5 != 4,
    ),
    FakeMediaStream(
      index: 6 + i * 2,
      type: 'Subtitle',
      codec: 'subrip',
      language: spec.$1,
      displayTitle: '${spec.$2} · 外挂',
      isExternal: true,
      isTextSubtitleStream: true,
    ),
  ],
];

/// 20 个片源:主源 + 19 个多版本(画质/组名/容量各异)。
const _denseSourceNames = <String>[
  '2160p.HDR.BluRay.REMUX.HEVC.DTS-SonyHD',
  '2160p.DoVi.WEB-DL.AV1.Atmos-NetHub',
  '1080p.BluRay.x264.DTS-LineTV',
  '1080p.WEB-DL.H264.AAC-HuoVer',
  '1080p.HDR.WEBRip.H265.EAC3-FangXin',
  '720p.HDTV.H264.AAC-OldRip',
  '1080p.BluRay.REMUX.AVC.TrueHD-KeJi',
  '2160p.HDR10+.BluRay.HEVC.DDP5.1-WeiLai',
  '1080p.WEB-DL.AV1.AAC-MiniSee',
  '720p.WEBRip.H264.AAC-FastDL',
  '2160p.SDR.BluRay.HEVC.DTSMA-Archive',
  '1080p.HDTV.AVC.AAC-LiveHD',
  '1080p.BluRay.x265.EAC3-YinHua',
  '720p.BluRay.H264.FLAC-Classic',
  '2160p.DoVi.BluRay.REMUX.AV1-Galaxy',
  '1080p.WEB-DL.H264.DD-JellyGrp',
  '480p.DVDRip.XviD.MP3-Legacy',
  '1080p.AMZN.WEB-DL.H265.DDP-StreamHQ',
  '1080p.NF.WEB-DL.AV1.EAC3-FlixHub',
];

FakeEmbyServer captureServer() {
  const streams = [
    FakeMediaStream(
      index: 0,
      type: 'Video',
      codec: 'h264',
      displayTitle: '1080p H.264',
    ),
    FakeMediaStream(
      index: 1,
      type: 'Audio',
      codec: 'aac',
      language: 'chi',
      displayTitle: '国语 · AAC 立体声',
      isDefault: true,
    ),
    FakeMediaStream(
      index: 2,
      type: 'Audio',
      codec: 'aac',
      language: 'eng',
      displayTitle: 'English · Director commentary · AAC Stereo',
    ),
    FakeMediaStream(
      index: 3,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'chi',
      displayTitle: '简体中文',
      isTextSubtitleStream: true,
    ),
    FakeMediaStream(
      index: 4,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'eng',
      displayTitle: 'English SDH',
      isTextSubtitleStream: true,
    ),
  ];
  final server = FakeEmbyServer(serverName: '灯川 · 家庭影院');
  server.views.addAll([
    for (final (index, name) in [
      '纪录片',
      '动画',
      '华语佳作',
      '经典修复',
      '短片',
      '演唱会',
      '家庭收藏',
    ].indexed)
      FakeEmbyItem(
        id: 'view-extra-$index',
        name: name,
        type: 'CollectionFolder',
        collectionType: 'movies',
      ),
  ]);
  final movie = server.items.firstWhere((item) => item.id == 'movie-up');
  for (var i = 0; i < server.items.length; i++) {
    final item = server.items[i];
    if (item.type == 'Movie' || item.type == 'Series') {
      item.genres = [
        const ['动画', '冒险', '科幻', '剧情', '喜剧', '纪录片'][i % 6],
        '家庭',
      ];
      item.communityRating ??= 7 + i % 18 / 10;
      item.favorite = i.isEven;
    }
  }
  movie.mediaStreams = streams;
  movie.extraSources = const [
    FakeMediaSource(
      id: 'movie-up-theatrical',
      name: '剧场版 · 1080p · H.264 · AAC',
      mediaStreams: streams,
    ),
    FakeMediaSource(
      id: 'movie-up-extended',
      name: '珍藏加长版 · 4K 修复 · 多语言音轨与导演评论',
      mediaStreams: streams,
    ),
  ];
  movie.overview =
      '一段关于约定、勇气与重新出发的旅程。老人卡尔带着满屋气球飞向远方，却意外遇见了热心的小伙伴。穿过云海与群山，他们发现最珍贵的冒险就在彼此身边。';
  server.setSeasons('series-friends', const [
    FakeSeason(
      id: 'season-friends-1',
      name: '第 1 季',
      indexNumber: 1,
      primaryImageTag: 's1',
      backdropImageTag: 'season-one-backdrop',
    ),
    FakeSeason(
      id: 'season-friends-2',
      name: '第 2 季',
      indexNumber: 2,
      primaryImageTag: 's2',
    ),
  ]);
  server.setEpisodes('series-friends', [
    for (var i = 1; i <= 26; i++)
      FakeEpisode(
        id: 'episode-friends-s1e$i',
        name: '第 $i 集 · 生活中的小小奇遇',
        seasonId: 'season-friends-1',
        indexNumber: i,
        parentIndexNumber: 1,
        primaryImageTag: 'e$i',
        runTimeTicks: 14400000000,
        overview: '朋友们相聚在熟悉的咖啡馆，一次意料之外的邀请打破了平静的日常。',
        mediaStreams: streams,
        nextUp: i == 2,
        played: i == 1,
      ),
    const FakeEpisode(
      id: 'episode-friends-s2e1',
      name: '新的开始',
      seasonId: 'season-friends-2',
      indexNumber: 1,
      parentIndexNumber: 2,
      primaryImageTag: 's2e1',
      mediaStreams: streams,
    ),
  ]);
  final denseStreams = _denseStreams();
  server.items.add(
    FakeEmbyItem(
      id: 'movie-dense',
      name: '环太平洋 · 多版本典藏',
      type: 'Movie',
      parentId: 'view-movies',
      productionYear: 2013,
      runTimeTicks: 54000000000,
      primaryImageTag: 'tag-dense',
      overview: '验收用条目:六十条字幕轨与二十个片源版本。',
      genres: const ['科幻', '动作'],
      communityRating: 7.7,
      mediaStreams: denseStreams,
      extraSources: [
        for (final name in _denseSourceNames)
          FakeMediaSource(
            id: 'movie-dense-${name.split('.').first}-${name.split('-').last}',
            name: name,
            mediaStreams: denseStreams,
          ),
      ],
    ),
  );
  return server;
}

/// In-memory transport: no real server, credentials, image host or native core.
class CaptureAdapter extends FakeEmbyAdapter {
  CaptureAdapter(super.servers);
  Completer<void>? catalogGate;
  Completer<void>? detailGate;
  bool failAggregationMirror = false;
  final artwork = <String, Uint8List>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (failAggregationMirror &&
        options.uri.host == 'capture-mirror.test' &&
        options.uri.path.endsWith('/Items')) {
      return ResponseBody.fromString(
        '{"Message":"synthetic offline"}',
        503,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.uri.path.contains('/Images/')) {
      final parts = options.uri.path.split('/');
      final index = parts.indexOf('Images');
      final id = parts[index - 1];
      if (id == 'palette-fallback' && parts.last == 'Backdrop') {
        return ResponseBody.fromString(
          '<html>synthetic200badimage</html>',
          200,
        );
      }
      if (parts.last == 'Logo') {
        final bytes = artwork['$id-logo'] ??= await drawLogo(id);
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
          },
        );
      }
      if (id != 'movie-broken') {
        final wide = parts.last != 'Primary' || id.startsWith('episode-');
        final key = '$id-$wide';
        final bytes = artwork[key] ??= await drawArtwork(id, wide: wide);
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
          },
        );
      }
    }
    if (options.method == 'GET' && catalogGate != null) {
      await catalogGate!.future;
    }
    // Source authorization must finish before the detail loading tree mounts.
    // Hold only the richer detail request, not its ancestry/permit checks.
    if (options.method == 'GET' &&
        detailGate != null &&
        options.uri.queryParameters['Fields']?.split(',').contains('People') ==
            true) {
      await detailGate!.future;
    }
    final response = await super.fetch(options, requestStream, cancelFuture);
    if (options.method == 'GET' &&
        (response.headers[Headers.contentTypeHeader]?.any(
              (value) => value.contains('application/json'),
            ) ??
            false) &&
        response.statusCode == 200) {
      final bytes = await response.stream.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      final data = jsonDecode(utf8.decode(bytes));
      void addAlbum(Object? value) {
        if (value is Map<String, dynamic>) {
          if (value['Type'] == 'Movie' || value['Type'] == 'Series') {
            value['ProviderIds'] = {
              'Tmdb': value['Id']
                  .toString()
                  .codeUnits
                  .fold<int>(7, (a, b) => a * 31 + b)
                  .abs()
                  .toString(),
            };
          }
          if (value['Id'] == 'movie-up') {
            value['BackdropImageTags'] = ['capture-still-1', 'capture-still-2'];
            // The carousel draws transparent title art when a logo exists.
            final tags = value['ImageTags'];
            if (tags is Map) tags['Logo'] = 'capture-logo';
          }
          // 首页轮播同时呈现全出血与海报聚焦两种版式。
          if (value['Id'] == 'series-friends') {
            value['BackdropImageTags'] = ['capture-still-2'];
          }
          for (final child in value.values) {
            addAlbum(child);
          }
        } else if (value is List) {
          for (final child in value) {
            addAlbum(child);
          }
        }
      }

      addAlbum(data);
      return ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return response;
  }
}

class CaptureBackend extends FakeVideoBackend
    implements VideoBackendPhonePresentation {
  @override
  final ValueNotifier<Map<String, dynamic>> phonePresentation = ValueNotifier({
    'supported': true,
    'foreground': true,
  });
  @override
  Future<void> configurePhonePresentation(bool enabled) async {}
  @override
  Future<Map<String, dynamic>> refreshPhonePresentation() async =>
      phonePresentation.value;
  @override
  Future<bool> enterPictureInPicture() async {
    phonePresentation.value = {
      'supported': true,
      'active': true,
      'retainPlayback': true,
      'foreground': false,
    };
    return true;
  }

  CaptureBackend() : super(duration: const Duration(minutes: 96));
  Completer<void>? openGate;

  @override
  Future<void> open(VideoOpenRequest request) async {
    if (openGate != null) await openGate!.future;
    await super.open(request);
  }

  @override
  Widget buildView({Key? key}) => CustomPaint(
    key: key,
    painter: const LandscapePainter(seed: 4),
    child: const SizedBox.expand(),
  );
}

/// Synthetic transparent wordmark standing in for a server title logo.
Future<Uint8List> drawLogo(String id) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final painter = TextPainter(
    text: TextSpan(
      text: 'UP',
      style: TextStyle(
        fontFamily: 'Roboto',
        fontSize: 200,
        fontWeight: FontWeight.w900,
        letterSpacing: 24,
        height: 1,
        foreground: Paint()
          ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 200), [
            const Color(0xFFFFF4D6),
            const Color(0xFFF2B84B),
          ]),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  // Real title logos are trimmed to their glyphs.
  final size = Size(
    painter.width.ceilToDouble(),
    painter.height.ceilToDouble(),
  );
  painter.paint(canvas, Offset.zero);
  painter.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> drawArtwork(String id, {required bool wide}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = wide ? const Size(960, 540) : const Size(400, 600);
  final seed = id.codeUnits.fold(0, (a, b) => a + b);
  final tone = switch (id) {
    'palette-red' => const Color(0xFFC63F51),
    'palette-blue' || 'palette-fallback' => const Color(0xFF3566C4),
    'palette-green' => const Color(0xFF278B62),
    'palette-mono' => const Color(0xFF888888),
    'palette-bright' => const Color(0xFFFAFAFA),
    'palette-dark' => const Color(0xFF080808),
    _ => null,
  };
  if (tone != null) {
    canvas.drawRect(Offset.zero & size, Paint()..color = tone);
    canvas.drawCircle(
      Offset(size.width * .7, size.height * .25),
      size.shortestSide * .12,
      Paint()..color = Colors.white.withValues(alpha: .2),
    );
  } else {
    LandscapePainter(seed: seed).paint(canvas, size);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// Code-drawn original landscape makes image loading and hover scrims visible.
class LandscapePainter extends CustomPainter {
  const LandscapePainter({required this.seed});
  final int seed;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = (seed * 37 % 360).toDouble();
    final sky = HSLColor.fromAHSL(1, hue, .35, .25).toColor();
    final glow = HSLColor.fromAHSL(1, (hue + 40) % 360, .55, .68).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          [sky, glow],
        ),
    );
    canvas.drawCircle(
      Offset(size.width * .7, size.height * .28),
      size.shortestSide * .12,
      Paint()..color = const Color(0xfff1ddae),
    );
    for (var layer = 0; layer < 4; layer++) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i <= 8; i++) {
        final y = .45 + layer * .12 + ((seed + i * 17 + layer * 11) % 23) / 100;
        path.lineTo(size.width * i / 8, size.height * y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            sky,
            const Color(0xff071820),
            .25 + layer * .18,
          )!,
      );
    }
    final paint = Paint()
      ..color = const Color(0x447adbd3)
      ..strokeWidth = 1;
    for (var i = 0; i < 18; i++) {
      final y = size.height * (.82 + i * .01);
      canvas.drawLine(
        Offset(size.width * .25, y),
        Offset(size.width * (.7 + i % 3 * .04), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(LandscapePainter oldDelegate) => oldDelegate.seed != seed;
}
