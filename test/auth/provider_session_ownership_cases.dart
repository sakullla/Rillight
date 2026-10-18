import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';

import '../jellyfin/fake_jellyfin_server.dart';
import '../plex/fake_plex.dart';

const _device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);

Future<String> _login(AuthController auth, JellyfinFakeServer fake) async {
  final connect = ProviderConnectController(
    pollInterval: const Duration(milliseconds: 10),
    auth: auth,
  )..reset(MediaServerType.jellyfin);
  try {
    await connect.password(fake.url.toString(), 'alice', 'password');
    await connect.finish();
    expect(connect.failure, isNull);
    return connect.sourceId!;
  } finally {
    connect.dispose();
  }
}

class _HeldCredentials extends MemoryCredentialStore {
  String? heldSource;
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<StoredCredentials?> read(String serverId) async {
    final value = await super.read(serverId);
    final pending = gate;
    if (serverId == heldSource && pending != null) {
      gate = null;
      entered.complete();
      await pending.future;
    }
    return value;
  }
}

void main() {
  for (final status in [401, 498]) {
    for (final replacement in [
      MediaServerType.jellyfin,
      MediaServerType.plex,
    ]) {
      test('late Plex $status cannot expire selected $replacement', () async {
        final fake = FakePlex();
        final jellyfin = JellyfinFakeServer();
        await fake.start();
        await jellyfin.start();
        final credentials = MemoryCredentialStore();
        final cloud = CloudCredentialStore(credentials);
        final dio = Dio();
        final plex = PlexAuthentication(
          device: _device,
          accountUrl: fake.url,
          homeUrl: fake.url,
          readCredential: cloud.readCredential,
          writeCredential: cloud.writeCredential,
          deleteCredential: cloud.deleteCredential,
        );
        final auth = AuthController(
          client: PlexClient(device: _device, dio: dio),
          credentials: credentials,
          servers: MemoryServerListStore(),
          plexAuthentication: plex,
          providerClientFactory: (type) => type == MediaServerType.plex
              ? PlexClient(device: _device, dio: dio)
              : JellyfinClient(device: _device),
        );
        final connect = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
        )..reset(MediaServerType.plex);
        final gate = Completer<void>();
        try {
          fake.authorized = true;
          await connect.authorize('');
          for (
            var i = 0;
            i < 200 && connect.stage != ProviderConnectStage.resources;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(connect.failure, isNull);
          final resource = connect.resources.single;
          await connect.selectResource(resource, resource.connections.first);
          await connect.finish();
          expect(auth.session?.userId, '1');
          final old = auth.client;
          final expired = old.onSessionExpired!;
          final refresh = old.onRefreshSession!;
          final entered = Completer<void>();
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) async {
                if (options.uri.path.endsWith('/stale-review')) {
                  entered.complete();
                  await gate.future;
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: status,
                      data: {},
                    ),
                  );
                } else {
                  handler.next(options);
                }
              },
            ),
          );
          final rejection = expectLater(
            old.getItem('stale-review'),
            throwsA(anything),
          );
          await entered.future;
          if (replacement == MediaServerType.jellyfin) {
            await _login(auth, jellyfin);
          } else {
            await auth.switchTo(connect.sourceId!);
          }
          final selected = auth.session;
          expect(selected, isNotNull);
          expect(auth.client, isNot(same(old)));
          // Also exercise AuthController's callback ownership independently
          // of the protocol client's late-response guard.
          expired();
          expect(await refresh(), isFalse);
          expect(auth.session, same(selected));
          gate.complete();
          await rejection;
          expect(auth.session, same(selected));
          expect(auth.client.hasSession, isTrue);
          auth.client.onSessionExpired!();
          expect(auth.session, isNull, reason: 'current owner still expires');
        } finally {
          if (!gate.isCompleted) gate.complete();
          connect.dispose();
          auth.dispose();
          dio.close(force: true);
          await fake.close();
          await jellyfin.close();
        }
      });
    }
  }

  for (final end in [
    'success',
    'failure',
    'logout',
    'dispose',
    'credentials',
  ]) {
    test('superseded activation stays retired after $end', () async {
      final a = JellyfinFakeServer()..serverId = 'a';
      final b = JellyfinFakeServer()..serverId = 'b';
      await a.start();
      await b.start();
      final credentials = _HeldCredentials();
      final auth = AuthController(
        client: JellyfinClient(device: _device),
        credentials: credentials,
        servers: MemoryServerListStore(),
      );
      var disposed = false;
      try {
        final aid = await _login(auth, a);
        final bid = await _login(auth, b);
        await auth.loadLibraryCounts();
        final selected = auth.client;
        final gate = Completer<void>();
        late final Future<void> entered;
        if (end == 'credentials') {
          credentials.heldSource = aid;
          credentials.gate = gate;
          entered = credentials.entered.future;
        } else {
          a.delay = gate;
          a.arrived = Completer<void>();
          entered = a.arrived!.future;
        }
        final earlier = auth.switchTo(aid);
        await entered;
        expect(auth.client, same(selected));
        expect(auth.client.hasSession, isTrue);
        expect(auth.session?.server.id, bid);
        if (end == 'logout') {
          await auth.logout();
        } else if (end == 'dispose') {
          auth.dispose();
          disposed = true;
        } else {
          await auth.switchTo(bid);
          expect(auth.session?.server.id, bid);
        }
        if (end == 'failure') a.nextStatus = 401;
        gate.complete();
        await earlier;
        if (end == 'logout') {
          expect(auth.session, isNull);
          expect(auth.client.hasSession, isFalse);
        } else if (end == 'dispose') {
          expect(selected.hasSession, isFalse);
        } else {
          expect(auth.session?.server.id, bid);
          expect(auth.client.hasSession, isTrue);
          expect(auth.failure, isNull);
          expect((await auth.client.getItem('movie-1')).id, 'movie-1');
        }
      } finally {
        if (!disposed) auth.dispose();
        await a.close();
        await b.close();
      }
    });
  }

  test(
    'failed explicit same-server activation preserves current facade',
    () async {
      final fake = JellyfinFakeServer();
      await fake.start();
      final auth = AuthController(
        client: JellyfinClient(device: _device),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      try {
        final id = await _login(auth, fake);
        await auth.loadLibraryCounts();
        final selected = auth.session;
        final retained = auth.client;
        fake.nextStatus = 500;
        await auth.switchTo(id);
        expect(auth.failure, isNotNull);
        expect(auth.session, same(selected));
        expect(auth.client, same(retained));
        expect((await retained.getItem('movie-1')).id, 'movie-1');
        retained.onSessionExpired!();
        expect(auth.session, isNull);
      } finally {
        auth.dispose();
        await fake.close();
      }
    },
  );

  for (final operation in ['restore', 'refresh']) {
    test(
      'late $operation credential read cannot replace new selection',
      () async {
        final a = JellyfinFakeServer()..serverId = 'a';
        final b = JellyfinFakeServer()..serverId = 'b';
        await a.start();
        await b.start();
        final credentials = _HeldCredentials();
        final auth = AuthController(
          client: JellyfinClient(device: _device),
          credentials: credentials,
          servers: MemoryServerListStore(),
        );
        try {
          final aid = await _login(auth, a);
          final bid = await _login(auth, b);
          await auth.loadLibraryCounts();
          final before = await credentials.read(bid);
          final gate = Completer<void>();
          credentials.heldSource = bid;
          credentials.gate = gate;
          final pending = operation == 'restore'
              ? auth.restore().then((_) => false)
              : auth.client.onRefreshSession!();
          await credentials.entered.future;
          await auth.switchTo(aid);
          final selected = auth.session;
          gate.complete();
          expect(await pending, isFalse);
          expect(auth.session, same(selected));
          expect(auth.session?.server.id, aid);
          expect(
            (await credentials.read(bid))?.accessToken,
            before?.accessToken,
          );
        } finally {
          auth.dispose();
          await a.close();
          await b.close();
        }
      },
    );
  }

  test(
    'reattached Emby request cannot borrow later session callbacks',
    () async {
      final dio = Dio();
      final client = EmbyClient(device: _device, dio: dio);
      final entered = Completer<void>();
      final gate = Completer<void>();
      var expired = 0;
      var refreshed = 0;
      client.attachSession(
        baseUrl: Uri.parse('http://127.0.0.1'),
        accessToken: 'old',
        userId: 'old-user',
      );
      client.onSessionExpired = () {};
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            entered.complete();
            await gate.future;
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 401),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final rejection = expectLater(client.getItem('movie'), throwsA(anything));
      await entered.future;
      client.attachSession(
        baseUrl: Uri.parse('http://127.0.0.1'),
        accessToken: 'new',
        userId: 'new-user',
      );
      client.onSessionExpired = () => expired++;
      client.onRefreshSession = () async {
        refreshed++;
        return false;
      };
      gate.complete();
      await rejection;
      expect(expired, 0);
      expect(refreshed, 0);
      expect(client.accessToken, 'new');
      dio.close(force: true);
    },
  );
}
