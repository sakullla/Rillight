import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';

/// Flutter [ImageCache] 解码图条目上限。与 [MediaImageCache] 的 JPEG 字节层
/// 分开计数,两边都按低配内存留余量,避免空闲时各吃 256 MiB。
const int kPaintingImageCacheMaxEntries = 400;

/// 海报请求宽度：按格子的物理像素取整，上限与桌面海报的 280 对齐。
int catalogPosterMaxWidth(double logicalWidth, double devicePixelRatio) {
  final physical = logicalWidth * devicePixelRatio;
  return physical.round().clamp(160, 280);
}

/// Flutter [ImageCache] 解码像素上限,约 64 MiB。
const int kPaintingImageCacheMaxBytes = 64 * 1024 * 1024;

/// 独立播放进程只要剧集缩略图,解码缓存再收一档。
const int kPlayerProcessImageCacheMaxEntries = 80;
const int kPlayerProcessImageCacheMaxBytes = 16 * 1024 * 1024;

/// 背景图请求宽度下限:窄窗口仍拉够一张能铺满的底图。
const int kMediaBackdropMinRequestWidth = 640;

/// 背景图请求宽度上限:按窗口像素取值,但不超过此解码预算。
const int kMediaBackdropMaxRequestWidth = 1280;

/// 把 Flutter 解码缓存收到低配可承受的上限。启动时调用一次。
void configurePaintingImageCache({bool playerProcess = false}) {
  final cache = PaintingBinding.instance.imageCache;
  if (playerProcess) {
    cache.maximumSize = kPlayerProcessImageCacheMaxEntries;
    cache.maximumSizeBytes = kPlayerProcessImageCacheMaxBytes;
    MediaImageCache.instance.memoryLimitBytes =
        kPlayerProcessImageCacheMaxBytes;
    return;
  }
  cache.maximumSize = kPaintingImageCacheMaxEntries;
  cache.maximumSizeBytes = kPaintingImageCacheMaxBytes;
}

/// 背景图按当前窗口逻辑宽 × DPR 取整,再夹在
/// [kMediaBackdropMinRequestWidth]–[kMediaBackdropMaxRequestWidth]。
/// 不按机型档位猜分辨率,只跟眼前这个窗口走。
int mediaBackdropRequestWidth({
  required double layoutWidth,
  required double devicePixelRatio,
}) {
  final px = (layoutWidth * devicePixelRatio).round();
  if (px < kMediaBackdropMinRequestWidth) {
    return kMediaBackdropMinRequestWidth;
  }
  if (px > kMediaBackdropMaxRequestWidth) {
    return kMediaBackdropMaxRequestWidth;
  }
  return px;
}

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.item,
    this.width,
    this.height,
    this.preferBackdrop = false,
    this.preferThumb = false,
    this.preferParentBackdrop = false,
    this.maxWidth,
    this.alignment = Alignment.center,
  });

  final EmbyItem item;
  final double? width;
  final double? height;
  final bool preferBackdrop;
  final bool preferThumb;

  /// 优先所属剧集的 Backdrop(单集 hero 底图),见 [EmbyItem.imageCandidates]。
  final bool preferParentBackdrop;
  final int? maxWidth;
  final Alignment alignment;

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
  const _LoadedImage({
    required this.bytes,
    required this.type,
    required this.cacheKey,
  });

  final Uint8List bytes;
  final String type;
  final String cacheKey;
}

class _MediaImageState extends State<MediaImage> {
  Future<_LoadedImage?>? _future;
  int _loadGeneration = 0;
  ScrollPosition? _observedScroll;
  bool _frameWakeQueued = false;
  Completer<void>? _layoutWake;

  List<ItemImageRef> get _candidates {
    return widget.item.imageCandidates(
      preferBackdrop: widget.preferBackdrop,
      preferThumb: widget.preferThumb,
      preferParentBackdrop: widget.preferParentBackdrop,
    );
  }

  bool get _hasImageSource => _candidates.isNotEmpty;

  int get _requestMaxWidth => widget.maxWidth ?? widget.width?.round() ?? 280;

  /// 缓存 key 的服务器维度:多服务器之间不串图。
  String get _serverId => AuthScope.maybeOf(context)?.session?.server.id ?? '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _trackScrollable();
    if (_hasImageSource && AuthScope.maybeOf(context) != null) {
      _future ??= _load();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _observedScroll?.removeListener(_onObservedScroll);
    _observedScroll = null;
    final wake = _layoutWake;
    _layoutWake = null;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
    super.dispose();
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
        oldWidget.preferParentBackdrop != widget.preferParentBackdrop ||
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
    final maxWidth = _requestMaxWidth;
    final cacheKey = MediaImageCache.key(
      serverId: _serverId,
      itemId: candidate.itemId,
      type: candidate.type,
      tag: candidate.tag,
      maxWidth: maxWidth,
    );
    final bytes = MediaImageCache.instance.peek(
      serverId: _serverId,
      itemId: candidate.itemId,
      type: candidate.type,
      tag: candidate.tag,
      maxWidth: maxWidth,
    );
    if (bytes != null && bytes.isNotEmpty) {
      return _LoadedImage(
        bytes: bytes,
        type: candidate.type,
        cacheKey: cacheKey,
      );
    }
    return null;
  }

  /// 本帧 layout 结束后才能判断格子在不在视口里。
  /// didChangeDependencies 里启动的 future 要先让出一次,微任务才落在布局之后。
  Future<void> _waitUntilLaidOut() async {
    await Future<void>.value();
    if (!mounted || _viewportHit() != null) {
      return;
    }
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!done.isCompleted) {
        done.complete();
      }
    });
    await done.future;
  }

  /// 滚动位置只在依赖变化时订阅。异步续体里再调 [Scrollable.maybeOf] 会登记继承依赖。
  void _trackScrollable() {
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _observedScroll)) {
      return;
    }
    _observedScroll?.removeListener(_onObservedScroll);
    _observedScroll = position;
    position?.addListener(_onObservedScroll);
  }

  void _onObservedScroll() {
    if (_frameWakeQueued || !mounted) {
      return;
    }
    _frameWakeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameWakeQueued = false;
      final wake = _layoutWake;
      if (wake != null && !wake.isCompleted) {
        wake.complete();
      }
    });
  }

  Future<void> _waitForViewportMove(_PosterLoadTurn turn) {
    final wake = Completer<void>();
    _layoutWake = wake;
    turn.done.future.whenComplete(() {
      if (!wake.isCompleted) {
        wake.complete();
      }
    });
    return wake.future;
  }

  /// true 在视口内,false 在滚动缓存区,null 还没有尺寸。
  /// 不在滚动视口里(详情头图等)视为在屏内。
  bool? _viewportHit() {
    if (!mounted) {
      return null;
    }
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    final viewport = RenderAbstractViewport.maybeOf(object);
    if (viewport == null) {
      return true;
    }
    if (viewport is! RenderBox) {
      return null;
    }
    final box = viewport as RenderBox;
    if (!box.attached || !box.hasSize) {
      return null;
    }
    final rect = MatrixUtils.transformRect(
      object.getTransformTo(box),
      Offset.zero & object.size,
    );
    return rect.overlaps(Offset.zero & box.size);
  }

  Future<_LoadedImage?> _load() async {
    final generation = ++_loadGeneration;
    bool current() => mounted && generation == _loadGeneration;
    // 内存命中立刻返回,回滑已看过的海报不闪骨架、也不等停稳。
    final peeked = _peekLoaded();
    if (peeked != null) {
      return peeked;
    }
    final cache = MediaImageCache.instance;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!current()) {
          return null;
        }
        final again = _peekLoaded();
        if (again != null) {
          return again;
        }
        await _waitUntilLaidOut();
        if (!current()) {
          return null;
        }
        final turn = cache._claimPosterLoadTurn(
          () => current() && _viewportHit() == true,
        );
        var probing = false;
        var probed = false;
        var ready = false;
        try {
          while (current() && !turn.isReleased) {
            // 视口内的磁盘命中不等滚动空闲。滑进视口时再探一次。
            if (!probed && _viewportHit() == true) {
              probed = true;
              probing = true;
              cache._beginViewportDiskProbe();
              final disk = await _readDiskLoaded();
              probing = false;
              cache._endViewportDiskProbe();
              if (!current()) {
                return null;
              }
              if (disk != null) {
                cache._cancelPosterLoadTurn(turn);
                return disk;
              }
            }
            if (turn.isReleased) {
              break;
            }
            if (!cache.isScrollBusy && !cache._hasActiveViewportDiskProbe) {
              await turn.done.future;
              break;
            }
            await _waitForViewportMove(turn);
          }
          ready = current();
        } finally {
          if (probing) {
            cache._endViewportDiskProbe();
          }
          if (!ready) {
            cache._cancelPosterLoadTurn(turn);
          }
        }
        if (!ready) {
          return null;
        }
        if (!turn.isReleased) {
          await turn.done.future;
        }
        if (!current()) {
          return null;
        }
        // 屏幕外的磁盘和网络仍等停稳,并排在视口内加载之后。解码并发不变。
        final loaded = await _loadOnce();
        if (loaded != null) {
          return loaded;
        }
        if (!current() || !_canRetryLoad()) {
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
      return null;
    } finally {
      if (generation == _loadGeneration) {
        final wake = _layoutWake;
        _layoutWake = null;
        if (wake != null && !wake.isCompleted) {
          wake.complete();
        }
      }
    }
  }

  Future<_LoadedImage?> _readDiskLoaded() async {
    if (_candidates.isEmpty) {
      return null;
    }
    final candidate = _candidates.first;
    final maxWidth = _requestMaxWidth;
    final serverId = _serverId;
    final bytes = await MediaImageCache.instance._readDiskCache(
      serverId: serverId,
      itemId: candidate.itemId,
      type: candidate.type,
      tag: candidate.tag,
      maxWidth: maxWidth,
    );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return _LoadedImage(
      bytes: bytes,
      type: candidate.type,
      cacheKey: MediaImageCache.key(
        serverId: serverId,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
      ),
    );
  }

  bool _canRetryLoad() {
    final serverId = _serverId;
    final maxWidth = _requestMaxWidth;
    for (final candidate in _candidates) {
      if (!MediaImageCache.instance.isNegativeCached(
        serverId: serverId,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<_LoadedImage?> _loadOnce() async {
    final client = AuthScope.of(context).client;
    final serverId = _serverId;
    final maxWidth = _requestMaxWidth;
    for (final candidate in _candidates) {
      CancelToken? token;
      final bytes = await MediaImageCache.instance.load(
        serverId: serverId,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
        fetch: () async {
          token = CancelToken();
          try {
            final data = await client.getItemImage(
              candidate.itemId,
              type: candidate.type,
              tag: candidate.tag,
              maxWidth: maxWidth,
              cancelToken: token,
            );
            if (data.isEmpty) {
              return null;
            }
            return Uint8List.fromList(data);
          } catch (_) {
            return null;
          }
        },
        onAbort: () => token?.cancel('image-timeout'),
      );
      if (bytes != null && bytes.isNotEmpty) {
        return _LoadedImage(
          bytes: bytes,
          type: candidate.type,
          cacheKey: MediaImageCache.key(
            serverId: serverId,
            itemId: candidate.itemId,
            type: candidate.type,
            tag: candidate.tag,
            maxWidth: maxWidth,
          ),
        );
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (!_hasImageSource || AuthScope.maybeOf(context) == null) {
      return PosterPlaceholder(width: width, height: height);
    }
    // 内存命中同一帧画上。视口内磁盘命中不等滚动空闲;屏幕外未缓存仍推迟。
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
    // 按请求宽度解码,避免服务端返回原图时在片库滚动里整屏解码。
    // ImageCache 用字符串 key,避免每帧对整段 JPEG 做 ==/hashCode。
    return Image(
      image: _MediaMemoryImage(
        cacheKey: loaded.cacheKey,
        bytes: loaded.bytes,
        targetWidth: widget.maxWidth,
      ),
      width: width,
      height: height,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      isAntiAlias: false,
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
      animated: false,
    );
  }
}

/// 同时只解码两张海报,避免片库快滑时一帧里塞进整屏解码。
class _DecodeGate {
  static const int _limit = 2;
  static int _active = 0;
  static final List<Completer<void>> _waiters = [];

  static Future<void> acquire() {
    if (_active < _limit) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  static void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) next.complete();
      return;
    }
    if (_active > 0) _active--;
  }
}

/// [ImageCache] 按字符串 key 命中,避免 [MemoryImage] 每帧扫描整段字节。
class _MediaMemoryImage extends ImageProvider<_MediaMemoryImage> {
  const _MediaMemoryImage({
    required this.cacheKey,
    required this.bytes,
    this.targetWidth,
  });

  final String cacheKey;
  final Uint8List bytes;
  final int? targetWidth;

  @override
  Future<_MediaMemoryImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_MediaMemoryImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _MediaMemoryImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1,
      debugLabel: 'MediaMemoryImage($cacheKey)',
    );
  }

  Future<ui.Codec> _loadAsync(
    _MediaMemoryImage key,
    ImageDecoderCallback decode,
  ) async {
    await _DecodeGate.acquire();
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(key.bytes);
      final target = key.targetWidth;
      if (target == null || target <= 0) {
        return await decode(buffer);
      }
      return await ui.instantiateImageCodecFromBuffer(
        buffer,
        targetWidth: target,
        allowUpscaling: false,
      );
    } finally {
      _DecodeGate.release();
    }
  }

  @override
  bool operator ==(Object other) {
    return other is _MediaMemoryImage && other.cacheKey == cacheKey;
  }

  @override
  int get hashCode => cacheKey.hashCode;
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

class _PosterLoadTurn {
  _PosterLoadTurn({required this.sequence, required this.inViewport});

  final int sequence;
  final bool Function() inViewport;
  final Completer<void> done = Completer<void>();
  bool cancelled = false;

  bool get isReleased => done.isCompleted;
}

/// 图片字节两级缓存:
/// - 第一级为进程内 LRU,按字节量上限(默认约 64 MiB,可调)淘汰最久未用条目;
/// - 第二级为磁盘缓存,目录 `ApplicationSupport/rillight/image_cache/`,
///   总占用超过上限时按 LRU 回收;
/// - 缓存 key 为 `serverId|itemId|type|tag|variant|maxWidth`,tag 变化即换 key,
///   服务器换图后自动重新拉取;
/// - 负缓存带 TTL,失败结果不再被永久吞掉;
/// - 磁盘写入失败时降级为仅内存缓存,不影响显示。
/// 同时限制并发网络拉取,网格快滑时不会一次打几十张把 UI 打卡。
/// 磁盘读写不占用该并发槽,避免写盘变慢后缩略图停在第几十张不再刷新。
class MediaImageCache {
  MediaImageCache._();

  static final MediaImageCache instance = MediaImageCache._();

  /// 内存层字节量上限,默认约 64 MiB。
  static const int defaultMemoryLimitBytes = 64 * 1024 * 1024;

  /// 磁盘层总占用上限,默认约 512 MiB。
  static const int defaultDiskLimitBytes = 512 * 1024 * 1024;

  /// 负缓存(拉取失败)的 TTL。
  static const Duration defaultNegativeTtl = Duration(seconds: 30);

  /// 单次网络拉取超时。超时记为未命中并释放并发槽,避免骨架永远转圈。
  static const Duration defaultFetchTimeout = Duration(seconds: 12);

  static const int _maxConcurrentFetches = 8;

  /// 屏幕外未缓存海报等滚动停稳后再读盘、再走网络。桌面滚轮是离散 jumpTo,
  /// Flutter 自带的滑动推迟几乎不生效。视口内的磁盘命中不走这个等待。
  static const Duration defaultScrollIdle = Duration(milliseconds: 80);

  int memoryLimitBytes = defaultMemoryLimitBytes;
  Duration negativeTtl = defaultNegativeTtl;
  Duration fetchTimeout = defaultFetchTimeout;
  DateTime Function() clock = DateTime.now;

  final LinkedHashMap<String, Uint8List> _bytes = LinkedHashMap();
  int _bytesTotal = 0;
  final Map<String, DateTime> _misses = {};
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _activeFetches = 0;
  final List<Completer<void>> _waiters = [];
  Timer? _scrollIdleTimer;
  final List<Completer<void>> _scrollIdleWaiters = [];
  final Map<String, Uint8List> _pendingDiskWrites = {};
  Timer? _writeFlushTimer;

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
    fetchTimeout = defaultFetchTimeout;
    clock = DateTime.now;
    _resetScrollIdle();
    _pendingDiskWrites.clear();
    _writeFlushTimer?.cancel();
    _writeFlushTimer = null;
    debugSetDiskStore(null);
  }

  /// 货架/网格正在滚:推迟未命中加载与磁盘写入。
  ///
  /// 忙碌窗口只跟 [Timer] 走。墙钟截止时间在 FakeAsync 测试里几乎不动,
  /// 按剩余墙钟再排 Timer 会在 `pumpAndSettle` 之后留下 pending timer。
  void markScrollActivity() {
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(defaultScrollIdle, _completeScrollIdleIfQuiet);
  }

  bool get isScrollBusy => _scrollIdleTimer != null;

  Future<void> waitForScrollIdle() async {
    if (!isScrollBusy) {
      return;
    }
    final waiter = Completer<void>();
    _scrollIdleWaiters.add(waiter);
    await waiter.future;
  }

  void _completeScrollIdleIfQuiet() {
    _scrollIdleTimer = null;
    _releaseScrollIdleWaiters();
    _schedulePosterRelease();
  }

  void _resetScrollIdle() {
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = null;
    _releaseScrollIdleWaiters();
    _resetPosterTurns();
  }

  void _releaseScrollIdleWaiters() {
    if (_scrollIdleWaiters.isEmpty) {
      return;
    }
    final waiters = List<Completer<void>>.from(_scrollIdleWaiters);
    _scrollIdleWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  bool get _hasActiveViewportDiskProbe => _viewportDiskProbes > 0;

  int _viewportDiskProbes = 0;
  int _posterTurnSerial = 0;
  final List<_PosterLoadTurn> _posterTurns = [];
  bool _posterReleaseQueued = false;

  /// 登记一次海报加载。滚动中或仍有视口磁盘探测时不放行。
  /// 放行时视口内排在屏幕外之前。
  _PosterLoadTurn _claimPosterLoadTurn(bool Function() inViewport) {
    final turn = _PosterLoadTurn(
      sequence: _posterTurnSerial++,
      inViewport: inViewport,
    );
    _posterTurns.add(turn);
    _schedulePosterRelease();
    return turn;
  }

  void _cancelPosterLoadTurn(_PosterLoadTurn turn) {
    turn.cancelled = true;
    _posterTurns.remove(turn);
  }

  void _beginViewportDiskProbe() {
    _viewportDiskProbes++;
  }

  void _endViewportDiskProbe() {
    if (_viewportDiskProbes > 0) {
      _viewportDiskProbes--;
    }
    _schedulePosterRelease();
  }

  void _schedulePosterRelease() {
    if (_posterReleaseQueued || _viewportDiskProbes > 0 || isScrollBusy) {
      return;
    }
    if (_posterTurns.isEmpty) {
      return;
    }
    _posterReleaseQueued = true;
    scheduleMicrotask(() {
      _posterReleaseQueued = false;
      if (_viewportDiskProbes > 0 || isScrollBusy) {
        return;
      }
      _releasePosterTurns();
    });
  }

  void _releasePosterTurns() {
    if (_posterTurns.isEmpty) {
      return;
    }
    final turns = List<_PosterLoadTurn>.from(_posterTurns);
    _posterTurns.clear();
    final viewport = <_PosterLoadTurn>[];
    final offscreen = <_PosterLoadTurn>[];
    for (final turn in turns) {
      if (turn.cancelled || turn.done.isCompleted) {
        continue;
      }
      if (_turnInViewport(turn)) {
        viewport.add(turn);
      } else {
        offscreen.add(turn);
      }
    }
    int bySequence(_PosterLoadTurn a, _PosterLoadTurn b) =>
        a.sequence.compareTo(b.sequence);
    viewport.sort(bySequence);
    offscreen.sort(bySequence);
    for (final turn in viewport.followedBy(offscreen)) {
      if (!turn.done.isCompleted) {
        turn.done.complete();
      }
    }
  }

  bool _turnInViewport(_PosterLoadTurn turn) {
    try {
      return turn.inViewport();
    } catch (_) {
      return false;
    }
  }

  void _resetPosterTurns() {
    _viewportDiskProbes = 0;
    _posterReleaseQueued = false;
    final turns = List<_PosterLoadTurn>.from(_posterTurns);
    _posterTurns.clear();
    for (final turn in turns) {
      if (!turn.done.isCompleted) {
        turn.done.complete();
      }
    }
  }

  /// 只读内存和磁盘,不发网络,也不等滚动空闲。
  Future<Uint8List?> _readDiskCache({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
  }) async {
    final cacheKey = key(
      serverId: serverId,
      itemId: itemId,
      type: type,
      tag: tag,
      variant: variant,
      maxWidth: maxWidth,
    );
    final cached = _touch(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    if (isNegativeCached(
      serverId: serverId,
      itemId: itemId,
      type: type,
      tag: tag,
      variant: variant,
      maxWidth: maxWidth,
    )) {
      return null;
    }
    if (!_diskResolved) {
      await _ensureDiskStore();
    }
    final disk = await _readDisk(cacheKey);
    if (disk != null && disk.isNotEmpty) {
      _storeBytes(cacheKey, disk);
      return disk;
    }
    return null;
  }

  Uint8List? peek({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
  }) {
    return _bytes[key(
      serverId: serverId,
      itemId: itemId,
      type: type,
      tag: tag,
      variant: variant,
      maxWidth: maxWidth,
    )];
  }

  bool isNegativeCached({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
  }) {
    final expiry =
        _misses[key(
          serverId: serverId,
          itemId: itemId,
          type: type,
          tag: tag,
          variant: variant,
          maxWidth: maxWidth,
        )];
    return expiry != null && clock().isBefore(expiry);
  }

  Future<Uint8List?> load({
    required String serverId,
    required String itemId,
    required String type,
    String? tag,
    String variant = '',
    required int maxWidth,
    required Future<Uint8List?> Function() fetch,
    VoidCallback? onAbort,
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
      try {
        // 磁盘读写不占网络并发槽:网格滑过几十张时写盘变慢,不能把后面的
        // 缩略图堵在 _acquire 队列里一直转圈。
        if (_diskResolved) {
          final disk = await _readDisk(cacheKey);
          if (disk != null && disk.isNotEmpty) {
            _storeBytes(cacheKey, disk);
            return disk;
          }
        } else {
          unawaited(_ensureDiskStore());
        }
        await _acquire();
        Uint8List? bytes;
        var timedOut = false;
        try {
          bytes = await fetch().timeout(fetchTimeout);
        } on TimeoutException {
          timedOut = true;
          bytes = null;
          onAbort?.call();
        } finally {
          _release();
        }
        if (bytes != null && bytes.isNotEmpty) {
          final loaded = bytes;
          _storeBytes(cacheKey, loaded);
          if (_diskResolved) {
            unawaited(_writeDisk(cacheKey, loaded));
          } else {
            unawaited(
              _ensureDiskStore().then((_) => _writeDisk(cacheKey, loaded)),
            );
          }
          return loaded;
        }
        if (!timedOut) {
          _recordMiss(cacheKey);
        }
        return null;
      } finally {
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

  static const Duration _diskIoTimeout = Duration(seconds: 2);

  Future<Uint8List?> _readDisk(String cacheKey) async {
    final store = _diskStore;
    if (store == null) {
      return null;
    }
    try {
      return await store.read(cacheKey).timeout(_diskIoTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String cacheKey, Uint8List bytes) async {
    if (isScrollBusy) {
      _pendingDiskWrites[cacheKey] = bytes;
      _scheduleWriteFlush();
      return;
    }
    await _writeDiskNow(cacheKey, bytes);
  }

  void _scheduleWriteFlush() {
    _writeFlushTimer?.cancel();
    _writeFlushTimer = Timer(defaultScrollIdle, () {
      _writeFlushTimer = null;
      if (isScrollBusy) {
        _scheduleWriteFlush();
        return;
      }
      unawaited(_flushPendingWrites());
    });
  }

  Future<void> _flushPendingWrites() async {
    if (_pendingDiskWrites.isEmpty) {
      return;
    }
    final pending = Map<String, Uint8List>.from(_pendingDiskWrites);
    _pendingDiskWrites.clear();
    for (final entry in pending.entries) {
      await _writeDiskNow(entry.key, entry.value);
    }
  }

  Future<void> _writeDiskNow(String cacheKey, Uint8List bytes) async {
    final store = _diskStore;
    if (store == null) {
      return;
    }
    try {
      await store.write(cacheKey, bytes).timeout(_diskIoTimeout);
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
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    if (_activeFetches > 0) {
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
    _pendingDiskWrites.clear();
    _writeFlushTimer?.cancel();
    _writeFlushTimer = null;
    _resetScrollIdle();
  }
}

/// 货架/网格滚动时通知 [MediaImageCache] 推迟未命中加载与写盘。
class MediaImageScrollListener extends StatelessWidget {
  const MediaImageScrollListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) {
          return false;
        }
        if (notification is ScrollStartNotification ||
            notification is ScrollUpdateNotification) {
          MediaImageCache.instance.markScrollActivity();
        }
        return false;
      },
      child: child,
    );
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

/// 默认磁盘缓存:文件名由缓存 key base64Url 编码而来。会话内 LRU 用内存
/// 索引的 lastUsed;进程重启后按文件写入时间近似。总占用超过上限时淘汰
/// 最久未使用的条目。
class FileMediaImageDiskStore implements MediaImageDiskStore {
  FileMediaImageDiskStore(
    this.directory, {
    this.limitBytes = MediaImageCache.defaultDiskLimitBytes,
  });

  final Directory directory;
  final int limitBytes;

  static const String _fileSuffix = '.img';

  Map<String, _DiskEntry>? _index;
  Future<Map<String, _DiskEntry>>? _indexBuild;
  int _totalBytes = 0;

  static String _fileName(String key) {
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return '$encoded$_fileSuffix';
  }

  Future<Map<String, _DiskEntry>> _ensureIndex() {
    final index = _index;
    if (index != null) {
      return Future<Map<String, _DiskEntry>>.value(index);
    }
    return _indexBuild ??= _buildIndex().whenComplete(() {
      _indexBuild = null;
    });
  }

  Future<Map<String, _DiskEntry>> _buildIndex() async {
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
    final name = _fileName(key);
    final indexed = _index?[name];
    if (indexed != null) {
      return _readIndexed(name, indexed);
    }
    if (_index != null) {
      return null;
    }
    // 索引还在扫目录时不要堵住缩略图:按文件名直接读,扫盘放到后台。
    unawaited(_ensureIndex());
    final file = File('${directory.path}/$name');
    try {
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readIndexed(String name, _DiskEntry entry) async {
    try {
      final bytes = await entry.file.readAsBytes();
      // 会话内 LRU 只改内存索引。每次命中都 setLastModified 会在 HDD 上
      // 把首页海报读放大写成元数据风暴。
      _index?[name] = entry.withLastUsed(DateTime.now());
      return bytes;
    } catch (_) {
      _index?.remove(name);
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
    await file.writeAsBytes(bytes, flush: false);
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
