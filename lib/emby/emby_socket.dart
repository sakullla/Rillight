import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_url.dart';

/// 目录相关的服务器通知类型。
///
/// Emby WebSocket 消息形如 `{"MessageName":"UserDataChanged","Data":"{...}"}`,
/// 其中 `Data` 的变更细节不消费——通知只作为失效信号,以重新拉取结果为准。
enum EmbySocketNotificationKind { userDataChanged, libraryChanged }

/// WebSocket 连接抽象,便于测试注入。
abstract class EmbySocketConnection {
  /// 文本帧流。
  Stream<String> get messages;

  Future<void> close();
}

/// dart:io WebSocket 实现(桌面端可用)。
class IoEmbySocketConnection implements EmbySocketConnection {
  IoEmbySocketConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((dynamic frame) => frame is String).cast<String>();

  @override
  Future<void> close() => _socket.close();
}

typedef EmbySocketConnector = Future<EmbySocketConnection> Function(Uri uri);

/// 连接官方 WebSocket 端点 /embywebsocket?api_key=...。
Future<EmbySocketConnection> connectEmbySocket(Uri uri) async {
  final socket = await WebSocket.connect(uri.toString());
  return IoEmbySocketConnection(socket);
}

/// 由 http(s) 服务器地址与访问令牌构造 WebSocket 地址。
Uri embyWebSocketUri(Uri baseUrl, String apiKey) {
  final joined = joinEmbyPath(baseUrl, '/embywebsocket');
  return joined.replace(
    scheme: joined.scheme == 'https' ? 'wss' : 'ws',
    queryParameters: {'api_key': apiKey},
  );
}

/// 解析服务器通知消息;不相关或无法解析的消息返回 null。
@visibleForTesting
EmbySocketNotificationKind? parseEmbySocketMessage(String raw) {
  Object decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  switch (decoded['MessageName']) {
    case 'UserDataChanged':
      return EmbySocketNotificationKind.userDataChanged;
    case 'LibraryChanged':
      return EmbySocketNotificationKind.libraryChanged;
    default:
      return null;
  }
}

/// Emby WebSocket 可选增强通道:服务器支持时接收 UserDataChanged /
/// LibraryChanged 通知,失效相关会话前缀缓存并触发后台重拉。
///
/// 仅作增强通道:连接失败/服务器不支持时静默指数退避重连,达到上限后
/// 放弃,全部更新能力仍由 HTTP 路径(先显后刷/TTL/手动刷新)承担,
/// 无功能缺失。通知不含(不消费)变更细节,以重新拉取结果为准。
///
/// 生命周期由调用方(CatalogShell)管理:start 后进入重连循环,
/// 登录会话变化时重建实例,登出/关闭时调用 stop。
class EmbySocket {
  EmbySocket({
    required Uri baseUrl,
    required String apiKey,
    required this.cache,
    required this.onUserDataChanged,
    required this.onLibraryChanged,
    EmbySocketConnector? connector,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.maxReconnectAttempts = defaultMaxReconnectAttempts,
    this.stableConnection = const Duration(seconds: 30),
    this.notifyDebounce = const Duration(milliseconds: 500),
  }) : _uri = embyWebSocketUri(baseUrl, apiKey),
       _connector = connector ?? connectEmbySocket;

  /// 连续失败重连上限,达到后放弃(静默,不再尝试)。
  static const int defaultMaxReconnectAttempts = 5;

  /// 缓存层:通知到达时失效当前会话前缀。
  final CatalogCache cache;

  /// UserDataChanged 对应的刷新(首页行,不含片库列表)。
  final Future<void> Function() onUserDataChanged;

  /// LibraryChanged 对应的刷新(全量,含片库列表)。
  final Future<void> Function() onLibraryChanged;

  final Duration initialBackoff;
  final Duration maxBackoff;
  final int maxReconnectAttempts;

  /// 连接存活超过该时长视为「稳定连接」:其断开将退避计数归零,
  /// 避免网络短断被闪断上限误杀,也避免连接反复闪断时无限重试。
  final Duration stableConnection;

  /// 通知触发的刷新去抖窗口:密集通知合并为一次刷新,
  /// LibraryChanged 与 UserDataChanged 同时在窗内时以全量刷新优先。
  final Duration notifyDebounce;

  final Uri _uri;
  final EmbySocketConnector _connector;

  EmbySocketStatus _status = EmbySocketStatus.idle;
  bool _started = false;
  int _failures = 0;
  DateTime? _connectedAt;
  EmbySocketConnection? _connection;
  StreamSubscription<String>? _subscription;
  Timer? _reconnectTimer;
  Timer? _notifyTimer;
  bool _pendingLibraryRefresh = false;

  EmbySocketStatus get status => _status;

  bool get isStarted => _started;

  /// 开始连接与重连循环(幂等)。
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _failures = 0;
    unawaited(_connect());
  }

  /// 停止并断开;之后不再重连。可再次 start(重新开始计数)。
  Future<void> stop() async {
    _started = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _pendingLibraryRefresh = false;
    _connectedAt = null;
    final connection = _connection;
    _connection = null;
    final subscription = _subscription;
    _subscription = null;
    _status = EmbySocketStatus.idle;
    if (subscription != null) {
      await subscription.cancel();
    }
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // 断开失败无碍:连接已弃用。
      }
    }
  }

  Future<void> _connect() async {
    if (!_started) {
      return;
    }
    _status = EmbySocketStatus.connecting;
    EmbySocketConnection connection;
    try {
      connection = await _connector(_uri);
    } catch (_) {
      // 连接失败/服务器不支持:静默退避,由 HTTP 路径承担更新。
      _onFailure();
      return;
    }
    if (!_started) {
      // stop() 在连接等待期间被调用。
      try {
        await connection.close();
      } catch (_) {
        // 同上,静默。
      }
      return;
    }
    _connection = connection;
    _connectedAt = DateTime.now();
    _status = EmbySocketStatus.connected;
    _subscription = connection.messages.listen(
      _onMessage,
      onError: (Object _) => _onDisconnected(),
      onDone: _onDisconnected,
      cancelOnError: true,
    );
  }

  void _onFailure() {
    if (!_started) {
      return;
    }
    if (_failures >= maxReconnectAttempts) {
      _status = EmbySocketStatus.gaveUp;
      return;
    }
    _failures++;
    _scheduleReconnect();
  }

  void _onDisconnected() {
    final subscription = _subscription;
    _subscription = null;
    final connectedAt = _connectedAt;
    _connectedAt = null;
    _connection = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    if (!_started) {
      return;
    }
    if (connectedAt != null &&
        DateTime.now().difference(connectedAt) >= stableConnection) {
      // 稳定连接断开:退避计数从初始值重新开始。
      _failures = 0;
    }
    _onFailure();
  }

  void _scheduleReconnect() {
    var delay = initialBackoff;
    for (var i = 1; i < _failures; i++) {
      delay *= 2;
      if (delay >= maxBackoff) {
        delay = maxBackoff;
        break;
      }
    }
    _status = EmbySocketStatus.waitingToRetry;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connect());
    });
  }

  void _onMessage(String raw) {
    final kind = parseEmbySocketMessage(raw);
    if (kind == null) {
      return;
    }
    // 通知不含变更细节:立即失效当前会话前缀缓存,重拉结果为准。
    unawaited(
      cache.invalidateSession().catchError((Object _) {
        // 失效失败无碍:条目仍有 TTL 兜底。
      }),
    );
    if (kind == EmbySocketNotificationKind.libraryChanged) {
      // 全量刷新优先:同一去抖窗口内出现 LibraryChanged 时,
      // UserDataChanged 的行级刷新被其覆盖。
      _pendingLibraryRefresh = true;
    }
    _notifyTimer?.cancel();
    _notifyTimer = Timer(notifyDebounce, _flushRefresh);
  }

  void _flushRefresh() {
    _notifyTimer = null;
    final full = _pendingLibraryRefresh;
    _pendingLibraryRefresh = false;
    final callback = full ? onLibraryChanged : onUserDataChanged;
    unawaited(
      callback().catchError((Object _) {
        // 刷新失败无碍:HTTP 路径的重试/TTL 机制仍在。
      }),
    );
  }
}

/// 连接状态。
enum EmbySocketStatus {
  /// 未启动或已停止。
  idle,

  /// 正在连接。
  connecting,

  /// 已连接。
  connected,

  /// 连接失败,退避等待重连。
  waitingToRetry,

  /// 连续失败达上限,已放弃(静默)。
  gaveUp,
}
