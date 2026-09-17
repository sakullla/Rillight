import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
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
      startTimeTicks: 600000000,
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
      expect(decoded.request.startTimeTicks, 600000000);
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

    test('takes the userAgent from client.customUserAgent', () async {
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

    test('no custom userAgent yields null', () async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final launch = PlayerWindowLaunch.fromAuth(
        auth: auth,
        request: const PlayerOpenRequest(itemId: 'movie-up'),
      );
      expect(launch.userAgent, isNull);
      expect(launch.toJson().containsKey('userAgent'), isFalse);
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
}
