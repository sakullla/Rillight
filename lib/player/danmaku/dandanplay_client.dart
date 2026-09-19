import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// 评论包正文达到该长度(UTF-16 码元数,约 256 KiB)时改在 Isolate 中解析。
const int kDanmakuIsolateParseThreshold = 256 * 1024;

/// 响应不是 dandanplay 兼容结构([DanmakuApiFailureKind.incompatible])
/// 或业务包 success=false([DanmakuApiFailureKind.http])。
///
/// 由纯函数 [parseDanmakuComments] 与业务包判定抛出,不含 HTTP 状态码;
/// 调用方补上状态码映射为 [DanmakuApiException]。字段均可跨 Isolate 传递。
class DanmakuResponseFormatException implements Exception {
  const DanmakuResponseFormatException(this.kind, this.detail);

  final DanmakuApiFailureKind kind;
  final String detail;

  @override
  String toString() => 'DanmakuResponseFormatException(${kind.name}): $detail';
}

/// 解析 `/api/v2/comment/{id}` 的正文:`jsonDecode` → 业务包兼容判定 →
/// 逐条解析 `p`(时间,模式,颜色,…)与 `m` → 按时间排序。
///
/// 纯函数,无外部依赖,可在 [Isolate.run] 中执行。非 JSON 对象或缺业务包
/// 字段抛 [DanmakuResponseFormatException](incompatible);success=false 抛
/// http 类别并携带 errorMessage。
List<DanmakuComment> parseDanmakuComments(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    decoded = null;
  }
  final data = _unwrapEnvelope(decoded);
  final comments = <DanmakuComment>[];
  final rawComments = data['comments'];
  if (rawComments is List) {
    for (final entry in rawComments) {
      if (entry is! Map) {
        continue;
      }
      final p = entry['p']?.toString() ?? '';
      final parts = p.split(',');
      if (parts.length < 3) {
        continue;
      }
      final time = double.tryParse(parts[0]);
      final mode = int.tryParse(parts[1]);
      final color = int.tryParse(parts[2]);
      final text = entry['m']?.toString() ?? '';
      if (time == null || mode == null || color == null || text.isEmpty) {
        continue;
      }
      comments.add(
        DanmakuComment(
          cid: _asInt(entry['cid']) ?? 0,
          time: time,
          mode: mode,
          color: color,
          text: text,
        ),
      );
    }
  }
  comments.sort(DanmakuComment.compareByTime);
  return comments;
}

/// dandanplay 兼容判定:JSON 对象且带标准业务包字段
/// (兼容源评论包常只有 count/comments,没有 success/errorCode)。
Map<String, dynamic> _unwrapEnvelope(Object? data) {
  if (data is! Map) {
    throw const DanmakuResponseFormatException(
      DanmakuApiFailureKind.incompatible,
      '响应不是 JSON 对象',
    );
  }
  final map = Map<String, dynamic>.from(data);
  if (!map.containsKey('success') && !map.containsKey('errorCode')) {
    if (map['comments'] is List) {
      return map;
    }
    throw const DanmakuResponseFormatException(
      DanmakuApiFailureKind.incompatible,
      '响应缺少 dandanplay 业务包字段',
    );
  }
  if (map['success'] == false) {
    throw DanmakuResponseFormatException(
      DanmakuApiFailureKind.http,
      map['errorMessage']?.toString() ?? '',
    );
  }
  return map;
}

/// dandanplay API 失败类别。
enum DanmakuApiFailureKind {
  /// 网络不可达/超时(官方源场景应静默)。
  unreachable,

  /// 响应不是 dandanplay 兼容结构(自定义服务不兼容时给出明确提示)。
  incompatible,

  /// HTTP 层错误或业务包 success=false。
  http,

  /// 请求被取消;不得升级为服务不可达。
  cancelled,
}

class DanmakuApiException implements Exception {
  const DanmakuApiException(this.kind, {this.statusCode, this.detail = ''});

  final DanmakuApiFailureKind kind;
  final int? statusCode;
  final String detail;

  bool get isUnreachable => kind == DanmakuApiFailureKind.unreachable;

  @override
  String toString() {
    final where = statusCode == null ? '' : ' ($statusCode)';
    return 'DanmakuApiException(${kind.name}$where): $detail';
  }
}

/// 一个弹幕数据源:官方开放 API(默认)或兼容自建服务(含令牌)。
class DandanplaySource {
  const DandanplaySource._({
    required this.baseUri,
    this.token,
    this.appId,
    this.appSecret,
    this.custom = false,
  });

  /// 官方 dandanplay 开放 API。自 2025-01 起需 [appId]/[appSecret]。
  static final DandanplaySource official = DandanplaySource.officialWith();

  /// 官方源;凭证成对才写入 X-AppId / X-AppSecret(开放平台凭证模式)。
  factory DandanplaySource.officialWith({String? appId, String? appSecret}) {
    final id = appId?.trim();
    final secret = appSecret?.trim();
    return DandanplaySource._(
      baseUri: Uri.parse('https://api.dandanplay.net'),
      appId: (id == null || id.isEmpty) ? null : id,
      appSecret: (secret == null || secret.isEmpty) ? null : secret,
    );
  }

  /// 兼容自建服务(如 misaka_danmu_server),baseUri 可带路径前缀。
  factory DandanplaySource.custom(String baseUrl, [String? token]) {
    var parsed = Uri.tryParse(baseUrl.trim());
    if (parsed == null || (!parsed.hasScheme || parsed.host.isEmpty)) {
      parsed = Uri.tryParse('https://${baseUrl.trim()}');
    }
    if (parsed == null || parsed.host.isEmpty) {
      // 无法解析的地址按官方源处理,由调用方配置入口保证可解析。
      return official;
    }
    return DandanplaySource._(
      // port 为 0 时必须省略(显式 :0 不是合法目标地址)。
      baseUri: parsed.hasPort
          ? Uri(
              scheme: parsed.scheme,
              host: parsed.host,
              port: parsed.port,
              path: parsed.path,
            )
          : Uri(scheme: parsed.scheme, host: parsed.host, path: parsed.path),
      token: (token == null || token.trim().isEmpty) ? null : token.trim(),
      custom: true,
    );
  }

  final Uri baseUri;
  final String? token;
  final String? appId;
  final String? appSecret;
  final bool custom;

  bool get isCustom => custom;

  /// 源基地址 + API 路径(保留自定义服务的路径前缀,base path 替换语义)。
  Uri resolve(String apiPath) {
    var prefix = baseUri.path;
    while (prefix.endsWith('/')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return baseUri.replace(path: '$prefix$apiPath');
  }

  /// 自定义源用 Bearer;官方源用开放平台凭证头(不引入签名依赖)。
  Map<String, String> headers() {
    if (custom) {
      final value = token;
      if (value == null || value.isEmpty) {
        return const {};
      }
      return {'Authorization': 'Bearer $value'};
    }
    final id = appId;
    final secret = appSecret;
    if (id == null || id.isEmpty || secret == null || secret.isEmpty) {
      return const {};
    }
    return {'X-AppId': id, 'X-AppSecret': secret};
  }
}

/// dandanplay 开放 API 客户端(官方直连为默认,亦可指向兼容服务)。
///
/// 网络一律经注入的 [Dio](生产为独立实例,不携带 Emby 会话头;
/// 测试全部 fake,不真实拨号)。错误统一抛 [DanmakuApiException]。
class DandanplayClient {
  DandanplayClient({
    Dio? dio,
    this.isolateParseThreshold = kDanmakuIsolateParseThreshold,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 10),
               headers: const {'Accept': 'application/json'},
             ),
           );

  final Dio _dio;

  /// 评论包正文长度达到该值时经 [Isolate.run] 解析(测试可置 0 强制分支)。
  final int isolateParseThreshold;

  /// 匹配:POST /api/v2/match。
  ///
  /// [fileHash] 为前 16MB 的 MD5(不可得时传空串,并用 [matchMode] fileNameOnly);
  /// [videoDuration] 为视频时长(秒)。
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    final body = <String, dynamic>{
      'fileName': fileName,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'videoDuration': videoDuration,
      'matchMode': matchMode,
    };
    final data = await _requestJson(
      source,
      'POST',
      '/api/v2/match',
      body: body,
      cancelToken: cancelToken,
    );
    final matches = <DanmakuMatchCandidate>[];
    final rawMatches = data['matches'];
    if (rawMatches is List) {
      for (final entry in rawMatches) {
        if (entry is! Map) {
          continue;
        }
        matches.add(
          DanmakuMatchCandidate(
            animeId: _asInt(entry['animeId']) ?? 0,
            animeTitle: entry['animeTitle']?.toString() ?? '',
            episodeId: _asInt(entry['episodeId']) ?? 0,
            episodeTitle: entry['episodeTitle']?.toString() ?? '',
          ),
        );
      }
    }
    return DanmakuMatchResponse(
      isMatched: data['isMatched'] == true,
      matches: matches,
    );
  }

  /// 标题搜索:GET /api/v2/search/anime(降级匹配与手动搜索共用)。
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    final term = keyword.trim();
    if (term.isEmpty) {
      return const [];
    }
    final data = await _requestJson(
      source,
      'GET',
      '/api/v2/search/anime',
      queryParameters: {'keyword': term},
      cancelToken: cancelToken,
    );
    return _parseAnimes(data);
  }

  /// 手动匹配用的分集搜索:GET /api/v2/search/episodes。
  ///
  /// 官方 `/search/anime` 通常只返回作品、不含分集;此接口才带 episodeId,
  /// 否则手动搜索展开后是空的。
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    final term = anime.trim();
    if (term.isEmpty) {
      return const [];
    }
    final data = await _requestJson(
      source,
      'GET',
      '/api/v2/search/episodes',
      queryParameters: {
        'anime': term,
        if (episode != null && episode > 0) 'episode': '$episode',
      },
      cancelToken: cancelToken,
    );
    return _parseAnimes(data);
  }

  /// 作品详情:GET /api/v2/bangumi/{animeId},补全 search/anime 缺的分集。
  Future<DanmakuAnime?> fetchBangumi(
    DandanplaySource source,
    int animeId, {
    CancelToken? cancelToken,
  }) async {
    if (animeId <= 0) {
      return null;
    }
    final data = await _requestJson(
      source,
      'GET',
      '/api/v2/bangumi/$animeId',
      cancelToken: cancelToken,
    );
    final raw = data['bangumi'] ?? data;
    if (raw is! Map) {
      return null;
    }
    return _animeFromMap(Map<String, dynamic>.from(raw));
  }

  static List<DanmakuAnime> _parseAnimes(Map<String, dynamic> data) {
    final animes = <DanmakuAnime>[];
    final rawAnimes = data['animes'];
    if (rawAnimes is! List) {
      return animes;
    }
    for (final entry in rawAnimes) {
      if (entry is! Map) {
        continue;
      }
      final anime = _animeFromMap(Map<String, dynamic>.from(entry));
      if (anime != null) {
        animes.add(anime);
      }
    }
    return animes;
  }

  static DanmakuAnime? _animeFromMap(Map<String, dynamic> entry) {
    final animeId = _asInt(entry['animeId']) ?? 0;
    final title = entry['animeTitle']?.toString() ?? '';
    if (animeId <= 0 && title.isEmpty) {
      return null;
    }
    final episodes = <DanmakuEpisode>[];
    final rawEpisodes = entry['episodes'];
    if (rawEpisodes is List) {
      for (final episode in rawEpisodes) {
        if (episode is! Map) {
          continue;
        }
        episodes.add(
          DanmakuEpisode(
            episodeId: _asInt(episode['episodeId']) ?? 0,
            episodeTitle: episode['episodeTitle']?.toString() ?? '',
          ),
        );
      }
    }
    return DanmakuAnime(
      animeId: animeId,
      animeTitle: title,
      type: entry['type']?.toString(),
      episodes: episodes,
    );
  }

  /// 弹幕:GET /api/v2/comment/{episodeId}。
  ///
  /// 携带 server 时间戳([serverTimestamp],Unix 毫秒,兼容服务用于
  /// 增量/去重;官方源忽略未知查询参数)。
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
    CancelToken? cancelToken,
  }) async {
    // 以纯文本取回,解析(jsonDecode + 对象化 + 排序)集中在纯函数;
    // 大包在 Isolate 中完成,避免万条级评论阻塞 UI isolate。
    final response = await _request(
      source,
      'GET',
      '/api/v2/comment/$episodeId',
      queryParameters: {
        'withRelated': 'true',
        'chConvert': '1',
        if (serverTimestamp != null) 'ts': '$serverTimestamp',
      },
      cancelToken: cancelToken,
      responseType: ResponseType.plain,
    );
    final body = _bodyAsString(response.data);
    try {
      if (body.length >= isolateParseThreshold) {
        return await Isolate.run(() => parseDanmakuComments(body));
      }
      return parseDanmakuComments(body);
    } on DanmakuResponseFormatException catch (failure) {
      throw _mapFormat(failure, response.statusCode ?? 0);
    }
  }

  /// 兼容注入的 Dio 已做过解码的情况(Map/List/bytes),生产路径为 String。
  static String _bodyAsString(Object? data) {
    if (data == null) {
      return '';
    }
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      return utf8.decode(data, allowMalformed: true);
    }
    if (data is Map || data is List) {
      return jsonEncode(data);
    }
    return data.toString();
  }

  Future<Map<String, dynamic>> _requestJson(
    DandanplaySource source,
    String method,
    String apiPath, {
    Object? body,
    Map<String, String>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    final response = await _request(
      source,
      method,
      apiPath,
      body: body,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
    );
    try {
      return _unwrapEnvelope(response.data);
    } on DanmakuResponseFormatException catch (failure) {
      throw _mapFormat(failure, response.statusCode ?? 0);
    }
  }

  /// 业务包判定失败 → API 异常:业务失败携带 HTTP 状态码,不兼容不带。
  static DanmakuApiException _mapFormat(
    DanmakuResponseFormatException failure,
    int status,
  ) {
    return DanmakuApiException(
      failure.kind,
      statusCode: failure.kind == DanmakuApiFailureKind.http ? status : null,
      detail: failure.detail,
    );
  }

  /// 发请求并完成传输层/HTTP 状态映射,不解读业务包。
  Future<Response<dynamic>> _request(
    DandanplaySource source,
    String method,
    String apiPath, {
    Object? body,
    Map<String, String>? queryParameters,
    CancelToken? cancelToken,
    ResponseType? responseType,
  }) async {
    var uri = source.resolve(apiPath);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      uri = uri.replace(
        queryParameters: {...uri.queryParameters, ...queryParameters},
      );
    }
    final Response<dynamic> response;
    try {
      response = await _dio.requestUri<dynamic>(
        uri,
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          responseType: responseType,
          headers: {
            if (body != null) 'Content-Type': 'application/json',
            ...source.headers(),
          },
        ),
      );
    } on DioException catch (error) {
      throw _mapTransport(error);
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw DanmakuApiException(
        DanmakuApiFailureKind.http,
        statusCode: status,
        detail: 'HTTP $status',
      );
    }
    return response;
  }

  DanmakuApiException _mapTransport(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionError:
        return DanmakuApiException(
          DanmakuApiFailureKind.unreachable,
          detail: error.message ?? 'network unreachable',
        );
      case DioExceptionType.cancel:
        return DanmakuApiException(
          DanmakuApiFailureKind.cancelled,
          detail: error.message ?? 'cancelled',
        );
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        final status = error.response?.statusCode;
        if (status == null) {
          return DanmakuApiException(
            DanmakuApiFailureKind.unreachable,
            detail: error.message ?? 'request failed',
          );
        }
        return DanmakuApiException(
          DanmakuApiFailureKind.http,
          statusCode: status,
          detail: 'HTTP $status',
        );
    }
  }
}

int? _asInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw);
  }
  return null;
}
