import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog-controller',
  version: '0.1.0',
);

void main() {
  test('logout then same-server login reloads home rows', () async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    final catalog = CatalogController(auth: auth);
    addTearDown(catalog.dispose);

    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await catalog.reload();
    final resumeBefore = server.requests
        .where((request) => request.contains('Items/Resume'))
        .length;

    await auth.logout();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      server.requests
          .where((request) => request.contains('Items/Resume'))
          .length,
      greaterThan(resumeBefore),
    );
  });
}
