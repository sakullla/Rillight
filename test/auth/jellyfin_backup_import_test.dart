import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/backup_import/backup_import.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_import_models.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';

import '../jellyfin/fake_jellyfin_server.dart';
import 'backup_import/backup_import_cases.dart' as fixture;

void main() {
  test(
    'imported Jellyfin password connects with Jellyfin protocol in place',
    () async {
      const device = ClientDeviceInfo(
        clientName: 'Rillight',
        deviceName: 'test',
        deviceId: 'import-jellyfin',
        version: '1.0.0',
      );
      final server = JellyfinFakeServer();
      await server.start();
      final store = MemoryServerListStore();
      final auth = AuthController(
        client: EmbyClient(device: device),
        credentials: MemoryCredentialStore(),
        servers: store,
        providerClientFactory: (type) => type == MediaServerType.jellyfin
            ? JellyfinClient(device: device)
            : EmbyClient(device: device),
      );
      addTearDown(() async {
        auth.dispose();
        await server.close();
      });
      await auth.restore();
      final bytes = await fixture.buildCommonConfig([
        fixture.commonEntry(
          type: 'jellyfin',
          name: 'Synthetic Jellyfin',
          url: server.url.toString(),
          authorization: {'user_name': 'alice', 'password': 'password'},
        ),
      ], selfKey: fixture.selfCarriedTestKey);
      final parsed = await parseBackupForImport(bytes);
      final imported = await auth.importServers(parsed.drafts);
      expect(imported.count(ServerImportStatus.added), 1);
      final id = imported.items.single.serverId!;
      expect(server.requests, isEmpty, reason: 'Import is offline');
      expect(auth.savedServers.single.serviceType, MediaServerType.jellyfin);
      await auth.switchTo(id);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.client.serviceType, MediaServerType.jellyfin);
      expect(auth.session!.server.id, id);
      expect((await store.load()).servers.single.identityPending, isFalse);
      expect(server.violations, isEmpty);
    },
  );
}
