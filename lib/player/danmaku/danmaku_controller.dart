import 'dart:async';

import 'package:dio/dio.dart';
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

  /// 官方源不可达或未配置 AppId。
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
    this.fileSize = 0,
    this.episodeIndex,
    this.seasonIndex,
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
  final int fileSize;
  final int? episodeIndex;
  final int? seasonIndex;

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
       layout = DanmakuLayout(measurer: textMeasurer ?? _defaultMeasure) {
    unawaited(_primeSettings());
  }

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

  /// 官方开放平台 AppId;与 [customToken](官方源时作 AppSecret)成对使用。
  String? officialAppId;

  /// 自定义服务失败后本会话内回退官方源(不持久化)。
  bool _officialFallback = false;
  Map<String, DanmakuSeriesMemory> _memories = const {};

  DanmakuEpisodeContext? _context;
  String? _sessionKey;

  /// 会话代际:每次 [startSession] 递增;旧会话的异步结果
  /// (弹幕落地/按剧记忆写入/状态落地)前校验未变,快速换集时丢弃。
  int _sessionGeneration = 0;

  /// 手动搜索代际:新搜索或会话切换递增,迟到结果返回空列表。
  int _searchGeneration = 0;
  CancelToken? _sessionCancelToken;
  CancelToken? _searchCancelToken;

  Future<void>? _restoreFuture;
  PlayerSettingsStore? _store;
  bool _disposed = false;

  // --- 播放位置喂入(渲染层插值用) ---

  Duration _anchorPosition = Duration.zero;
  DateTime _anchorAt = DateTime.now();
  bool playing = false;
  double playbackRate = 1;

  bool get usesCustomSource =>
      !_officialFallback &&
      customServerUrl != null &&
      customServerUrl!.isNotEmpty;

  /// 官方源已配置成对的 AppId 与 AppSecret。
  bool get hasOfficialCredentials {
    final id = officialAppId;
    final secret = customToken;
    return id != null && id.isNotEmpty && secret != null && secret.isNotEmpty;
  }

  /// 已填自定义服务或官方 AppId,控制条才露出弹幕入口。
  bool get isConfigured => usesCustomSource || hasOfficialCredentials;

  DandanplaySource get _source {
    final url = customServerUrl;
    if (usesCustomSource) {
      return DandanplaySource.custom(url!, customToken);
    }
    return DandanplaySource.officialWith(
      appId: officialAppId,
      appSecret: customToken,
    );
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
    _cancelActiveToken(_sessionCancelToken);
    _sessionCancelToken = CancelToken();
    _cancelSearchRequests();
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

  bool get _canCallOfficialApi => usesCustomSource || hasOfficialCredentials;

  /// 弹幕开关:关闭立即清屏;开启时对当前会话重新解析加载。
  Future<void> toggleDanmaku() async {
    await _ensureRestored();
    if (_disposed) {
      return;
    }
    danmakuOn = !danmakuOn;
    if (danmakuOn) {
      final context = _context;
      if (context != null) {
        status = DanmakuStatus.loading;
        notifyListeners();
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
    await _ensureRestored();
    if (_disposed) {
      return;
    }
    display = next;
    layout.settings = next;
    layout.reset();
    notifyListeners();
    await _writeSettings();
  }

  /// 手动搜索(匹配错误时切换剧集入口)。失败返回空列表。
  ///
  /// 优先 `/search/episodes`(带分集);官方 `/search/anime` 往往只有作品名,
  /// 展开后是空的,所以缺分集时再拉 `/bangumi/{id}`。
  Future<List<DanmakuAnime>> search(String keyword) async {
    final term = keyword.trim();
    if (term.isEmpty) {
      return const [];
    }
    if (!_canCallOfficialApi) {
      return const [];
    }
    _cancelActiveToken(_searchCancelToken);
    final token = CancelToken();
    _searchCancelToken = token;
    final generation = ++_searchGeneration;
    try {
      var results = await _client.searchEpisodes(
        _source,
        anime: term,
        episode: _context?.episodeIndex,
        cancelToken: token,
      );
      if (results.isEmpty) {
        results = await _client.searchAnime(_source, term, cancelToken: token);
      }
      results = await _ensureEpisodes(_source, results, cancelToken: token);
      if (_requestDropped(
        generation: generation,
        current: _searchGeneration,
        token: token,
      )) {
        return const [];
      }
      return results;
    } on DanmakuApiException catch (failure) {
      if (_requestDropped(
        generation: generation,
        current: _searchGeneration,
        token: token,
        failure: failure,
      )) {
        return const [];
      }
      try {
        final results = await _client.searchAnime(
          _source,
          term,
          cancelToken: token,
        );
        final filled = await _ensureEpisodes(
          _source,
          results,
          cancelToken: token,
        );
        if (_requestDropped(
          generation: generation,
          current: _searchGeneration,
          token: token,
        )) {
          return const [];
        }
        return filled;
      } on DanmakuApiException catch (fallbackFailure) {
        if (_requestDropped(
          generation: generation,
          current: _searchGeneration,
          token: token,
          failure: fallbackFailure,
        )) {
          return const [];
        }
        return const [];
      }
    }
  }

  /// 手动选择搜索结果的某一集:加载其弹幕并写入按剧记忆。
  Future<void> selectEpisode(DanmakuAnime anime, DanmakuEpisode episode) async {
    final context = _context;
    if (context == null) {
      return;
    }
    if (!_canCallOfficialApi) {
      status = DanmakuStatus.unreachable;
      notifyListeners();
      return;
    }
    final generation = _sessionGeneration;
    final cancelToken = _sessionCancelToken;
    status = DanmakuStatus.loading;
    notifyListeners();
    try {
      final loaded = await _client.fetchComments(
        _source,
        episode.episodeId,
        cancelToken: cancelToken,
      );
      if (_requestDropped(
        generation: generation,
        current: _sessionGeneration,
        token: cancelToken,
      )) {
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
      if (_requestDropped(
        generation: generation,
        current: _sessionGeneration,
        token: cancelToken,
        failure: failure,
      )) {
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
    final cancelToken = _sessionCancelToken;
    if (!_canCallOfficialApi) {
      status = DanmakuStatus.unreachable;
      statusDetail = null;
      notifyListeners();
      return;
    }
    final source = _source;
    var animeId = 0;
    var animeTitle = '';
    var episodeId = 0;
    var resolved = false;
    DanmakuApiException? lookupFailure;

    bool dropped([DanmakuApiException? failure]) {
      return _requestDropped(
        generation: generation,
        current: _sessionGeneration,
        token: cancelToken,
        failure: failure,
      );
    }

    // 三步彼此隔离:一步 API 失败记入 lookupFailure 后继续,取消则丢弃整链。
    // 1. 按剧记忆:同集直接复用,同剧后续集沿用动画并按集号对位。
    try {
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
          var animes = await _client.searchAnime(
            source,
            memory.animeTitle,
            cancelToken: cancelToken,
          );
          animes = await _ensureEpisodes(
            source,
            animes,
            cancelToken: cancelToken,
          );
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
    } on DanmakuApiException catch (failure) {
      if (dropped(failure)) {
        return;
      }
      lookupFailure = failure;
    }

    // 2. dandanplay 匹配:直连流先取前 16MB 哈希,不可得时按文件名降级。
    if (!resolved) {
      try {
        final streamUrl = context.streamUrl;
        var hash = '';
        if (streamUrl != null) {
          hash = await _hasher.hashOf(streamUrl) ?? '';
        }
        if (dropped()) {
          return;
        }
        final match = await _client.match(
          source,
          fileName: context.fileName ?? context.title ?? '',
          fileHash: hash,
          fileSize: context.fileSize,
          videoDuration: context.duration.inSeconds,
          matchMode: hash.isEmpty ? 'fileNameOnly' : 'hashAndFileName',
          cancelToken: cancelToken,
        );
        if (match.isMatched && match.matches.isNotEmpty) {
          final candidate = match.matches.first;
          animeId = candidate.animeId;
          animeTitle = candidate.animeTitle;
          episodeId = candidate.episodeId;
          resolved = true;
        }
      } on DanmakuApiException catch (failure) {
        if (dropped(failure)) {
          return;
        }
        lookupFailure = failure;
      }
    }

    // 3. 标题搜索降级:先 search/episodes(带分集),再 search/anime + bangumi。
    if (!resolved) {
      try {
        var keyword = context.seriesTitle?.trim() ?? '';
        if (keyword.isEmpty) {
          keyword = context.title?.trim() ?? '';
        }
        if (keyword.isEmpty) {
          keyword = context.fileName ?? '';
        }
        if (keyword.isNotEmpty) {
          var animes = await _client.searchEpisodes(
            source,
            anime: keyword,
            episode: context.episodeIndex,
            cancelToken: cancelToken,
          );
          if (animes.isEmpty) {
            animes = await _client.searchAnime(
              source,
              keyword,
              cancelToken: cancelToken,
            );
          }
          animes = await _ensureEpisodes(
            source,
            animes,
            cancelToken: cancelToken,
          );
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
      } on DanmakuApiException catch (failure) {
        if (dropped(failure)) {
          return;
        }
        lookupFailure = failure;
      }
    }

    if (!resolved) {
      if (dropped()) {
        return;
      }
      if (lookupFailure != null) {
        _handleLoadFailure(lookupFailure);
      } else {
        status = DanmakuStatus.noMatch;
        notifyListeners();
      }
      return;
    }

    try {
      final loaded = await _client.fetchComments(
        source,
        episodeId,
        cancelToken: cancelToken,
      );
      if (dropped()) {
        // 新会话已开启:旧会话结果不落地、不写记忆。
        return;
      }
      await _remember(context, animeId, animeTitle, episodeId);
      layout.comments = loaded;
      matchedTitle = animeTitle;
      status = DanmakuStatus.active;
      notifyListeners();
    } on DanmakuApiException catch (failure) {
      if (dropped(failure)) {
        return;
      }
      _handleLoadFailure(failure);
    }
  }

  void _handleLoadFailure(DanmakuApiException failure) {
    if (failure.kind == DanmakuApiFailureKind.cancelled) {
      return;
    }
    if (usesCustomSource &&
        (failure.kind == DanmakuApiFailureKind.unreachable ||
            failure.kind == DanmakuApiFailureKind.incompatible)) {
      // 连不上或根本不是 dandanplay 兼容包,才提示整站不可用。
      status = DanmakuStatus.customUnreachable;
      statusDetail = failure.toString();
    } else if (usesCustomSource) {
      // HTTP 500/429 等:搜索仍可用,不要把横幅钉死在「服务不可用」。
      status = DanmakuStatus.noMatch;
      statusDetail = failure.toString();
    } else {
      status = DanmakuStatus.unreachable;
      statusDetail = null;
    }
    notifyListeners();
  }

  void _cancelActiveToken(CancelToken? token) {
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  void _cancelSearchRequests() {
    _searchGeneration++;
    _cancelActiveToken(_searchCancelToken);
    _searchCancelToken = null;
  }

  bool _requestDropped({
    required int generation,
    required int current,
    CancelToken? token,
    DanmakuApiException? failure,
  }) {
    return _disposed ||
        generation != current ||
        (token?.isCancelled ?? false) ||
        failure?.kind == DanmakuApiFailureKind.cancelled;
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

  Future<List<DanmakuAnime>> _ensureEpisodes(
    DandanplaySource source,
    List<DanmakuAnime> animes, {
    CancelToken? cancelToken,
  }) async {
    final filled = <DanmakuAnime>[];
    for (final anime in animes.take(12)) {
      if (anime.episodes.isNotEmpty) {
        filled.add(anime);
        continue;
      }
      try {
        final detailed = await _client.fetchBangumi(
          source,
          anime.animeId,
          cancelToken: cancelToken,
        );
        filled.add(detailed ?? anime);
      } on DanmakuApiException catch (failure) {
        if (failure.kind == DanmakuApiFailureKind.cancelled) {
          rethrow;
        }
        filled.add(anime);
      }
    }
    return filled;
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

  Future<void> _primeSettings() async {
    await _ensureRestored();
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  Future<void> _ensureRestored() {
    return _restoreFuture ??= _restore();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelActiveToken(_sessionCancelToken);
    _cancelSearchRequests();
    super.dispose();
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
      final appId = settings.danmakuAppId?.trim();
      officialAppId = (appId == null || appId.isEmpty) ? null : appId;
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
          danmakuAppId: officialAppId,
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
