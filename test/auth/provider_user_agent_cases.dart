import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';

import '../jellyfin/fake_jellyfin_server.dart';
import '../plex/fake_plex.dart';

const _device = ClientDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);

Future<void> _discovered(ProviderConnectController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.stage != ProviderConnectStage.resources &&
      controller.failure == null) {
    if (DateTime.now().isAfter(deadline)) fail('Resource discovery timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(controller.failure, isNull);
}

void main() {
  test(
    'Plex UA is saved, modified and cleared through authorization and media',
    () async {
      final fake = FakePlex()..authorized = true;
      await fake.start();
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.next(request);
            },
          ),
        );
      final credentials = MemoryCredentialStore();
      final cloud = CloudCredentialStore(credentials);
      final auth = AuthController(
        client: PlexClient(device: _device, dio: dio),
        credentials: credentials,
        servers: MemoryServerListStore(),
        providerClientFactory: (_) => PlexClient(device: _device, dio: dio),
        plexAuthentication: PlexAuthentication(
          device: _device,
          dio: dio,
          accountUrl: fake.url,
          homeUrl: fake.url,
          readCredential: cloud.readCredential,
          writeCredential: cloud.writeCredential,
          deleteCredential: cloud.deleteCredential,
        ),
      );
      try {
        for (final ua in ['Custom-Plex/1', 'Custom-Plex/2', '']) {
          requests.clear();
          final previous = auth.savedServers.firstOrNull;
          final controller = ProviderConnectController(
            pollInterval: const Duration(milliseconds: 10),
            auth: auth,
            existing: previous,
          );
          expect(controller.userAgent, previous?.userAgent ?? '');
          controller.userAgent = ua;
          controller.reset(MediaServerType.plex);
          try {
            await controller.authorize('');
            await _discovered(controller);
            // Home exchange and resource rediscovery use the same configured UA.
            await controller.selectHome(controller.users.last, '1234');
            expect(controller.failure, isNull);
            final resource = controller.resources.single;
            await controller.selectResource(
              resource,
              resource.connections.first,
            );
            expect(controller.failure, isNull);
            controller.selectedLibraries.addAll(controller.libraries.keys);
            await controller.finish();
            expect(controller.failure, isNull);
            expect(
              auth.savedServers.single.normalizedUserAgent,
              normalizeUserAgent(ua),
            );
            final client = auth.client;
            expect(await client.getPrimaryImage('42'), fake.imageBytes);
            final info = await client.getPlaybackInfo(itemId: '42');
            final playback = client.resolvePlayback(info: info, itemId: '42')!;
            final expected = resolveUserAgent(ua, _device);
            expect(
              playback.authorization!.headersFor(fake.url)['User-Agent'],
              expected,
            );
            await info.resources?.release();
            expect(
              requests.any((r) => r.uri.path.endsWith('/api/v2/user')),
              isTrue,
            );
            expect(
              requests.any((r) => r.uri.path.endsWith('/identity')),
              isTrue,
            );
            expect(requests.any((r) => r.uri.path.contains('/thumb/')), isTrue);
            for (final request in requests) {
              expect(
                request.headers['User-Agent'],
                expected,
                reason: request.uri.path,
              );
            }
          } finally {
            controller.dispose();
          }
        }
      } finally {
        auth.dispose();
        dio.close(force: true);
        await fake.close();
      }
    },
  );

  test('Jellyfin reauthentication explicitly clears an existing UA', () async {
    final fake = JellyfinFakeServer();
    await fake.start();
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.next(request);
          },
        ),
      );
    final auth = AuthController(
      client: JellyfinClient(device: _device, dio: dio),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
      providerClientFactory: (_) => JellyfinClient(device: _device, dio: dio),
    );
    try {
      for (final ua in ['Custom-Jellyfin/1', '']) {
        requests.clear();
        final previous = auth.savedServers.firstOrNull;
        final controller = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
          existing: previous,
        )..reset(MediaServerType.jellyfin);
        expect(controller.userAgent, previous?.userAgent ?? '');
        controller.userAgent = ua;
        try {
          await controller.password(fake.url.toString(), 'alice', 'password');
          expect(controller.failure, isNull);
          await controller.finish();
          expect(controller.failure, isNull);
          expect(
            auth.savedServers.single.normalizedUserAgent,
            normalizeUserAgent(ua),
          );
          await auth.client.getPrimaryImage('movie-1');
          final info = await auth.client.getPlaybackInfo(itemId: 'movie-1');
          final playback = auth.client.resolvePlayback(
            info: info,
            itemId: 'movie-1',
          )!;
          final expected = resolveUserAgent(ua, _device);
          expect(
            playback.authorization!.headersFor(fake.url)['User-Agent'],
            expected,
          );
          await info.resources?.release();
          expect(
            requests.any(
              (r) => r.uri.path.endsWith('/Users/AuthenticateByName'),
            ),
            isTrue,
          );
          expect(requests.any((r) => r.uri.path.contains('/Images/')), isTrue);
          for (final request in requests) {
            expect(
              request.headers['User-Agent'],
              expected,
              reason: request.uri.path,
            );
          }
        } finally {
          controller.dispose();
        }
      }
      expect(fake.violations, isEmpty);
    } finally {
      auth.dispose();
      dio.close(force: true);
      await fake.close();
    }
  });
}
