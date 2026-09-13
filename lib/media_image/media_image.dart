import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.item,
    this.width,
    this.height,
    this.preferBackdrop = false,
    this.preferThumb = false,
    this.maxWidth,
  });

  final EmbyItem item;
  final double? width;
  final double? height;
  final bool preferBackdrop;
  final bool preferThumb;
  final int? maxWidth;

  /// 清空内存与磁盘两级缓存,仅测试使用。
  @visibleForTesting
  static void debugClearCache() {
    MediaImageCache.instance.clear();
  }

  /// 仅清空进程内内存层(保留磁盘层),模拟应用重启,仅测试使用。
  @visibleForTesting
  static void debugClearMemory() {
    MediaImageCache.instance.clearMemory();
  }

  /// 恢复缓存默认配置(内存上限/负缓存 TTL/时钟/磁盘存储注入),仅测试使用。
  @visibleForTesting
  static void debugResetCacheConfiguration() {
    MediaImageCache.instance.resetConfiguration();
  }

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _LoadedImage {
  const _LoadedImage({required this.bytes, required this.type});

  final Uint8List bytes;
  final String type;
}

class _MediaImageState extends State<MediaImage> {
  Future<_LoadedImage?>? _future;

  List<ItemImageRef> get _candidates {
    return widget.item.imageCandidates(
      preferBackdrop: widget.preferBackdrop,
      preferThumb: widget.preferThumb,
    );
  }

  bool get _hasImageSource => _candidates.isNotEmpty;

  int get _requestMaxWidth => widget.maxWidth ?? widget.width?.round() ?? 280;

  /// 缓存 key 的服务器维度:多服务器之间不串图。
  String get _serverId => AuthScope.of(context).session?.server.id ?? '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasImageSource) {
      _future ??= _load();
    }
  }

  @override
  void didUpdateWidget(MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 网格滚动时 LayoutBuilder 宽度会抖 1px;已指定 maxWidth 则不重拉。
    final maxWidthChanged = oldWidget.maxWidth != widget.maxWidth;
    final widthChanged =
        widget.maxWidth == null && oldWidget.width != widget.width;
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.primaryImageTag != widget.item.primaryImageTag ||
        oldWidget.item.thumbImageTag != widget.item.thumbImageTag ||
        oldWidget.item.backdropImageTag != widget.item.backdropImageTag ||
        oldWidget.item.parentBackdropItemId !=
            widget.item.parentBackdropItemId ||
        oldWidget.item.parentBackdropImageTag !=
            widget.item.parentBackdropImageTag ||
        oldWidget.item.seriesPrimaryImageTag !=
            widget.item.seriesPrimaryImageTag ||
        oldWidget.preferBackdrop != widget.preferBackdrop ||
        oldWidget.preferThumb != widget.preferThumb ||
        maxWidthChanged ||
        widthChanged) {
      _future = _hasImageSource ? _load() : null;
    }
  }

  _LoadedImage? _peekLoaded() {
    // 只看首选候选。后面的剧 Backdrop 往往已经在缓存里,跳过去会让换集时
    // 背景永远停在同一张剧图,连本集 Thumb 都不拉。
    if (_candidates.isEmpty) {
      return null;
    }
    final candidate = _candidates.first;
    final bytes = MediaImageCache.instance.peek(
      serverId: _serverId,
      itemId: candidate.itemId,
      type: candidate.type,
      tag: candidate.tag,
      maxWidth: _requestMaxWidth,
    );
    if (bytes != null && bytes.isNotEmpty) {
      return _LoadedImage(bytes: bytes, type: candidate.type);
    }
    return null;
  }

  Future<_LoadedImage?> _load() async {
    final client = AuthScope.of(context).client;
    final serverId = _serverId;
    final maxWidth = _requestMaxWidth;
    for (final candidate in _candidates) {
      final bytes = await MediaImageCache.instance.load(
        serverId: serverId,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
        fetch: () async {
          try {
            final data = await client.getItemImage(
              candidate.itemId,
              type: candidate.type,
              tag: candidate.tag,
              maxWidth: maxWidth,
            );
            if (data.isEmpty) {
              return null;
            }
            return Uint8List.fromList(data);
          } catch (_) {
            return null;
          }
        },
      );
      if (bytes != null && bytes.isNotEmpty) {
        return _LoadedImage(bytes: bytes, type: candidate.type);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (!_hasImageSource) {
      return PosterPlaceholder(width: width, height: height);
    }
    final cached = _peekLoaded();
    if (cached != null) {
      return _paint(context, cached, width, height);
    }
    return FutureBuilder<_LoadedImage?>(
      future: _future,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return _loadingBox(context, width, height);
        }
        if (loaded == null || loaded.bytes.isEmpty) {
          return PosterPlaceholder(width: width, height: height);
        }
        return _paint(context, loaded, width, height);
      },
    );
  }

  Widget _paint(
    BuildContext context,
    _LoadedImage loaded,
    double? width,
    double? height,
  ) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final displayWidth = width == null || width <= 0
        ? null
        : math.max(1, (width * dpr).round());
    final cacheWidth = displayWidth == null
        ? null
        : math.min(displayWidth, _requestMaxWidth);
    return Image.memory(
      loaded.bytes,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return PosterPlaceholder(width: width, height: height);
      },
    );
  }

  Widget _loadingBox(BuildContext context, double? width, double? height) {
    return SkeletonBlock(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(AppRadii.sm),
    );
  }
}

/// 章节图统一经 [MediaImageCache] 管道加载,与海报/剧照共用内存+磁盘两级缓存,
/// 重复进入详情页不再重复请求。
Future<Uint8List?> loadChapterImage(
  BuildContext context, {
  required String itemId,
  required int index,
  String? tag,
  int maxWidth = 160,
}) async {
  if (tag == null || tag.isEmpty) {
    return Future<Uint8List?>.value();
  }
  final auth = AuthScope.of(context);
  return MediaImageCache.instance.load(
    serverId: auth.session?.server.id ?? '',
    itemId: itemId,
    type: 'Chapter',
    variant: '$index',
    tag: tag,
    maxWidth: maxWidth,
    fetch: () async {
      try {
        final data = await auth.client.getChapterImage(
          itemId,
          index: index,
          tag: tag,
          maxWidth: maxWidth,
        );
        if (data.isEmpty) {
          return null;
        }
        return Uint8List.fromList(data);
      } catch (_) {
        return null;
      }
    },
  );
}

/// 图片字节两级缓存:
/// - 第一级为进程内 LRU,按字节量上限(默认约 256 MiB,可调)淘汰最久未用条目;
/// - 第二级为磁盘缓存,目录 `ApplicationSupport/rillight/image_cache/`,
///   总占用超过上限时按 LRU 回收;
/// - 缓存 key 为 `serverId|itemId|type|tag|variant|maxWidth`,tag 变化即换 key,
///   服务器换图后自动重新拉取;
/// - 负缓存带 TTL,失败结果不再被永久吞掉;
/// - 磁盘写入失败时降级为仅内存缓存,不影响显示。
/// 同时限制并发拉取,网格快滑时不会一次打几十张把 UI 打卡。
class MediaImageCache {
  MediaImageCache._();

  static final MediaImageCache instance = MediaImageCache._();

  /// 内存层字节量上限,默认约 256 MiB。
  static const int defaultMemoryLimitBytes = 256 * 1024 * 1024;

  /// 磁盘层总占用上限,默认约 512 MiB。
  static const int defaultDiskLimitBytes = 512 * 1024 * 1024;

  /// 负缓存(拉取失败)的 TTL。
  static const Duration defaultNegativeTtl = Duration(seconds: 30);

  static const int _maxConcurrentFetches = 12;

  int memoryLimitBytes = defaultMemoryLimitBytes;
  Duration negativeTtl = defaultNegativeTtl;
  DateTime Function() clock = DateTime.now;

  final LinkedHashMap<String, Uint8List> _bytes = LinkedHashMap();
  int _bytesTotal = 0;
  final Map<String, DateTime> _misses = {};
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _activeFetches = 0;
  final List<Completer<void>> _waiters = [];

  MediaImageDiskStore? _diskStore;
  bool _diskResolved = false;
  Future<MediaImageDiskStore?>? _diskResolveFuture;

  static String key({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
  }) {
    return '$serverId|$itemId|$type|${tag ?? ''}|$variant|$maxWidth';
  }

  /// 测试注入磁盘存储;传入 null 恢复为默认(惰性创建文件实现)。
  @visibleForTesting
  void debugSetDiskStore(MediaImageDiskStore? store) {
    _diskStore = store;
    _diskResolved = store != null;
    _diskResolveFuture = null;
  }

  /// 恢复默认配置,仅测试使用。
  @visibleForTesting
  void resetConfiguration() {
    memoryLimitBytes = defaultMemoryLimitBytes;
    negativeTtl = defaultNegativeTtl;
    clock = DateTime.now;
    debugSetDiskStore(null);
  }

  Uint8List? peek({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
  }) {
    return _touch(
      key(
        serverId: serverId,
        itemId: itemId,
        type: type,
        tag: tag,
        variant: variant,
        maxWidth: maxWidth,
      ),
    );
  }

  Future<Uint8List?> load({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
    required Future<Uint8List?> Function() fetch,
  }) {
    final cacheKey = key(
      serverId: serverId,
      itemId: itemId,
      type: type,
      tag: tag,
      variant: variant,
      maxWidth: maxWidth,
    );
    final cached = _touch(cacheKey);
    if (cached != null) {
      return Future<Uint8List?>.value(cached);
    }
    final missExpiry = _misses[cacheKey];
    if (missExpiry != null) {
      if (clock().isBefore(missExpiry)) {
        return Future<Uint8List?>.value(null);
      }
      _misses.remove(cacheKey);
    }
    return _inflight.putIfAbsent(cacheKey, () async {
      await _acquire();
      try {
        if (_diskResolved) {
          final disk = await _readDisk(cacheKey);
          if (disk != null && disk.isNotEmpty) {
            _storeBytes(cacheKey, disk);
            return disk;
          }
        } else {
          // 首次使用时后台解析磁盘层;解析完成前本次仅走内存+网络。
          unawaited(_ensureDiskStore());
        }
        final bytes = await fetch();
        if (bytes != null && bytes.isNotEmpty) {
          _storeBytes(cacheKey, bytes);
          if (_diskResolved) {
            await _writeDisk(cacheKey, bytes);
          } else {
            unawaited(
              _ensureDiskStore().then((_) => _writeDisk(cacheKey, bytes)),
            );
          }
          return bytes;
        }
        _recordMiss(cacheKey);
        return null;
      } finally {
        _release();
        _inflight.remove(cacheKey);
      }
    });
  }

  Uint8List? _touch(String cacheKey) {
    final cached = _bytes.remove(cacheKey);
    if (cached == null) {
      return null;
    }
    // 最近使用移到尾部,LRU 淘汰时从头部取最久未用条目。
    _bytes[cacheKey] = cached;
    return cached;
  }

  void _storeBytes(String cacheKey, Uint8List bytes) {
    final previous = _bytes.remove(cacheKey);
    if (previous != null) {
      _bytesTotal -= previous.length;
    }
    _bytes[cacheKey] = bytes;
    _bytesTotal += bytes.length;
    while (_bytesTotal > memoryLimitBytes && _bytes.length > 1) {
      final eldest = _bytes.remove(_bytes.keys.first)!;
      _bytesTotal -= eldest.length;
    }
  }

  void _recordMiss(String cacheKey) {
    _misses[cacheKey] = clock().add(negativeTtl);
    // 顺手清理过期负缓存,长会话下 Map 不无限膨胀。
    final now = clock();
    _misses.removeWhere((_, expiry) => !now.isBefore(expiry));
  }

  Future<MediaImageDiskStore?> _ensureDiskStore() {
    if (_diskResolved) {
      return Future<MediaImageDiskStore?>.value(_diskStore);
    }
    return _diskResolveFuture ??= openDefaultMediaImageDiskStore()
        .then<MediaImageDiskStore?>((store) {
          _diskStore = store;
          return store;
        })
        .catchError((Object _) {
          // 磁盘层不可用时降级为仅内存缓存。
          return null;
        })
        .whenComplete(() {
          _diskResolved = true;
          _diskResolveFuture = null;
        });
  }

  Future<Uint8List?> _readDisk(String cacheKey) async {
    final store = _diskStore;
    if (store == null) {
      return null;
    }
    try {
      return await store.read(cacheKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String cacheKey, Uint8List bytes) async {
    final store = _diskStore;
    if (store == null) {
      return;
    }
    try {
      await store.write(cacheKey, bytes);
    } catch (_) {
      // 磁盘写入失败降级为仅内存缓存,不影响显示。
    }
  }

  Future<void> _acquire() async {
    if (_activeFetches < _maxConcurrentFetches) {
      _activeFetches++;
      return;
    }
    final gate = Completer<void>();
    _waiters.add(gate);
    await gate.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _activeFetches--;
    }
  }

  /// 清空内存与磁盘两层缓存。
  void clear() {
    clearMemory();
    if (_diskResolved) {
      final store = _diskStore;
      if (store != null) {
        unawaited(() async {
          try {
            await store.clear();
          } catch (_) {}
        }());
      }
    }
  }

  /// 仅清空进程内内存层,保留磁盘层(模拟应用重启)。
  void clearMemory() {
    _bytes.clear();
    _bytesTotal = 0;
    _misses.clear();
    _inflight.clear();
    final pending = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    _activeFetches = 0;
    for (final waiter in pending) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

/// 图片磁盘缓存存储抽象,便于测试替换。
abstract class MediaImageDiskStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List bytes);
  Future<void> remove(String key);
  Future<void> clear();
}

Future<MediaImageDiskStore> openDefaultMediaImageDiskStore({
  int limitBytes = MediaImageCache.defaultDiskLimitBytes,
}) async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/rillight/image_cache');
  await directory.create(recursive: true);
  return FileMediaImageDiskStore(directory, limitBytes: limitBytes);
}

class _DiskEntry {
  const _DiskEntry({
    required this.file,
    required this.size,
    required this.lastUsed,
  });

  final File file;
  final int size;
  final DateTime lastUsed;

  _DiskEntry withLastUsed(DateTime value) {
    return _DiskEntry(file: file, size: size, lastUsed: value);
  }
}

/// 默认磁盘缓存:文件名由缓存 key base64Url 编码而来,以文件修改时间
/// 近似 LRU(读取时刷新 mtime),总占用超过上限时淘汰最久未使用的条目。
class FileMediaImageDiskStore implements MediaImageDiskStore {
  FileMediaImageDiskStore(
    this.directory, {
    this.limitBytes = MediaImageCache.defaultDiskLimitBytes,
  });

  final Directory directory;
  final int limitBytes;

  static const String _fileSuffix = '.img';

  Map<String, _DiskEntry>? _index;
  int _totalBytes = 0;

  static String _fileName(String key) {
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return '$encoded$_fileSuffix';
  }

  Future<Map<String, _DiskEntry>> _ensureIndex() async {
    final index = _index;
    if (index != null) {
      return index;
    }
    final entries = <String, _DiskEntry>{};
    var total = 0;
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) {
          continue;
        }
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith(_fileSuffix)) {
          continue;
        }
        try {
          final stat = await entity.stat();
          entries[name] = _DiskEntry(
            file: entity,
            size: stat.size,
            lastUsed: stat.modified,
          );
          total += stat.size;
        } catch (_) {
          // 单个条目损坏跳过,不影响其余缓存。
        }
      }
    } catch (_) {
      // 目录损坏时整体重建。
      await _rebuild();
      entries.clear();
      total = 0;
    }
    _index = entries;
    _totalBytes = total;
    return entries;
  }

  Future<void> _rebuild() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      await directory.create(recursive: true);
    } catch (_) {
      // 重建失败则本会话禁用磁盘层(上层已降级为仅内存)。
    }
  }

  @override
  Future<Uint8List?> read(String key) async {
    final entries = await _ensureIndex();
    final name = _fileName(key);
    final entry = entries[name];
    if (entry == null) {
      return null;
    }
    try {
      final bytes = await entry.file.readAsBytes();
      final now = DateTime.now();
      entries[name] = entry.withLastUsed(now);
      // 读取即视为最近使用,尽力刷新 mtime 供 LRU 回收参考。
      unawaited(entry.file.setLastModified(now).catchError((_) => now));
      return bytes;
    } catch (_) {
      entries.remove(name);
      _totalBytes = math.max(0, _totalBytes - entry.size);
      unawaited(_deleteQuietly(entry.file));
      return null;
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    final entries = await _ensureIndex();
    final name = _fileName(key);
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    final previous = entries[name];
    if (previous != null) {
      _totalBytes = math.max(0, _totalBytes - previous.size);
    }
    entries[name] = _DiskEntry(
      file: file,
      size: bytes.length,
      lastUsed: DateTime.now(),
    );
    _totalBytes += bytes.length;
    await _evict(entries, keep: name);
  }

  Future<void> _evict(Map<String, _DiskEntry> entries, {String? keep}) async {
    while (_totalBytes > limitBytes) {
      String? oldestName;
      _DiskEntry? oldest;
      for (final entry in entries.entries) {
        if (entry.key == keep) {
          continue;
        }
        if (oldest == null || entry.value.lastUsed.isBefore(oldest.lastUsed)) {
          oldestName = entry.key;
          oldest = entry.value;
        }
      }
      if (oldestName == null || oldest == null) {
        break;
      }
      entries.remove(oldestName);
      _totalBytes = math.max(0, _totalBytes - oldest.size);
      await _deleteQuietly(oldest.file);
    }
  }

  @override
  Future<void> remove(String key) async {
    final entries = await _ensureIndex();
    final name = _fileName(key);
    final entry = entries.remove(name);
    if (entry == null) {
      return;
    }
    _totalBytes = math.max(0, _totalBytes - entry.size);
    await _deleteQuietly(entry.file);
  }

  @override
  Future<void> clear() async {
    final index = _index;
    if (index == null) {
      // 索引尚未建立时直接重建目录。
      await _rebuild();
      _index = {};
      _totalBytes = 0;
      return;
    }
    final files = [for (final entry in index.values) entry.file];
    index.clear();
    _totalBytes = 0;
    for (final file in files) {
      await _deleteQuietly(file);
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
