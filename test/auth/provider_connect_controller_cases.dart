import '../helpers/server_access_fixture.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';

import '../jellyfin/fake_jellyfin_server.dart';
import '../emby/fake_emby_server.dart';
import '../plex/fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'test-device',
  version: 'test',
);

Future<void> waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Authorization did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class DelayedServerStore extends MemoryServerListStore {
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    final pending = gate;
    if (pending != null) {
      entered?.complete();
      await pending.future;
      gate = null;
    }
    await super.save(snapshot);
  }
}

void main() {
  test(
    'Emby guarded password failure recovers into a verified source',
    () async {
      final fake = FakeEmbyServer();
      final adapter = FakeEmbyAdapter([fake]);
      EmbyClient client() =>
          EmbyClient(device: device, dio: dioForFakeEmby(adapter));
      final auth = AuthController(
        serverAccess: TestServerAccessController(),
        client: client(),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
        providerClientFactory: (_) => client(),
      );
      final controller = ProviderConnectController(
        pollInterval: const Duration(milliseconds: 10),
        auth: auth,
      );
      try {
        await controller.password(fake.baseUrl.toString(), 'alice', 'wrong');
        expect(controller.failure, MediaServerFailureKind.invalidCredentials);
        expect(auth.sources.project(), isEmpty);
        await controller.password(
          fake.baseUrl.toString(),
          'alice',
          'correct-horse',
        );
        expect(controller.failure, isNull);
        expect(controller.stage, ProviderConnectStage.done);
        await controller.finish();
        expect(controller.failure, isNull);
        expect(auth.session?.server.verifiedServerId, fake.serverId);
        expect(auth.client.serviceType, MediaServerType.emby);
      } finally {
        controller.dispose();
        auth.dispose();
      }
    },
  );

  group('Jellyfin product transaction', () {
    late JellyfinFakeServer fake;
    late AuthController auth;
    late ProviderConnectController controller;
    setUp(() async {
      fake = JellyfinFakeServer();
      await fake.start();
      auth = AuthController.memory(client: JellyfinClient(device: device));
      controller = ProviderConnectController(
        pollInterval: const Duration(milliseconds: 10),
        auth: auth,
      )..reset(MediaServerType.jellyfin);
    });
    tearDown(() async {
      controller.dispose();
      auth.dispose();
      await fake.close();
      expect(fake.violations, isEmpty);
    });

    test(
      'password commit directly activates Jellyfin without a library scope',
      () async {
        await controller.password(fake.url.toString(), 'alice', 'password');
        expect(controller.failure, isNull);
        expect(controller.stage, ProviderConnectStage.done);
        expect(
          auth.sources.project().single.toJson().containsKey('scopeKnown'),
          isFalse,
        );

        await controller.finish();
        expect(controller.failure, isNull);
        expect(controller.stage, ProviderConnectStage.done);
        expect(auth.client.serviceType, MediaServerType.jellyfin);
        expect(auth.session!.userId, 'alice-id');
        expect(
          auth.savedServers.single.toJson().containsKey('libraryIds'),
          isFalse,
        );
      },
    );

    test('saved Jellyfin identity is checked before password, switch, restore and cold acquisition', () async {
      await controller.password(fake.url.toString(), 'alice', 'password');
      expect(controller.failure, isNull);
      while (auth.libraryCountsLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final saved = auth.savedServers.single;
      fake.serverId = 'impostor-jellyfin';
      fake.requests.clear();
      final reauth = ProviderConnectController(auth: auth, existing: saved);
      addTearDown(reauth.dispose);
      await reauth.password(fake.url.toString(), 'alice', 'password');
      expect(reauth.failure, MediaServerFailureKind.incompatibleServer);
      await auth.switchTo(saved.id);
      expect(auth.failure?.kind, MediaServerFailureKind.incompatibleServer);
      final cold = AuthController(
        client: JellyfinClient(device: device),
        credentials: auth.credentials,
        servers: auth.sources.store,
      );
      addTearDown(cold.dispose);
      await cold.restore();
      expect(cold.isLoggedIn, isFalse);
      await expectLater(
        cold.sources.ensureSession(saved.id),
        throwsA(isA<MediaServerException>()),
      );
      expect(
        fake.requests.map((r) => r.path),
        everyElement(endsWith('/System/Info/Public')),
      );
      expect(
        fake.requests.any((r) => r.authorization?.contains('Token=') == true),
        isFalse,
      );
    });

    test(
      'wrong password and disabled Quick Connect remain recoverable',
      () async {
        await controller.password(fake.url.toString(), 'alice', 'bad');
        expect(controller.failure, MediaServerFailureKind.invalidCredentials);
        expect(auth.sources.project(), isEmpty);
        fake.quickEnabled = false;
        await controller.authorize(fake.url.toString());
        expect(controller.failure, MediaServerFailureKind.unsupported);
        await controller.password(fake.url.toString(), 'alice', 'password');
        expect(controller.stage, ProviderConnectStage.done);
      },
    );

    test('cancel discards a delayed password response', () async {
      final delayed = Completer<void>();
      fake.delay = delayed;
      fake.arrived = Completer<void>();
      final login = controller.password(
        fake.url.toString(),
        'alice',
        'password',
      );
      await fake.arrived!.future;
      controller.reset();
      delayed.complete();
      await login;
      expect(auth.sources.project(), isEmpty);
      expect(controller.stage, ProviderConnectStage.credentials);
    });

    test(
      'Quick Connect exchanges authorization before library discovery',
      () async {
        fake.quickAuthorized = true;
        await controller.authorize(fake.url.toString());
        expect(controller.attempt!.code, isNotEmpty);
        await waitFor(
          () =>
              controller.stage == ProviderConnectStage.done ||
              controller.failure != null,
        );
        expect(controller.failure, isNull);
        expect(
          auth.sources.project().single.serviceType,
          MediaServerType.jellyfin,
        );
      },
    );

    test('cancelled server addition discards delayed authentication', () async {
      controller.dispose();
      controller = ProviderConnectController(
        pollInterval: const Duration(milliseconds: 10),
        auth: auth,
      )..reset(MediaServerType.jellyfin);
      final delayed = Completer<void>();
      fake.delay = delayed;
      fake.arrived = Completer<void>();
      final login = controller.password(
        fake.url.toString(),
        'alice',
        'password',
      );
      await fake.arrived!.future;
      controller.reset(MediaServerType.jellyfin);
      delayed.complete();
      await login;
      expect(auth.sources.project(), isEmpty);
      expect(auth.savedServers, isEmpty);
      expect(controller.stage, ProviderConnectStage.credentials);
    });

    test(
      'cancel during authorization save rolls back and cannot activate later',
      () async {
        controller.dispose();
        auth.dispose();
        final store = DelayedServerStore();
        auth = AuthController(
          serverAccess: TestServerAccessController(),
          client: JellyfinClient(device: device),
          credentials: MemoryCredentialStore(),
          servers: store,
        );
        controller = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
        )..reset(MediaServerType.jellyfin);
        store.gate = Completer<void>();
        store.entered = Completer<void>();
        final finishing = controller.password(
          fake.url.toString(),
          'alice',
          'password',
        );
        await store.entered!.future;
        controller.reset();
        store.gate!.complete();
        await finishing;
        expect(auth.session, isNull);
        expect(controller.stage, ProviderConnectStage.credentials);
      },
    );
  });

  test(
    'Plex PIN, wrong Home PIN, resource token and library activation',
    () async {
      final fake = FakePlex();
      await fake.start();
      final credentials = MemoryCredentialStore();
      final cloud = CloudCredentialStore(credentials);
      final plex = PlexAuthentication(
        device: device,
        accountUrl: fake.url,
        homeUrl: fake.url,
        readCredential: cloud.readCredential,
        writeCredential: cloud.writeCredential,
        deleteCredential: cloud.deleteCredential,
      );
      final auth = AuthController(
        serverAccess: TestServerAccessController(),
        client: PlexClient(device: device),
        credentials: credentials,
        servers: MemoryServerListStore(),
        plexAuthentication: plex,
      );
      var controller = ProviderConnectController(
        pollInterval: const Duration(milliseconds: 10),
        auth: auth,
      )..reset(MediaServerType.plex);
      try {
        fake.authorized = true;
        await controller.authorize('');
        await waitFor(
          () =>
              controller.stage == ProviderConnectStage.resources ||
              controller.failure != null,
        );
        expect(controller.failure, isNull);
        expect(auth.sources.project(), isEmpty);
        expect(
          await cloud.readCredential(controller.account!.credentialRef),
          isNull,
          reason:
              'Discovery stays in the candidate overlay until resource commit',
        );
        final ownerResource = controller.resources.single;
        await controller.selectResource(
          ownerResource,
          ownerResource.connections.first,
        );
        expect(controller.failure, isNull);

        await controller.finish();
        expect(
          auth.savedServers.single.toJson().containsKey('libraryIds'),
          isFalse,
        );
        final browse = BrowseController(
          auth: auth,
          cache: CatalogCache(),
          parentId: 'section:1',
        );
        try {
          await browse.load();
          expect(browse.sortBy, 'DateCreated');
          expect(browse.error, isNull);
          expect(browse.items, isNotEmpty);
          expect(
            fake.requests.any(
              (request) =>
                  request.path == '/library/sections/1/all' &&
                  request.query['sort'] == 'addedAt:desc',
            ),
            isTrue,
          );
          // An explicitly requested unsupported meaning remains an error,
          // rather than silently becoming "date added".
          await browse.filter(sortBy: 'DateLastContentAdded');
          expect(browse.error?.kind, MediaServerFailureKind.unsupported);
          expect(browse.sortBy, 'DateLastContentAdded');
        } finally {
          browse.dispose();
        }
        fake.includeAlternateConnection = true;
        final sourceId = auth.savedServers.single.id;
        await auth.addLine(sourceId, '${fake.url}/alternate');
        for (final line in auth.savedServers.single.lines) {
          await auth.sources.renameLine(sourceId, line.id, 'Name-${line.id}');
        }
        await auth.refreshServers();
        final saved = auth.savedServers.single;
        final originalLines = saved.lines.map((l) => l.toJson()).toList();
        controller.dispose();
        controller = ProviderConnectController(
          pollInterval: const Duration(milliseconds: 10),
          auth: auth,
          existing: saved,
        );
        await controller.restoreHome();
        expect(controller.failure, isNull);
        expect(controller.resources, isEmpty);
        expect(auth.session!.userId, isNotEmpty);
        final home = controller.users.last;
        await controller.selectHome(home, 'bad');
        expect(controller.failure, MediaServerFailureKind.forbidden);
        expect(controller.resources, isEmpty);
        await controller.selectHome(home, '1234');
        expect(controller.failure, isNull);
        final resource = controller.resources.single;
        expect(resource.homeUserId, home.id);
        await controller.selectResource(resource, resource.connections.first);
        expect(controller.failure, isNull);
        expect(controller.stage, ProviderConnectStage.done);
        expect(
          auth.sources.project().single.toJson().containsKey('scopeKnown'),
          isFalse,
        );

        await controller.finish();
        expect(controller.failure, isNull);
        expect(auth.session!.userId, home.id);
        expect(auth.session!.accessToken, 'child-resource');
        expect(
          auth.savedServers.single.lines.map((l) => l.toJson()).toList(),
          originalLines,
        );
        controller.dispose();
        controller = ProviderConnectController(
          auth: auth,
          existing: auth.savedServers.single,
          pollInterval: const Duration(milliseconds: 10),
        );
        await controller.authorize('');
        await waitFor(
          () =>
              controller.stage == ProviderConnectStage.resources ||
              controller.failure != null,
        );
        expect(controller.failure, isNull);
        final reauthorized = controller.resources.single;
        await controller.selectResource(
          reauthorized,
          reauthorized.connections.first,
        );
        expect(controller.failure, isNull);
        expect(
          auth.savedServers.single.lines.map((l) => l.toJson()).toList(),
          originalLines,
        );
      } finally {
        controller.dispose();
        auth.dispose();
        await fake.close();
      }
    },
  );
}
