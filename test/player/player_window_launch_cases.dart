import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';
import 'fake_player_process_control.dart';

class _SharedLines extends FakeEmbyAdapter {
  _SharedLines(this.lines) : super(lines);
  final List<FakeEmbyServer> lines;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final tokens = lines.expand((server) => server.issuedTokens).toList();
    for (final line in lines) {
      line.issuedTokens.addAll(tokens);
    }
    return super.fetch(options, stream, cancel);
  }
}

const _device = ClientDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-launch',
  version: '0.1.0',
);

PlayerWindowLaunch _launch({String? userAgent}) {
  return PlayerWindowLaunch(
    request: const PlayerOpenRequest(
      itemId: 'movie-up',
      autoResume: false,
      mediaSourceId: 'source-up',
      audioStreamIndex: 2,
      subtitleStreamIndex: 3,
      startPosition: Duration(microseconds: 600000000 ~/ 10),
    ),
    baseUrl: 'http://emby.test:8096/',
    accessToken: 'token-1',
    userId: 'user-alice',
    device: _device,
    userAgent: userAgent,
  );
}

void main() {
  group('PlayerWindowLaunch json', () {
    test('toJson/fromJson round-trip keeps the request and userAgent', () {
      final original = _launch(userAgent: 'CustomUA/1.0');
      final decoded = PlayerWindowLaunch.fromArguments(original.toArguments());

      expect(decoded.request.itemId, 'movie-up');
      expect(decoded.request.autoResume, isFalse);
      expect(decoded.request.mediaSourceId, 'source-up');
      expect(decoded.request.audioStreamIndex, 2);
      expect(decoded.request.subtitleStreamIndex, 3);
      expect(
        decoded.request.startPosition,
        Duration(microseconds: (600000000) ~/ 10),
      );
      expect(decoded.baseUrl, 'http://emby.test:8096/');
      expect(decoded.accessToken, 'token-1');
      expect(decoded.userId, 'user-alice');
      expect(decoded.userAgent, 'CustomUA/1.0');
      expect(decoded.device.clientName, _device.clientName);
      expect(decoded.device.deviceName, _device.deviceName);
      expect(decoded.device.deviceId, _device.deviceId);
      expect(decoded.device.version, _device.version);
    });

    test(
      'missing userAgent decodes to null and the client uses the default',
      () {
        final json = _launch().toJson();
        expect(json.containsKey('userAgent'), isFalse);

        final decoded = PlayerWindowLaunch.fromJson(json);
        expect(decoded.userAgent, isNull);

        final client = EmbyClient(device: decoded.device);
        client.attachSession(
          baseUrl: Uri.parse(decoded.baseUrl),
          accessToken: decoded.accessToken,
          userId: decoded.userId,
          userAgent: decoded.userAgent,
        );
        expect(client.customUserAgent, isNull);
        expect(client.userAgent, _device.defaultUserAgent);
        expect(client.sessionHeaders['User-Agent'], _device.defaultUserAgent);
      },
    );
  });

  group('PlayerWindowLaunch.fromAuth', () {
    late FakeEmbyServer server;
    late AuthController auth;

    setUp(() {
      server = FakeEmbyServer();
      auth = AuthController(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
    });

    tearDown(() => auth.dispose());

    test('takes the userAgent from client.customUserAgent and yields null without one', () async {
      // 未配置自定义 UA 时载荷为 null,且序列化省略该字段。
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final plain = PlayerWindowLaunch.fromAuth(
        auth: auth,
        request: const PlayerOpenRequest(itemId: 'movie-up'),
      );
      expect(plain.userAgent, isNull);
      expect(plain.toJson().containsKey('userAgent'), isFalse);

      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: '  CustomUA/1.0  ',
      );
      expect(auth.isLoggedIn, isTrue);
      expect(auth.client.customUserAgent, 'CustomUA/1.0');

      final launch = PlayerWindowLaunch.fromAuth(
        auth: auth,
        request: const PlayerOpenRequest(itemId: 'movie-up'),
      );
      expect(launch.userAgent, auth.client.customUserAgent);
      expect(launch.baseUrl, auth.client.baseUrl.toString());
      expect(launch.userId, auth.client.userId);
      expect(launch.accessToken, auth.client.accessToken);

      // 载荷跟随 client 的实际请求头,而非登录时的线路模型。
      auth.client.setUserAgent('Direct/2.0');
      expect(
        PlayerWindowLaunch.fromAuth(
          auth: auth,
          request: const PlayerOpenRequest(itemId: 'movie-up'),
        ).userAgent,
        'Direct/2.0',
      );
    });

    test('throws without a session', () {
      expect(
        () => PlayerWindowLaunch.fromAuth(
          auth: auth,
          request: const PlayerOpenRequest(itemId: 'movie-up'),
        ),
        throwsStateError,
      );
    });
  });

  test(
    'automatic desktop open starts playback on the last successful line',
    () async {
      final primary = FakeEmbyServer(
        baseUrl: Uri.parse('http://line-a.test:8096'),
      );
      final backup = FakeEmbyServer(
        serverId: primary.serverId,
        baseUrl: Uri.parse('http://line-b.test:8096'),
      );
      final auth = AuthController(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(_SharedLines([primary, backup])),
        ),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      HistoryWriter? history;
      DesktopPlayerWindowHost? host;
      try {
        await auth.connect(
          address: primary.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        history = await HistoryWriter.open(
          registry: auth.sources,
          store: MemoryHistoryStore(),
        );
        final runtime = PlaybackRuntime(auth: auth, history: history);
        final process = FakePlayerProcessControl();
        host = DesktopPlayerWindowHost(
          auth: auth,
          runtime: runtime,
          processControl: process,
        );
        final serverId = auth.savedServers.single.id;
        await auth.addLine(serverId, backup.baseUrl.toString());
        final saved = auth.savedServers.single;
        final activeId = saved.lines
            .firstWhere((line) => line.address.contains('line-a'))
            .id;
        final successfulId = saved.lines
            .firstWhere((line) => line.address.contains('line-b'))
            .id;
        await auth.selectLine(serverId, LineSelection.fixed(successfulId));
        Future<void> save(LineSelection selection) => auth.saveConfiguration(
          serverId,
          nickname: saved.nickname ?? '',
          iconId: saved.iconId,
          userAgent: saved.userAgent ?? '',
          lines: saved.lines,
          lineSelection: selection,
        );
        await save(LineSelection.fixed(activeId));
        await save(const LineSelection.auto());
        expect(auth.savedServers.single.activeLineId, activeId);
        expect(auth.savedServers.single.lastSuccessfulLineId, successfulId);
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        final launch = PlayerWindowLaunch.fromArguments(
          process.spawnedArguments.single,
        );
        expect(launch.baseUrl, contains('line-b.test'));
        expect(launch.lineSelection?.isAutomatic, isTrue);
      } finally {
        await host?.close();
        host?.dispose();
        await history?.close();
        auth.dispose();
      }
    },
  );
}
