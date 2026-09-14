import 'dart:async';

import 'package:dio/dio.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// dandanplay API 失败类别。
enum DanmakuApiFailureKind {
  /// 网络不可达/超时(官方源场景应静默)。
  unreachable,

  /// 响应不是 dandanplay 兼容结构(自定义服务不兼容时给出明确提示)。
  incompatible,

  /// HTTP 层错误或业务包 success=false。
  http,
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
    this.custom = false,
  });

  /// 官方 dandanplay 开放 API,默认直连。
  static final DandanplaySource official = DandanplaySource._(
    baseUri: Uri.parse('https://api.dandanplay.net'),
  );

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

  /// 兼容服务的令牌经 Authorization: Bearer 头携带。
  Map<String, String> headers() {
    final value = token;
    if (value == null || value.isEmpty) {
      return const {};
    }
    return {'Authorization': 'Bearer $value'};
  }
}

/// dandanplay 开放 API 客户端(官方直连为默认,亦可指向兼容服务)。
///
/// 网络一律经注入的 [Dio](生产为独立实例,不携带 Emby 会话头;
/// 测试全部 fake,不真实拨号)。错误统一抛 [DanmakuApiException]。
class DandanplayClient {
  DandanplayClient({Dio? dio})
    : _dio =
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

  /// 匹配:POST /api/v2/match。
  ///
  /// [fileHash] 为前 16MB 的 MD5(不可得时传空串,服务端按文件名降级);
  /// [videoDuration] 为视频时长(分钟)。
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
  }) async {
    final body = <String, dynamic>{
      'fileName': fileName,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'videoDuration': videoDuration,
      'matchMode': 'hashAndFileName',
    };
    final data = await _requestJson(
      source,
      'POST',
      '/api/v2/match',
      body: body,
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
    String keyword,
  ) async {
    final term = keyword.trim();
    if (term.isEmpty) {
      return const [];
    }
    final data = await _requestJson(
      source,
      'GET',
      '/api/v2/search/anime',
      queryParameters: {'keyword': term},
    );
    final animes = <DanmakuAnime>[];
    final rawAnimes = data['animes'];
    if (rawAnimes is List) {
      for (final entry in rawAnimes) {
        if (entry is! Map) {
          continue;
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
        animes.add(
          DanmakuAnime(
            animeId: _asInt(entry['animeId']) ?? 0,
            animeTitle: entry['animeTitle']?.toString() ?? '',
            type: entry['type']?.toString(),
            episodes: episodes,
          ),
        );
      }
    }
    return animes;
  }

  /// 弹幕:GET /api/v2/comment/{episodeId}。
  ///
  /// 携带 server 时间戳([serverTimestamp],Unix 毫秒,兼容服务用于
  /// 增量/去重;官方源忽略未知查询参数)。
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
  }) async {
    final data = await _requestJson(
      source,
      'GET',
      '/api/v2/comment/$episodeId',
      queryParameters: {
        'withRelated': 'true',
        'chConvert': '1',
        if (serverTimestamp != null) 'ts': '$serverTimestamp',
      },
    );
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

  Future<Map<String, dynamic>> _requestJson(
    DandanplaySource source,
    String method,
    String apiPath, {
    Object? body,
    Map<String, String>? queryParameters,
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
        options: Options(
          method: method,
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
    // dandanplay 兼容判定:JSON 对象且带标准业务包字段。
    final dynamic data = response.data;
    if (data is! Map) {
      throw const DanmakuApiException(
        DanmakuApiFailureKind.incompatible,
        detail: '响应不是 JSON 对象',
      );
    }
    final map = Map<String, dynamic>.from(data);
    if (!map.containsKey('success') && !map.containsKey('errorCode')) {
      throw const DanmakuApiException(
        DanmakuApiFailureKind.incompatible,
        detail: '响应缺少 dandanplay 业务包字段',
      );
    }
    if (map['success'] == false) {
      throw DanmakuApiException(
        DanmakuApiFailureKind.http,
        statusCode: status,
        detail: map['errorMessage']?.toString() ?? '',
      );
    }
    return map;
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
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
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
