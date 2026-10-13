import '../helpers/region_access_fixture.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

import '../emby/fake_emby_server.dart';

class _HeldAdapter extends FakeEmbyAdapter {
  _HeldAdapter(super.servers);
  Completer<void>? gate;
  final arrived = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    final response = await super.fetch(options, stream, cancelled);
    if (gate case final pending?) {
      if (!arrived.isCompleted) arrived.complete();
      await pending.future;
    }
    return response;
  }
}

void main() {
  late AuthController auth;
  late FakeEmbyServer primary, other, alternate;
  late _HeldAdapter adapter;
  setUp(() {
    primary = FakeEmbyServer();
    other = FakeEmbyServer(
      serverId: 'another-server',
      baseUrl: Uri.parse('http://another.test'),
    );
    alternate = FakeEmbyServer(baseUrl: Uri.parse('http://alternate.test'));
    adapter = _HeldAdapter([primary, other, alternate]);
    EmbyClient client() => EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'line-test',
        version: '1',
      ),
      dio: dioForFakeEmby(adapter),
    );
    auth = AuthController(
      regionAccess: TestRegionAccessController(),
      client: client(),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
      providerClientFactory: (_) => client(),
    );
  });
  tearDown(() => auth.dispose());

  Future<String> privateSource() async {
    await auth.setPrivatePin('1234', '1234');
    await auth.regionAccess.unlock('1234');
    final login = ProviderConnectController(
      pollInterval: const Duration(milliseconds: 10),
      auth: auth,
      region: AccessRegion.private,
    );
    await login.password(primary.baseUrl.toString(), 'alice', 'correct-horse');
    expect(login.failure, isNull);
    await login.finish();
    final id = login.sourceId!;
    login.dispose();
    return id;
  }

  test(
    'private line rejects another server and preserves the configured address',
    () async {
      final id = await privateSource();
      final original = auth.sources
          .project(AccessRegion.private)
          .single
          .lines
          .single;
      await expectLater(
        auth.sources.setLineAddress(
          id,
          other.baseUrl.toString(),
          lineId: original.id,
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        auth.sources.project(AccessRegion.private).single.lines.single.address,
        original.address,
      );
      expect(auth.session, isNull);
    },
  );

  test(
    'private lock rejects a late verified line without persisting it',
    () async {
      final id = await privateSource();
      adapter.gate = Completer<void>();
      final pending = auth.sources.setLineAddress(
        id,
        alternate.baseUrl.toString(),
      );
      final checked = expectLater(pending, throwsStateError);
      await adapter.arrived.future;
      await auth.regionAccess.lock();
      adapter.gate!.complete();
      await checked;
      await auth.regionAccess.unlock('1234');
      expect(
        auth.sources.project(AccessRegion.private).single.lines,
        hasLength(1),
      );
    },
  );

  test(
    'cancelled Emby prelogin drops its late response and publishes no credential',
    () async {
      final login = ProviderConnectController(
        pollInterval: const Duration(milliseconds: 10),
        auth: auth,
      );
      adapter.gate = Completer<void>();
      final pending = login.password(
        primary.baseUrl.toString(),
        'alice',
        'correct-horse',
      );
      await adapter.arrived.future;
      login.dispose();
      adapter.gate!.complete();
      await pending;
      expect(auth.sources.project(AccessRegion.ordinary), isEmpty);
      expect(auth.session, isNull);
      expect(auth.client.hasSession, isFalse);
    },
  );

  test(
    'Emby prelogin guard cloning preserves both authority guards and transport',
    () async {
      var originalValid = true;
      final guarded = auth.client
          .withRequestGuard(() {
            if (!originalValid) throw StateError('revoked original');
          })
          .withRequestGuard(() {});
      expect(
        (await guarded.getPublicInfo(primary.baseUrl)).id,
        primary.serverId,
      );
      adapter.gate = Completer<void>();
      final pending = guarded.getPublicInfo(primary.baseUrl);
      final checked = expectLater(pending, throwsA(isA<Exception>()));
      await adapter.arrived.future;
      originalValid = false;
      adapter.gate!.complete();
      await checked;
      expect(guarded.hasSession, isFalse);
    },
  );
}
