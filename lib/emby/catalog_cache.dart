import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

/// 目录请求描述:path + 查询参数。
///
/// 查询参数即缓存 key 的一部分,[CatalogCache] 内部按键排序规范化后拼 key,
/// 因此同一请求(参数集合相同)在任意页面得到同一 key。
class CatalogRequest {
  const CatalogRequest(this.path, [this.query]);

  final String path;
  final Map<String, String>? query;
}

/// 缓存命中:原始响应 JSON 与写入时间。
class CatalogCacheHit {
  const CatalogCacheHit({required this.json, required this.storedAt});

  final Object json;
  final DateTime storedAt;
}

// ---------------------------------------------------------------------------
// 请求构造:与 [EmbyClient] 对应查询方法的 path 与参数(含插入顺序)一致,
// 保证经缓存层发出的请求与直连完全相同。
// ---------------------------------------------------------------------------

CatalogRequest catalogResumeRequest({
  required String userId,
  int limit = 24,
  int? startIndex,
  String? sortBy,
  String? sortOrder,
  String fields = EmbyClient.gridFields,
}) {
  return CatalogRequest('/Users/$userId/Items/Resume', {
    'Limit': '$limit',
    'MediaTypes': 'Video',
    'Fields': fields,
    'EnableImageTypes': EmbyClient.imageTypes,
    if (startIndex != null) 'StartIndex': '$startIndex',
    'SortBy': ?sortBy,
    'SortOrder': ?sortOrder,
  });
}

CatalogRequest catalogNextUpRequest({
  required String userId,
  int limit = 24,
  int? startIndex,
  String? sortBy,
  String? sortOrder,
  String fields = EmbyClient.gridFields,
}) {
  return CatalogRequest('/Shows/NextUp', {
    'UserId': userId,
    'Limit': '$limit',
    'Fields': fields,
    'EnableImageTypes': EmbyClient.imageTypes,
    if (startIndex != null) 'StartIndex': '$startIndex',
    'SortBy': ?sortBy,
    'SortOrder': ?sortOrder,
  });
}

CatalogRequest catalogViewsRequest({required String userId}) {
  return CatalogRequest('/Users/$userId/Views');
}

/// 筛选参数与 [EmbyClient.queryItems] 完全镜像(含插入顺序),
/// 由 request-parity 测试锁定。
CatalogRequest catalogItemsRequest({
  required String userId,
  String? parentId,
  String? searchTerm,
  String? includeItemTypes,
  bool recursive = false,
  int? limit,
  int? startIndex,
  String? sortBy,
  String? sortOrder,
  List<String>? filters,
  List<String>? genres,
  List<int>? years,
  String fields = EmbyClient.gridFields,
}) {
  return CatalogRequest('/Users/$userId/Items', {
    if (parentId != null && parentId.isNotEmpty) 'ParentId': parentId,
    'SearchTerm': ?searchTerm,
    if (includeItemTypes != null && includeItemTypes.isNotEmpty)
      'IncludeItemTypes': includeItemTypes,
    'Recursive': '$recursive',
    if (limit != null) 'Limit': '$limit',
    if (startIndex != null) 'StartIndex': '$startIndex',
    'Fields': fields,
    'SortBy': ?sortBy,
    'SortOrder': ?sortOrder,
    if (filters != null && filters.isNotEmpty) 'Filters': filters.join(','),
    if (genres != null && genres.isNotEmpty) 'Genres': genres.join(','),
    if (years != null && years.isNotEmpty) 'Years': years.join(','),
    'EnableImageTypes': EmbyClient.imageTypes,
  });
}

/// 与 [EmbyClient.searchByName] 同构:Movie,Series、递归、按标题升序。
CatalogRequest catalogSearchRequest({
  required String userId,
  required String searchTerm,
  int? startIndex,
  int limit = 50,
  String fields = EmbyClient.itemFields,
}) {
  return catalogItemsRequest(
    userId: userId,
    searchTerm: searchTerm,
    recursive: true,
    includeItemTypes: 'Movie,Series',
    limit: limit,
    startIndex: startIndex,
    sortBy: 'SortName',
    sortOrder: 'Ascending',
    fields: fields,
  );
}

CatalogRequest catalogSimilarRequest({
  required String userId,
  required String itemId,
  int? limit,
  String? sortBy,
  String? sortOrder,
  String fields = EmbyClient.gridFields,
}) {
  return CatalogRequest('/Items/$itemId/Similar', {
    'UserId': userId,
    if (limit != null) 'Limit': '$limit',
    'Fields': fields,
    'EnableImageTypes': EmbyClient.imageTypes,
    'SortBy': ?sortBy,
    'SortOrder': ?sortOrder,
  });
}

CatalogRequest catalogItemRequest({
  required String userId,
  required String itemId,
}) {
  return CatalogRequest('/Users/$userId/Items/$itemId', {
    'Fields': EmbyClient.itemFields,
    'EnableImageTypes': EmbyClient.detailImageTypes,
  });
}

// ---------------------------------------------------------------------------
// 响应解析
// ---------------------------------------------------------------------------

/// 解析 {Items, TotalRecordCount} 分页响应。
///
/// [EmbyClient.getJson] 会把数组响应包成 {'value': [...]},这里一并解包,
/// 与 EmbyClient._getItemList 对数组/Map 两种形态的容忍度一致。
EmbyItemPage parseCatalogPage(Object json) {
  var data = json;
  if (data is Map && data.length == 1 && data['value'] is List) {
    data = data['value']!;
  }
  return EmbyItemPage(
    items: parseEmbyItemList(data),
    totalRecordCount: parseEmbyTotalCount(data),
  );
}

/// 解析单条目详情响应。
EmbyItem parseCatalogItem(Object json) {
  if (json is Map) {
    return EmbyItem.fromJson(Map<String, dynamic>.from(json));
  }
  throw const EmbyException(EmbyFailureKind.unknown);
}

// ---------------------------------------------------------------------------
// 磁盘存储
// ---------------------------------------------------------------------------

/// 目录缓存磁盘存储抽象,便于测试替换。
abstract class CatalogDiskStore {
  Future<String?> read(String key);
  Future<void> write(String key, String body);
  Future<void> remove(String key);
  Future<void> clear();
}

/// 支持按前缀删除的磁盘存储能力(可选):WebSocket 通知等外部变更
/// 信号失效缓存前缀时,已有磁盘条目同步删除,避免残留过期数据。
/// 不实现该接口的存储静默跳过磁盘前缀删除,仍有 TTL 兜底。
abstract class PrefixCatalogDiskStore implements CatalogDiskStore {
  Future<void> removePrefix(String prefix);
}

Future<CatalogDiskStore> openDefaultCatalogDiskStore() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/rillight/catalog_cache');
  await directory.create(recursive: true);
  return FileCatalogDiskStore(directory);
}

/// 默认磁盘存储:文件名由缓存 key base64Url 编码而来,以文件修改时间近似
/// LRU,总占用超过上限时淘汰最久未写的条目。
class FileCatalogDiskStore implements PrefixCatalogDiskStore {
  FileCatalogDiskStore(
    this.directory, {
    this.limitBytes = CatalogCache.defaultDiskLimitBytes,
  });

  final Directory directory;
  final int limitBytes;

  static const String _fileSuffix = '.json';

  static String _fileName(String key) {
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return '$encoded$_fileSuffix';
  }

  File _fileFor(String key) {
    return File('${directory.path}${Platform.pathSeparator}${_fileName(key)}');
  }

  @override
  Future<String?> read(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }

  @override
  Future<void> write(String key, String body) async {
    await directory.create(recursive: true);
    await _fileFor(key).writeAsString(body, flush: true);
    await _trimToLimit();
  }

  @override
  Future<void> remove(String key) async {
    final file = _fileFor(key);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> clear() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
  }

  @override
  Future<void> removePrefix(String prefix) async {
    if (!await directory.exists()) {
      return;
    }
    try {
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith(_fileSuffix)) {
          continue;
        }
        final name = entity.uri.pathSegments.last;
        final key = _decodeKey(
          name.substring(0, name.length - _fileSuffix.length),
        );
        if (key != null && key.startsWith(prefix)) {
          try {
            await entity.delete();
          } catch (_) {
            // 单条删除失败留给下次再试。
          }
        }
      }
    } catch (_) {
      // 目录列举失败无碍,条目仍有 TTL 兜底。
    }
  }

  /// 文件名(去后缀)反解缓存 key;损坏文件名跳过。
  String? _decodeKey(String encoded) {
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return null;
    }
  }

  Future<void> _trimToLimit() async {
    final entries = <(File, int, DateTime)>[];
    var total = 0;
    try {
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith(_fileSuffix)) {
          continue;
        }
        final stat = await entity.stat();
        entries.add((entity, stat.size, stat.modified));
        total += stat.size;
      }
    } catch (_) {
      return;
    }
    if (total <= limitBytes) {
      return;
    }
    // 最久未写的先淘汰。
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    for (final entry in entries) {
      if (total <= limitBytes) {
        break;
      }
      total -= entry.$2;
      try {
        await entry.$1.delete();
      } catch (_) {
        // 淘汰失败留给下次再试。
      }
    }
  }
}

class _CatalogMemoryEntry {
  const _CatalogMemoryEntry({required this.json, required this.storedAt});

  final Object json;
  final DateTime storedAt;
}

/// 目录数据两层 JSON 缓存:
/// - key 为 `serverId|userId|path?规范化查询参数`,多服务器/多用户不串数据;
/// - 内存层为进程内 LRU(按条目数上限),磁盘层支撑重启先显;
/// - TTL 兜底(默认约 10 分钟,可调),过期条目不再作为先显数据;
/// - 「先显后刷」由调用方组合 [lookup] + [fetch] 完成:命中缓存立即渲染,
///   同时后台重拉,完成后无感更新;
/// - [fetch] 总是走网络(手动刷新即只调 fetch,天然绕过缓存),
///   成功后写穿两层;失败原样抛出,不动已有缓存;
/// - 磁盘读写失败静默降级为仅内存/直连,不影响正常显示。
class CatalogCache {
  CatalogCache({this.ttl = defaultTtl}) {
    // 启动即后台解析磁盘层,重启后的首次先显有尽可能大的机会命中。
    // 解析完成前的读写仅走内存(测试环境无平台通道,解析静默不完成)。
    unawaited(_ensureDiskStore());
  }

  /// TTL 兜底默认值:约 10 分钟。
  static const Duration defaultTtl = Duration(minutes: 10);

  /// 内存层条目数上限。
  static const int defaultMemoryLimitEntries = 64;

  /// 磁盘层总占用上限,默认约 32 MiB。
  static const int defaultDiskLimitBytes = 32 * 1024 * 1024;

  /// 先显数据的最大年龄,可调。
  Duration ttl;

  /// 测试注入时钟。
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  String? _serverId;
  String? _userId;
  final LinkedHashMap<String, _CatalogMemoryEntry> _memory = LinkedHashMap();

  CatalogDiskStore? _diskStore;
  bool _diskResolved = false;
  Future<CatalogDiskStore?>? _diskResolveFuture;

  /// 测试注入磁盘存储;传入 null 表示已解析且禁用磁盘层。
  @visibleForTesting
  void debugSetDiskStore(CatalogDiskStore? store) {
    _diskStore = store;
    _diskResolved = true;
    _diskResolveFuture = null;
  }

  /// 测试恢复默认配置(惰性创建文件实现)并清空内存。
  @visibleForTesting
  void resetConfiguration() {
    ttl = defaultTtl;
    clock = DateTime.now;
    _memory.clear();
    _serverId = null;
    _userId = null;
    debugSetDiskStore(null);
    _diskResolved = false;
  }

  bool get hasSession =>
      _serverId != null &&
      _serverId!.isNotEmpty &&
      _userId != null &&
      _userId!.isNotEmpty;

  /// 绑定会话(key 前缀)。会话切换时清内存层;磁盘层按 key 隔离,无需清。
  void attachSession({required String serverId, required String userId}) {
    if (_serverId == serverId && _userId == userId) {
      return;
    }
    _serverId = serverId;
    _userId = userId;
    _memory.clear();
  }

  void detachSession() {
    _serverId = null;
    _userId = null;
    _memory.clear();
  }

  String _key(CatalogRequest request) {
    final scope = hasSession ? '$_serverId|$_userId' : 'anon';
    final query = request.query;
    final normalized = query == null || query.isEmpty
        ? ''
        : (query.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
              .map(
                (entry) =>
                    '${Uri.encodeQueryComponent(entry.key)}='
                    '${Uri.encodeQueryComponent(entry.value)}',
              )
              .join('&');
    return '$scope|${request.path}${normalized.isEmpty ? '' : '?$normalized'}';
  }

  /// 先显读:内存命中即时返回;磁盘层已解析时读磁盘。TTL 过期视为未命中并移除。
  /// 未绑定会话时永远未命中(降级直连)。磁盘层尚未解析完成时本次仅走内存,
  /// 不阻塞页面加载。
  Future<CatalogCacheHit?> lookup(CatalogRequest request) async {
    if (!hasSession) {
      return null;
    }
    final key = _key(request);
    final now = clock();
    final cached = _memory.remove(key);
    if (cached != null) {
      if (now.isBefore(cached.storedAt.add(ttl))) {
        // 最近使用移到尾部,LRU 淘汰时从头部取最久未用条目。
        _memory[key] = cached;
        return CatalogCacheHit(json: cached.json, storedAt: cached.storedAt);
      }
    }
    if (!_diskResolved) {
      return null;
    }
    final store = _diskStore;
    if (store == null) {
      return null;
    }
    try {
      final raw = await store.read(key);
      if (raw == null) {
        return null;
      }
      final hit = _decodeEntry(raw, now);
      if (hit == null) {
        // 过期或损坏的磁盘条目惰性清除。
        unawaited(_removeDiskQuiet(store, key));
        return null;
      }
      _storeMemory(key, hit.json, hit.storedAt);
      return hit;
    } catch (_) {
      return null;
    }
  }

  /// 后台重拉:总是走网络(不读缓存),成功后写穿两层。
  /// 失败原样抛出,已有缓存不受影响。
  Future<Object> fetch(EmbyClient client, CatalogRequest request) async {
    final json = await client.getJson(
      request.path,
      queryParameters: request.query,
    );
    await write(request, json);
    return json;
  }

  /// 写穿:内存层立即写入;磁盘层已解析则写入,未解析则后台解析后补写,
  /// 不阻塞调用方。未绑定会话时跳过。
  Future<void> write(CatalogRequest request, Object json) async {
    if (!hasSession) {
      return;
    }
    final key = _key(request);
    final storedAt = clock();
    _storeMemory(key, json, storedAt);
    final body = jsonEncode({
      'storedAt': storedAt.toIso8601String(),
      'data': json,
    });
    if (_diskResolved) {
      final store = _diskStore;
      if (store == null) {
        return;
      }
      try {
        await store.write(key, body);
      } catch (_) {
        // 磁盘写入失败降级为仅内存缓存,不影响显示。
      }
      return;
    }
    unawaited(
      _ensureDiskStore().then((store) async {
        if (store == null) {
          return;
        }
        try {
          await store.write(key, body);
        } catch (_) {
          // 同上,静默降级。
        }
      }),
    );
  }

  CatalogCacheHit? _decodeEntry(String raw, DateTime now) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final storedAt = DateTime.tryParse(decoded['storedAt']?.toString() ?? '');
      final data = decoded['data'];
      if (storedAt == null || data == null) {
        return null;
      }
      if (!now.isBefore(storedAt.add(ttl))) {
        return null;
      }
      return CatalogCacheHit(json: data, storedAt: storedAt);
    } catch (_) {
      return null;
    }
  }

  /// 失效当前会话(key 前缀 `serverId|userId|`)的全部缓存。
  ///
  /// 供 WebSocket 通知等外部变更信号使用:通知不含变更细节,
  /// 失效后以重新拉取结果为准。未绑定会话时为无操作。
  Future<void> invalidateSession() async {
    if (!hasSession) {
      return;
    }
    await invalidatePrefix('$_serverId|$_userId|');
  }

  /// 失效 key 以 [prefix] 开头的条目:内存层同步移除,磁盘层尽力删除
  /// (存储不支持前缀删除或删除失败时静默,仍有 TTL 兜底)。
  Future<void> invalidatePrefix(String prefix) async {
    _memory.removeWhere((key, _) => key.startsWith(prefix));
    if (!_diskResolved) {
      // 磁盘层尚未解析:解析完成后补删,不阻塞调用方。
      unawaited(
        _ensureDiskStore().then((store) async {
          if (store is! PrefixCatalogDiskStore) {
            return;
          }
          try {
            await store.removePrefix(prefix);
          } catch (_) {
            // 静默降级。
          }
        }),
      );
      return;
    }
    final store = _diskStore;
    if (store is! PrefixCatalogDiskStore) {
      return;
    }
    try {
      await store.removePrefix(prefix);
    } catch (_) {
      // 静默降级。
    }
  }

  void _storeMemory(String key, Object json, DateTime storedAt) {
    _memory[key] = _CatalogMemoryEntry(json: json, storedAt: storedAt);
    while (_memory.length > defaultMemoryLimitEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<CatalogDiskStore?> _ensureDiskStore() {
    if (_diskResolved) {
      return Future<CatalogDiskStore?>.value(_diskStore);
    }
    return _diskResolveFuture ??= openDefaultCatalogDiskStore()
        .then<CatalogDiskStore?>((store) {
          _diskStore = store;
          return store;
        })
        .catchError((Object _) {
          // 磁盘层不可用(如测试环境)时降级为仅内存缓存。
          return null;
        })
        .whenComplete(() {
          _diskResolved = true;
          _diskResolveFuture = null;
        });
  }

  Future<void> _removeDiskQuiet(CatalogDiskStore store, String key) async {
    try {
      await store.remove(key);
    } catch (_) {
      // 清理失败无碍,下次读取仍按过期处理。
    }
  }
}
