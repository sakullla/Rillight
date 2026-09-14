import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_settings.dart';

/// 弹幕会话状态(菜单与横幅提示依据)。
enum DanmakuStatus {
  /// 用户关闭弹幕。
  off,

  /// 开启但尚无会话(播放未解析完成)。
  idle,

  /// 匹配/拉取中。
  loading,

  /// 弹幕已加载。
  active,

  /// 未匹配到弹幕(可手动搜索)。
  noMatch,

  /// 自定义服务不可用(明确提示,可回退官方源)。
  customUnreachable,

  /// 官方源不可达(静默无弹幕)。
  unreachable,
}

/// 一次弹幕会话的匹配上下文,由 player_page 从当前播放状态构建。
class DanmakuEpisodeContext {
  const DanmakuEpisodeContext({
    required this.itemId,
    required this.mediaSourceId,
    this.seriesId,
    this.seriesTitle,
    this.title,
    this.fileName,
    this.episodeIndex,
    this.streamUrl,
    this.duration = Duration.zero,
    this.isMovie = false,
  });

  /// 会话键组成部分:换条目或换媒体源视为新会话。
  final String itemId;
  final String mediaSourceId;
  final String? seriesId;
  final String? seriesTitle;
  final String? title;
  final String? fileName;
  final int? episodeIndex;

  /// 直连播放流地址(用于 16MB 哈希);转码流为 null(哈希无意义)。
  final Uri? streamUrl;
  final Duration duration;
  final bool isMovie;
}

/// 弹幕控制器:匹配/降级/记忆、来源选择与回退、显示参数与开关持久化。
///
/// 播放位置经 [syncFromPlayback]/[updatePosition] 喂入(不自行订阅 backend),
/// 渲染层按 [estimatePosition] 推进时间轴。网络一律经注入的
/// [DandanplayClient]/[DanmakuStreamHasher](测试全部 fake,不真实拨号)。
class DanmakuController extends ChangeNotifier {
  DanmakuController({
    PlayerSettingsStore? settingsStore,
    DandanplayClient? client,
    DanmakuStreamHasher? hasher,
    DanmakuTextMeasurer? textMeasurer,
  }) : _injectedStore = settingsStore,
       _client = client ?? DandanplayClient(),
       _hasher = hasher ?? DanmakuStreamHasher(),
       layout = DanmakuLayout(measurer: textMeasurer ?? _defaultMeasure);

  final PlayerSettingsStore? _injectedStore;
  final DandanplayClient _client;
  final DanmakuStreamHasher _hasher;

  /// 时间轴布局引擎(渲染层直接驱动)。
  final DanmakuLayout layout;

  DanmakuStatus status = DanmakuStatus.idle;

  /// 自定义服务不可用时的细节(诊断提示)。
  String? statusDetail;

  /// 已匹配的动画标题(菜单状态回显)。
  String? matchedTitle;

  /// 弹幕开关(持久化;null 配置默认开启)。
  bool danmakuOn = true;

  DanmakuDisplaySettings display = const DanmakuDisplaySettings();

  List<DanmakuComment> get comments => layout.comments;

  bool get hasComments => layout.comments.isNotEmpty;

  /// 自定义兼容服务基地址(空表示官方直连)。
  String? customServerUrl;
  String? customToken;

  /// 自定义服务失败后本会话内回退官方源(不持久化)。
  bool _officialFallback = false;
  Map<String, DanmakuSeriesMemory> _memories = const {};

  DanmakuEpisodeContext? _context;
  String? _sessionKey;

  /// 会话代际:每次 [startSession] 递增;旧会话的异步结果
  /// (弹幕落地/按剧记忆写入/状态落地)前校验未变,快速换集时丢弃。
  int _sessionGeneration = 0;

  Future<void>? _restoreFuture;
  PlayerSettingsStore? _store;

  // --- 播放位置喂入(渲染层插值用) ---

  Duration _anchorPosition = Duration.zero;
  DateTime _anchorAt = DateTime.now();
  bool playing = false;
  double playbackRate = 1;

  bool get usesCustomSource =>
      !_officialFallback &&
      customServerUrl != null &&
      customServerUrl!.isNotEmpty;

  DandanplaySource get _source {
    final url = customServerUrl;
    if (usesCustomSource) {
      return DandanplaySource.custom(url!, customToken);
    }
    return DandanplaySource.official;
  }

  /// 按播放状态估计当前时间轴位置(暂停时冻结在最后已知位置)。
  Duration estimatePosition() {
    if (!playing) {
      return _anchorPosition;
    }
    final elapsed = DateTime.now().difference(_anchorAt);
    return _anchorPosition + elapsed * playbackRate;
  }

  /// 由 player_page 的控制器监听驱动:会话未变时只推进位置,
  /// 换条目/换源时开启新会话。
  void syncFromPlayback(
    DanmakuEpisodeContext? context, {
    required Duration position,
    required bool playing,
    required double rate,
  }) {
    if (context != null) {
      final key = '${context.itemId}|${context.mediaSourceId}';
      if (key != _sessionKey) {
        unawaited(startSession(context));
        return;
      }
    }
    updatePosition(position, playing: playing, rate: rate);
  }

  void updatePosition(
    Duration position, {
    required bool playing,
    required double rate,
  }) {
    final wasPlaying = this.playing;
    final estimate = estimatePosition();
    final jumped = (position - estimate).abs() > kDanmakuSeekThreshold;
    _anchorPosition = position;
    _anchorAt = DateTime.now();
    this.playing = playing;
    playbackRate = rate;
    if (wasPlaying != playing || jumped) {
      notifyListeners();
    }
  }

  /// 开启新会话:重置布局并按 记忆→哈希匹配→标题搜索 降级解析。
  Future<void> startSession(DanmakuEpisodeContext context) async {
    _sessionGeneration++;
    _context = context;
    _sessionKey = '${context.itemId}|${context.mediaSourceId}';
    layout.reset();
    layout.comments = const [];
    matchedTitle = null;
    statusDetail = null;
    // 先恢复持久化设置(开关/显示参数/记忆/来源)再决定是否加载。
    await _ensureRestored();
    if (!danmakuOn) {
      status = DanmakuStatus.off;
      notifyListeners();
      return;
    }
    status = DanmakuStatus.loading;
    notifyListeners();
    await _resolveAndLoad(context);
  }

  /// 弹幕开关:关闭立即清屏;开启时对当前会话重新解析加载。
  Future<void> toggleDanmaku() async {
    danmakuOn = !danmakuOn;
    if (danmakuOn) {
      final context = _context;
      if (context != null) {
        status = DanmakuStatus.loading;
        notifyListeners();
        await _ensureRestored();
        await _resolveAndLoad(context);
      } else {
        status = DanmakuStatus.idle;
        notifyListeners();
      }
    } else {
      status = DanmakuStatus.off;
      statusDetail = null;
      matchedTitle = null;
      layout.reset();
      layout.comments = const [];
      notifyListeners();
    }
    await _writeSettings();
  }

  /// 更新显示参数:立即生效并持久化。
  Future<void> setDisplay(DanmakuDisplaySettings next) async {
    display = next;
    layout.settings = next;
    layout.reset();
    notifyListeners();
    await _writeSettings();
  }

  /// 手动搜索(匹配错误时切换剧集入口)。失败返回空列表。
  Future<List<DanmakuAnime>> search(String keyword) async {
    final term = keyword.trim();
    if (term.isEmpty) {
      return const [];
    }
    try {
      return await _client.searchAnime(_source, term);
    } on DanmakuApiException {
      return const [];
    }
  }

  /// 手动选择搜索结果的某一集:加载其弹幕并写入按剧记忆。
  Future<void> selectEpisode(DanmakuAnime anime, DanmakuEpisode episode) async {
    final context = _context;
    if (context == null) {
      return;
    }
    final generation = _sessionGeneration;
    status = DanmakuStatus.loading;
    notifyListeners();
    try {
      final loaded = await _client.fetchComments(_source, episode.episodeId);
      if (generation != _sessionGeneration) {
        // 与 _resolveAndLoad 同族保护:会话已切换,选择结果不落地。
        return;
      }
      await _remember(
        context,
        anime.animeId,
        anime.animeTitle,
        episode.episodeId,
      );
      layout.comments = loaded;
      matchedTitle = anime.animeTitle;
      status = DanmakuStatus.active;
      notifyListeners();
    } on DanmakuApiException catch (failure) {
      if (generation != _sessionGeneration) {
        return;
      }
      _handleLoadFailure(failure);
    }
  }

  /// 自定义服务不可用时回退官方源并重试当前会话。
  Future<void> useOfficialSource() async {
    final context = _context;
    if (context == null || !usesCustomSource) {
      return;
    }
    _officialFallback = true;
    status = DanmakuStatus.loading;
    statusDetail = null;
    notifyListeners();
    await _resolveAndLoad(context);
  }

  // -------------------------------------------------------------------
  // 匹配降级链
  // -------------------------------------------------------------------

  Future<void> _resolveAndLoad(DanmakuEpisodeContext context) async {
    final generation = _sessionGeneration;
    final source = _source;
    try {
      var animeId = 0;
      var animeTitle = '';
      var episodeId = 0;
      var resolved = false;

      // 1. 按剧记忆:同集直接复用,同剧后续集沿用动画并按集号对位。
      final memory = context.seriesId == null
          ? null
          : _memories[context.seriesId];
      if (memory != null) {
        if (context.episodeIndex != null &&
            memory.episodeId != null &&
            memory.episodeNumber == context.episodeIndex) {
          animeId = memory.animeId;
          animeTitle = memory.animeTitle;
          episodeId = memory.episodeId!;
          resolved = true;
        } else {
          final animes = await _client.searchAnime(source, memory.animeTitle);
          final anime = _findAnimeById(animes, memory.animeId);
          final picked = anime == null
              ? null
              : _pickEpisode(anime.episodes, context.episodeIndex);
          if (picked != null) {
            animeId = anime!.animeId;
            animeTitle = anime.animeTitle;
            episodeId = picked.episodeId;
            resolved = true;
          }
        }
      }

      // 2. dandanplay 匹配:直连流先取前 16MB 哈希,不可得时按文件名降级。
      if (!resolved) {
        final streamUrl = context.streamUrl;
        var hash = '';
        if (streamUrl != null) {
          hash = await _hasher.hashOf(streamUrl) ?? '';
        }
        final match = await _client.match(
          source,
          fileName: context.fileName ?? context.title ?? '',
          fileHash: hash,
          fileSize: 0,
          videoDuration: context.duration.inMinutes,
        );
        if (match.isMatched && match.matches.isNotEmpty) {
          final candidate = match.matches.first;
          animeId = candidate.animeId;
          animeTitle = candidate.animeTitle;
          episodeId = candidate.episodeId;
          resolved = true;
        }
      }

      // 3. 标题搜索降级。
      if (!resolved) {
        var keyword = context.seriesTitle?.trim() ?? '';
        if (keyword.isEmpty) {
          keyword = context.fileName ?? context.title ?? '';
        }
        if (keyword.isNotEmpty) {
          final animes = await _client.searchAnime(source, keyword);
          final anime = _pickAnime(animes, context.isMovie);
          final picked = anime == null
              ? null
              : _pickEpisode(anime.episodes, context.episodeIndex);
          if (picked != null) {
            animeId = anime!.animeId;
            animeTitle = anime.animeTitle;
            episodeId = picked.episodeId;
            resolved = true;
          }
        }
      }

      if (!resolved) {
        if (generation != _sessionGeneration) {
          return;
        }
        status = DanmakuStatus.noMatch;
        notifyListeners();
        return;
      }

      final loaded = await _client.fetchComments(source, episodeId);
      if (generation != _sessionGeneration) {
        // 新会话已开启:旧会话结果不落地、不写记忆。
        return;
      }
      await _remember(context, animeId, animeTitle, episodeId);
      layout.comments = loaded;
      matchedTitle = animeTitle;
      status = DanmakuStatus.active;
      notifyListeners();
    } on DanmakuApiException catch (failure) {
      if (generation != _sessionGeneration) {
        return;
      }
      _handleLoadFailure(failure);
    }
  }

  void _handleLoadFailure(DanmakuApiException failure) {
    if (usesCustomSource) {
      // 自定义服务不可用:明确提示,可回退官方源。
      status = DanmakuStatus.customUnreachable;
      statusDetail = failure.toString();
    } else {
      // 官方源不可达:静默无弹幕。
      status = DanmakuStatus.unreachable;
      statusDetail = null;
    }
    notifyListeners();
  }

  Future<void> _remember(
    DanmakuEpisodeContext context,
    int animeId,
    String animeTitle,
    int episodeId,
  ) async {
    final seriesId = context.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    _memories = Map.of(_memories);
    _memories[seriesId] = DanmakuSeriesMemory(
      animeId: animeId,
      animeTitle: animeTitle,
      episodeId: episodeId,
      episodeNumber: context.episodeIndex,
    );
    await _writeSettings();
  }

  static DanmakuAnime? _findAnimeById(List<DanmakuAnime> animes, int animeId) {
    for (final anime in animes) {
      if (anime.animeId == animeId) {
        return anime;
      }
    }
    return null;
  }

  /// 按条目类型挑选搜索结果:电影取 movie,剧集优先 tvseries。
  static DanmakuAnime? _pickAnime(List<DanmakuAnime> animes, bool isMovie) {
    for (final anime in animes) {
      if (isMovie && anime.isMovie) {
        return anime;
      }
      if (!isMovie && (anime.isSeries || anime.type == null)) {
        return anime;
      }
    }
    return animes.isEmpty ? null : animes.first;
  }

  /// 按集号挑选剧集:先按标题中的集号匹配,再退位置对位。
  static DanmakuEpisode? _pickEpisode(
    List<DanmakuEpisode> episodes,
    int? episodeIndex,
  ) {
    if (episodes.isEmpty) {
      return null;
    }
    if (episodeIndex != null) {
      for (final episode in episodes) {
        if (parseEpisodeNumber(episode.episodeTitle) == episodeIndex) {
          return episode;
        }
      }
      if (episodeIndex >= 1 && episodeIndex <= episodes.length) {
        return episodes[episodeIndex - 1];
      }
    }
    return episodes.first;
  }

  // -------------------------------------------------------------------
  // 设置持久化
  // -------------------------------------------------------------------

  Future<PlayerSettingsStore> _settings() async {
    return _store ??= _injectedStore ?? await openPlayerSettingsStore();
  }

  Future<void> _ensureRestored() {
    return _restoreFuture ??= _restore();
  }

  Future<void> _restore() async {
    try {
      final settings = await (await _settings()).read();
      danmakuOn = settings.isDanmakuEnabled;
      display = settings.danmakuDisplay ?? const DanmakuDisplaySettings();
      layout.settings = display;
      final server = settings.danmakuServer?.trim();
      customServerUrl = (server == null || server.isEmpty) ? null : server;
      final token = settings.danmakuToken?.trim();
      customToken = (token == null || token.isEmpty) ? null : token;
      _memories = Map.of(settings.danmakuSeriesMemories);
    } catch (_) {
      // 设置不可读时按默认运行,不阻塞弹幕会话。
    }
  }

  Future<void> _writeSettings() async {
    try {
      // 部分写:只携带弹幕字段,音量等未设置字段不参与合并写覆盖。
      await (await _settings()).write(
        PlayerSettings(
          danmakuEnabled: danmakuOn,
          danmakuDisplay: display,
          danmakuServer: customServerUrl,
          danmakuToken: customToken,
          danmakuSeriesMemories: _memories,
        ),
      );
    } catch (_) {
      // 持久化失败不影响运行时行为。
    }
  }

  /// 默认文本测量器:TextPainter 一次布局取宽度。
  static double _defaultMeasure(String text, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}

/// 从剧集标题解析集号:第12话 / EP3 / 03.5 等常见形态。
int? parseEpisodeNumber(String title) {
  var match = RegExp(r'第\s*(\d{1,4})\s*[话話集]').firstMatch(title);
  match ??= RegExp(
    r'(?:^|[^0-9a-zA-Z])ep?\.?\s*(\d{1,4})',
    caseSensitive: false,
  ).firstMatch(title);
  match ??= RegExp(r'(?:^|\s)(\d{1,4})(?:\s|$|[.．，,])').firstMatch(title);
  return match == null ? null : int.tryParse(match.group(1)!);
}
