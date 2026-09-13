import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_socket.dart';

/// 记录前缀删除的假磁盘存储。
class _RecordingDiskStore implements CatalogDiskStore, PrefixCatalogDiskStore {
  final Map<String, String> data = {};
  final List<String> removedPrefixes = [];

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String body) async {
    data[key] = body;
  }

  @override
  Future<void> remove(String key) async {
    data.remove(key);
  }

  @override
  Future<void> clear() async {
    data.clear();
  }

  @override
  Future<void> removePrefix(String prefix) async {
    removedPrefixes.add(prefix);
    data.removeWhere((key, _) => key.startsWith(prefix));
  }
}

class _FakeConnection implements EmbySocketConnection {
  _FakeConnection({void Function()? onClose}) : _onClose = onClose;

  final void Function()? _onClose;
  final StreamController<String> _messages = StreamController<String>();
  bool closed = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    _onClose?.call();
    await _messages.close();
  }

  /// 服务器侧断开(未经客户端 close)。
  void serverClose() => _messages.close();

  void emit(String raw) => _messages.add(raw);
}

Future<void> _noOp() async {}

CatalogCache _cacheWithStore([_RecordingDiskStore? store]) {
  final cache = CatalogCache();
  cache.debugSetDiskStore(store ?? _RecordingDiskStore());
  return cache;
}

EmbySocket _buildSocket({
  required EmbySocketConnector connector,
  CatalogCache? cache,
  Future<void> Function() onUserDataChanged = _noOp,
  Future<void> Function() onLibraryChanged = _noOp,
  Duration initialBackoff = Duration.zero,
  Duration stableConnection = Duration.zero,
  int maxReconnectAttempts = 3,
  Duration notifyDebounce = Duration.zero,
}) {
  return EmbySocket(
    baseUrl: Uri.parse('http://emby.test:8096'),
    apiKey: 'token-1',
    cache: cache ?? _cacheWithStore(),
    onUserDataChanged: onUserDataChanged,
    onLibraryChanged: onLibraryChanged,
    connector: connector,
    initialBackoff: initialBackoff,
    maxReconnectAttempts: maxReconnectAttempts,
    stableConnection: stableConnection,
    notifyDebounce: notifyDebounce,
  );
}

void main() {
  test('embyWebSocketUri 构造官方 ws 端点并携带 api_key', () {
    expect(
      embyWebSocketUri(Uri.parse('http://emby.test:8096'), 'token-1'),
      Uri.parse('ws://emby.test:8096/embywebsocket?api_key=token-1'),
    );
    expect(
      embyWebSocketUri(Uri.parse('https://emby.test'), 'token-2'),
      Uri.parse('wss://emby.test/embywebsocket?api_key=token-2'),
    );
    // 反代子路径场景:保留 base path。
    expect(
      embyWebSocketUri(Uri.parse('https://emby.test/emby'), 'token-3'),
      Uri.parse('wss://emby.test/emby/embywebsocket?api_key=token-3'),
    );
  });

  test('parseEmbySocketMessage 只识别目录相关通知', () {
    expect(
      parseEmbySocketMessage(
        '{"MessageName":"UserDataChanged","Data":"{\\"UserId\\":\\"u1\\"}"}',
      ),
      EmbySocketNotificationKind.userDataChanged,
    );
    expect(
      parseEmbySocketMessage('{"MessageName":"LibraryChanged","Data":"{}"}'),
      EmbySocketNotificationKind.libraryChanged,
    );
    // 其余消息(播放指令、保活、畸形文本)一律忽略。
    expect(parseEmbySocketMessage('{"MessageName":"GeneralCommand"}'), isNull);
    expect(parseEmbySocketMessage('{"MessageName":"Play"}'), isNull);
    expect(parseEmbySocketMessage('{"MessageName":"KeepAlive"}'), isNull);
    expect(parseEmbySocketMessage('not-json'), isNull);
    expect(parseEmbySocketMessage('[1,2,3]'), isNull);
  });

  test('start 经注入连接器连接官方端点,stop 断开并复位状态', () async {
    final connection = _FakeConnection();
    Uri? requested;
    final socket = _buildSocket(
      connector: (uri) async {
        requested = uri;
        return connection;
      },
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);
    expect(
      requested,
      Uri.parse('ws://emby.test:8096/embywebsocket?api_key=token-1'),
    );
    expect(socket.status, EmbySocketStatus.connected);
    expect(socket.isStarted, isTrue);

    await socket.stop();
    expect(connection.closed, isTrue);
    expect(socket.status, EmbySocketStatus.idle);
    expect(socket.isStarted, isFalse);
  });

  test('UserDataChanged 失效会话前缀缓存并触发首页行刷新', () async {
    final store = _RecordingDiskStore();
    final cache = _cacheWithStore(store);
    cache.attachSession(serverId: 'server-id-1', userId: 'user-alice');
    final request = catalogViewsRequest(userId: 'user-alice');
    await cache.write(request, {'Items': [], 'TotalRecordCount': 0});
    expect(await cache.lookup(request), isNotNull);

    final connection = _FakeConnection();
    var refreshes = 0;
    final socket = _buildSocket(
      connector: (uri) async => connection,
      cache: cache,
      onUserDataChanged: () async => refreshes++,
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);

    connection.emit(
      '{"MessageName":"UserDataChanged","Data":"{\\"UserId\\":\\"user-alice\\"}"}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(refreshes, 1);
    expect(await cache.lookup(request), isNull, reason: '会话前缀缓存已失效');
    expect(store.removedPrefixes, contains('server-id-1|user-alice|'));
    expect(store.data, isEmpty);
    await socket.stop();
  });

  test('LibraryChanged 失效缓存并触发全量刷新回调', () async {
    final store = _RecordingDiskStore();
    final cache = _cacheWithStore(store);
    cache.attachSession(serverId: 'server-id-1', userId: 'user-alice');
    await cache.write(catalogViewsRequest(userId: 'user-alice'), {
      'Items': [],
      'TotalRecordCount': 0,
    });

    final connection = _FakeConnection();
    var rowRefreshes = 0;
    var fullRefreshes = 0;
    final socket = _buildSocket(
      connector: (uri) async => connection,
      cache: cache,
      onUserDataChanged: () async => rowRefreshes++,
      onLibraryChanged: () async => fullRefreshes++,
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);

    connection.emit('{"MessageName":"LibraryChanged","Data":"{}"}');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rowRefreshes, 0);
    expect(fullRefreshes, 1);
    expect(store.removedPrefixes, contains('server-id-1|user-alice|'));
    await socket.stop();
  });

  test('密集通知去抖合并为一次刷新,LibraryChanged 优先全量', () async {
    final connection = _FakeConnection();
    var rowRefreshes = 0;
    var fullRefreshes = 0;
    final socket = _buildSocket(
      connector: (uri) async => connection,
      onUserDataChanged: () async => rowRefreshes++,
      onLibraryChanged: () async => fullRefreshes++,
      notifyDebounce: const Duration(milliseconds: 30),
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);

    connection.emit('{"MessageName":"UserDataChanged"}');
    connection.emit('{"MessageName":"UserDataChanged"}');
    connection.emit('{"MessageName":"LibraryChanged"}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(rowRefreshes, 0, reason: '去抖窗口内不触发');
    expect(fullRefreshes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rowRefreshes, 0);
    expect(fullRefreshes, 1);

    connection.emit('{"MessageName":"UserDataChanged"}');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rowRefreshes, 1);
    expect(fullRefreshes, 1);
    await socket.stop();
  });

  test('无关消息不触发刷新与失效', () async {
    final store = _RecordingDiskStore();
    final cache = _cacheWithStore(store);
    cache.attachSession(serverId: 'server-id-1', userId: 'user-alice');
    await cache.write(catalogViewsRequest(userId: 'user-alice'), {
      'Items': [],
      'TotalRecordCount': 0,
    });

    final connection = _FakeConnection();
    var refreshes = 0;
    final socket = _buildSocket(
      connector: (uri) async => connection,
      cache: cache,
      onUserDataChanged: () async => refreshes++,
      onLibraryChanged: () async => refreshes++,
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);

    connection.emit('{"MessageName":"GeneralCommand"}');
    connection.emit('broken');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(refreshes, 0);
    expect(store.removedPrefixes, isEmpty);
    expect(
      await cache.lookup(catalogViewsRequest(userId: 'user-alice')),
      isNotNull,
    );
    await socket.stop();
  });

  test('连接失败静默指数退避,达上限后放弃', () async {
    var attempts = 0;
    final socket = _buildSocket(
      connector: (uri) async {
        attempts++;
        throw StateError('server unreachable');
      },
      initialBackoff: const Duration(milliseconds: 1),
      maxReconnectAttempts: 3,
    );
    // 不抛出:连接失败对调用方完全静默。
    socket.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempts, 4, reason: '首次连接 + 3 次退避重连');
    expect(socket.status, EmbySocketStatus.gaveUp);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(attempts, 4, reason: '放弃后不再尝试');
    await socket.stop();
  });

  test('连接反复闪断累计失败,达到重连上限后放弃', () async {
    var attempts = 0;
    final socket = _buildSocket(
      connector: (uri) async {
        attempts++;
        final connection = _FakeConnection();
        // 订阅前即被服务器关闭:连接立即 onDone。
        connection.serverClose();
        return connection;
      },
      initialBackoff: const Duration(milliseconds: 1),
      maxReconnectAttempts: 3,
      stableConnection: const Duration(minutes: 1),
    );
    socket.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempts, 4);
    expect(socket.status, EmbySocketStatus.gaveUp);
    await socket.stop();
  });

  test('稳定连接断开后自动重连并继续处理通知', () async {
    final first = _FakeConnection();
    final second = _FakeConnection();
    final connections = [first, second];
    var index = 0;
    var refreshes = 0;
    final socket = _buildSocket(
      connector: (uri) async => connections[index++],
      onUserDataChanged: () async => refreshes++,
      initialBackoff: const Duration(milliseconds: 1),
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);
    expect(socket.status, EmbySocketStatus.connected);

    first.serverClose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(index, 2, reason: '断线后重连一次');
    expect(socket.status, EmbySocketStatus.connected);

    second.emit('{"MessageName":"UserDataChanged"}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(refreshes, 1);
    await socket.stop();
    expect(second.closed, isTrue);
  });

  test('stop 取消待重连定时器,不再发起新连接', () async {
    var attempts = 0;
    final first = _FakeConnection();
    final socket = _buildSocket(
      connector: (uri) async {
        attempts++;
        return first;
      },
      initialBackoff: const Duration(milliseconds: 200),
    );
    socket.start();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);

    first.serverClose();
    await socket.stop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(attempts, 1, reason: 'stop 后不再重连');
    expect(socket.status, EmbySocketStatus.idle);
  });

  test('invalidateSession 未绑定会话时静默无操作', () async {
    final cache = _cacheWithStore();
    await cache.invalidateSession();
    expect(cache.hasSession, isFalse);
  });
}
