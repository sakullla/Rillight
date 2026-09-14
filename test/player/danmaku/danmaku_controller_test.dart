import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_settings.dart';

/// 行为 fake:记录调用与来源,不真实拨号。
class FakeDandanplayClient extends DandanplayClient {
  FakeDandanplayClient() : super(dio: Dio());

  final List<(DandanplaySource, String)> searchCalls = [];
  final List<(DandanplaySource, int)> commentCalls = [];
  final List<(DandanplaySource, Map<String, Object?>)> matchCalls = [];

  DanmakuMatchResponse matchResponse = const DanmakuMatchResponse(
    isMatched: false,
    matches: [],
  );
  List<DanmakuAnime> searchResponse = const [];
  List<DanmakuComment> commentResponse = const [];
  Object? matchError;
  Object? searchError;
  Object? commentError;

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
  }) async {
    matchCalls.add((
      source,
      {
        'fileName': fileName,
        'fileHash': fileHash,
        'fileSize': fileSize,
        'videoDuration': videoDuration,
      },
    ));
    if (matchError != null) {
      throw matchError!;
    }
    return matchResponse;
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword,
  ) async {
    searchCalls.add((source, keyword));
    if (searchError != null) {
      throw searchError!;
    }
    return searchResponse;
  }

  @override
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
  }) async {
    commentCalls.add((source, episodeId));
    if (commentError != null) {
      throw commentError!;
    }
    return commentResponse;
  }
}

class FakeHasher extends DanmakuStreamHasher {
  FakeHasher([this.hash]);

  final String? hash;
  final List<Uri> requested = [];

  @override
  Future<String?> hashOf(Uri streamUrl) async {
    requested.add(streamUrl);
    return hash;
  }
}

const unreachable = DanmakuApiException(
  DanmakuApiFailureKind.unreachable,
  detail: 'network down',
);

DanmakuComment comment(int cid, double time) =>
    DanmakuComment(cid: cid, time: time, mode: 1, color: 16777215, text: 'hi');

DanmakuEpisodeContext context({
  String itemId = 'item-1',
  String? seriesId = 'series-1',
  int? index = 1,
  bool directStream = true,
  bool isMovie = false,
}) {
  return DanmakuEpisodeContext(
    itemId: itemId,
    mediaSourceId: 'ms',
    seriesId: seriesId,
    seriesTitle: 'Show',
    title: 'Show 1',
    fileName: '[G] Show - 01.mkv',
    episodeIndex: index,
    streamUrl: directStream ? Uri.parse('https://emby/stream') : null,
    duration: const Duration(minutes: 24),
    isMovie: isMovie,
  );
}

void main() {
  late FakeDandanplayClient client;
  late FakeHasher hasher;
  late MemoryPlayerSettingsStore store;

  DanmakuController makeController({MemoryPlayerSettingsStore? settings}) {
    return DanmakuController(
      settingsStore: settings ?? store,
      client: client,
      hasher: hasher,
      textMeasurer: (text, fontSize) => text.length * fontSize * 0.6,
    );
  }

  setUp(() {
    client = FakeDandanplayClient();
    hasher = FakeHasher('deadbeef');
    store = MemoryPlayerSettingsStore();
  });

  test('auto match loads comments and writes series memory', () async {
    client.matchResponse = const DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 7,
          animeTitle: 'Show',
          episodeId: 100,
          episodeTitle: '第01话',
        ),
      ],
    );
    client.commentResponse = [comment(1, 5)];
    final controller = makeController();
    await controller.startSession(context());

    expect(controller.status, DanmakuStatus.active);
    expect(controller.hasComments, isTrue);
    expect(controller.matchedTitle, 'Show');
    // 直连流先哈希再匹配。
    expect(hasher.requested, hasLength(1));
    expect(client.matchCalls.single.$2['fileHash'], 'deadbeef');
    expect(client.commentCalls.single.$2, 100);

    final memory = (await store.read()).danmakuSeriesMemories['series-1'];
    expect(memory, isNotNull);
    expect(memory!.animeId, 7);
    expect(memory.episodeId, 100);
    expect(memory.episodeNumber, 1);
  });

  test('transcode stream skips hashing and matches by name', () async {
    client.matchResponse = const DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 7,
          animeTitle: 'Show',
          episodeId: 100,
          episodeTitle: '第01话',
        ),
      ],
    );
    final controller = makeController();
    await controller.startSession(context(directStream: false));
    expect(hasher.requested, isEmpty);
    expect(client.matchCalls.single.$2['fileHash'], '');
  });

  test('unavailable hash falls back to filename match', () async {
    hasher = FakeHasher(null);
    final controller = makeController();
    await controller.startSession(context());
    expect(client.matchCalls.single.$2['fileHash'], '');
    expect(client.matchCalls.single.$2['fileName'], '[G] Show - 01.mkv');
  });

  test(
    'same series next episode reuses memory via search, no hash match',
    () async {
      store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          danmakuSeriesMemories: {
            'series-1': DanmakuSeriesMemory(
              animeId: 7,
              animeTitle: 'Show',
              episodeId: 100,
              episodeNumber: 1,
            ),
          },
        ),
      );
      client.searchResponse = const [
        DanmakuAnime(
          animeId: 7,
          animeTitle: 'Show',
          type: 'tvseries',
          episodes: [
            DanmakuEpisode(episodeId: 100, episodeTitle: '第01话'),
            DanmakuEpisode(episodeId: 101, episodeTitle: '第02话'),
            DanmakuEpisode(episodeId: 102, episodeTitle: '第03话'),
          ],
        ),
      ];
      final controller = makeController();
      await controller.startSession(context(index: 2));

      // 记忆路径:按动画标题搜索,不哈希不匹配。
      expect(client.searchCalls, hasLength(1));
      expect(client.searchCalls.single.$2, 'Show');
      expect(client.matchCalls, isEmpty);
      expect(hasher.requested, isEmpty);
      expect(client.commentCalls.single.$2, 101);
      final memory = (await store.read()).danmakuSeriesMemories['series-1'];
      expect(memory!.episodeId, 101);
      expect(memory.episodeNumber, 2);
    },
  );

  test(
    'replaying the same episode reuses remembered episode without network',
    () async {
      store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          danmakuSeriesMemories: {
            'series-1': DanmakuSeriesMemory(
              animeId: 7,
              animeTitle: 'Show',
              episodeId: 100,
              episodeNumber: 1,
            ),
          },
        ),
      );
      final controller = makeController();
      await controller.startSession(context());
      expect(client.searchCalls, isEmpty);
      expect(client.matchCalls, isEmpty);
      expect(client.commentCalls.single.$2, 100);
      expect(controller.status, DanmakuStatus.active);
    },
  );

  test('match miss falls back to title search and episode index', () async {
    client.searchResponse = const [
      DanmakuAnime(
        animeId: 9,
        animeTitle: 'Show',
        type: 'tvseries',
        episodes: [
          DanmakuEpisode(episodeId: 200, episodeTitle: '第01话'),
          DanmakuEpisode(episodeId: 201, episodeTitle: '第02话'),
          DanmakuEpisode(episodeId: 202, episodeTitle: '第03话'),
        ],
      ),
    ];
    final controller = makeController();
    await controller.startSession(context(index: 3));
    expect(client.searchCalls.single.$2, 'Show');
    expect(client.commentCalls.single.$2, 202);
    expect(controller.status, DanmakuStatus.active);
  });

  test('movie context prefers movie results in fallback search', () async {
    client.searchResponse = const [
      DanmakuAnime(
        animeId: 30,
        animeTitle: 'Some Series',
        type: 'tvseries',
        episodes: [DanmakuEpisode(episodeId: 300, episodeTitle: '第01话')],
      ),
      DanmakuAnime(
        animeId: 40,
        animeTitle: 'Show Movie',
        type: 'movie',
        episodes: [DanmakuEpisode(episodeId: 400, episodeTitle: '剧场版')],
      ),
    ];
    final controller = makeController();
    await controller.startSession(context(seriesId: null, isMovie: true));
    expect(client.commentCalls.single.$2, 400);
  });

  test('no match at all lands in noMatch status', () async {
    final controller = makeController();
    await controller.startSession(context());
    expect(controller.status, DanmakuStatus.noMatch);
    expect(controller.hasComments, isFalse);
  });

  test('official source unreachable is silent', () async {
    client.matchError = unreachable;
    final controller = makeController();
    await controller.startSession(context());
    expect(controller.status, DanmakuStatus.unreachable);
    expect(controller.hasComments, isFalse);
  });

  test(
    'custom source used with token; failure prompts and falls back',
    () async {
      store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          danmakuServer: 'https://dan.example.com',
          danmakuToken: 'secret',
        ),
      );
      client.matchError = unreachable;
      final controller = makeController();
      await controller.startSession(context());

      // 自定义服务不可达:明确提示,不发弹幕。
      expect(controller.status, DanmakuStatus.customUnreachable);
      var match = client.matchCalls.single;
      expect(match.$1.isCustom, isTrue);
      expect(match.$1.token, 'secret');
      expect(client.commentCalls, isEmpty);

      // 回退官方源后重试成功。
      client.matchError = null;
      client.matchResponse = const DanmakuMatchResponse(
        isMatched: true,
        matches: [
          DanmakuMatchCandidate(
            animeId: 7,
            animeTitle: 'Show',
            episodeId: 100,
            episodeTitle: '第01话',
          ),
        ],
      );
      await controller.useOfficialSource();
      expect(controller.status, DanmakuStatus.active);
      match = client.matchCalls.last;
      expect(match.$1.isCustom, isFalse);
      expect(client.commentCalls, hasLength(1));
    },
  );

  test('toggle off clears and persists, toggle on reloads', () async {
    client.matchResponse = const DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 7,
          animeTitle: 'Show',
          episodeId: 100,
          episodeTitle: '第01话',
        ),
      ],
    );
    client.commentResponse = [comment(1, 5)];
    final controller = makeController();
    await controller.startSession(context());
    expect(controller.hasComments, isTrue);

    await controller.toggleDanmaku();
    expect(controller.status, DanmakuStatus.off);
    expect(controller.hasComments, isFalse);
    expect((await store.read()).danmakuEnabled, isFalse);

    await controller.toggleDanmaku();
    expect(controller.status, DanmakuStatus.active);
    expect(controller.hasComments, isTrue);
    expect((await store.read()).danmakuEnabled, isTrue);
  });

  test('display settings persist and apply to the layout', () async {
    final controller = makeController();
    await controller.setDisplay(
      const DanmakuDisplaySettings(fontScale: 1.5, speed: 2, opacity: 0.5),
    );
    expect(controller.layout.settings.fontScale, 1.5);
    expect(controller.layout.settings.speed, 2);
    final stored = (await store.read()).danmakuDisplay;
    expect(stored, isNotNull);
    expect(stored!.fontScale, 1.5);
    expect(stored.speed, 2);
    expect(stored.opacity, 0.5);
  });

  test('restore reads persisted switch, display and keywords', () async {
    store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        danmakuEnabled: false,
        danmakuDisplay: DanmakuDisplaySettings(
          fontScale: 0.75,
          blockedKeywords: ['广告'],
        ),
      ),
    );
    final controller = makeController();
    await controller.startSession(context());
    // 恢复的开关为关:会话直接进入 off。
    expect(controller.status, DanmakuStatus.off);
    expect(client.matchCalls, isEmpty);
    await controller.toggleDanmaku();
    expect(controller.danmakuOn, isTrue);
    expect(controller.display.fontScale, 0.75);
    expect(controller.display.blockedKeywords, ['广告']);
    expect(controller.layout.settings.blockedKeywords, ['广告']);
  });

  test('manual search returns results and select loads + remembers', () async {
    final animes = const [
      DanmakuAnime(
        animeId: 9,
        animeTitle: 'Show',
        type: 'tvseries',
        episodes: [
          DanmakuEpisode(episodeId: 200, episodeTitle: '第01话'),
          DanmakuEpisode(episodeId: 201, episodeTitle: '第02话'),
        ],
      ),
    ];
    final controller = makeController();
    await controller.startSession(context());
    expect(controller.status, DanmakuStatus.noMatch);

    // 手动搜索在自动匹配失败后进行。
    client.searchResponse = animes;
    final results = await controller.search('Show');
    expect(results, hasLength(1));

    await controller.selectEpisode(results.first, results.first.episodes.last);
    expect(controller.status, DanmakuStatus.active);
    expect(client.commentCalls.single.$2, 201);
    final memory = (await store.read()).danmakuSeriesMemories['series-1'];
    expect(memory!.episodeId, 201);
    expect(memory.animeId, 9);

    client.searchError = unreachable;
    expect(await controller.search('Show'), isEmpty);
  });

  test('position feed estimates with rate and notifies on jumps', () {
    final controller = makeController();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.updatePosition(
      const Duration(seconds: 10),
      playing: true,
      rate: 2,
    );
    expect(notifications, 1); // 播放状态切换通知
    controller.updatePosition(
      const Duration(seconds: 11),
      playing: true,
      rate: 2,
    );
    expect(notifications, 1); // 正常推进不通知
    // 大幅前跳(seek)通知,回退亦然。
    controller.updatePosition(
      const Duration(seconds: 50),
      playing: true,
      rate: 2,
    );
    expect(notifications, 2);
    controller.updatePosition(
      const Duration(seconds: 20),
      playing: true,
      rate: 2,
    );
    expect(notifications, 3);
    // 暂停冻结。
    controller.updatePosition(
      const Duration(seconds: 20),
      playing: false,
      rate: 2,
    );
    expect(controller.estimatePosition(), const Duration(seconds: 20));
  });

  test('episode number parsing covers common title shapes', () {
    expect(parseEpisodeNumber('第01话 开端'), 1);
    expect(parseEpisodeNumber('第12話'), 12);
    expect(parseEpisodeNumber('EP3 突袭'), 3);
    expect(parseEpisodeNumber('ep.11'), 11);
    expect(parseEpisodeNumber('05.5 总集篇'), 5);
    expect(parseEpisodeNumber('最终话'), isNull);
  });
}
