import 'dart:io';

import 'startup_recovery.dart';
export 'startup_recovery.dart';

import 'backup_import/environment_keys.dart';
import 'cloud_credentials.dart';
import 'provider_identity.dart';
import 'server_access_credentials.dart';
import 'server_configuration_migration.dart';
import '../media_server/provider_registry.dart';
import '../plex/plex_authentication.dart';

import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/windows_credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/pin_store.dart';

import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';

Future<AuthController> createProductionAuth() async {
  final validation = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
  if (validation != null &&
      (validation.isEmpty || !Directory(validation).isAbsolute)) {
    throw ArgumentError(
      'RILLIGHT_VALIDATION_DIRECTORY must be an absolute directory',
    );
  }
  final dir = validation != null
      ? Directory(validation)
      : Directory('${(await getApplicationSupportDirectory()).path}/rillight');
  await dir.create(recursive: true);

  final deviceId = await loadOrCreateDeviceId(File('${dir.path}/device_id'));
  final client = EmbyClient(
    device: ClientDeviceInfo(
      clientName: kHttpClientName,
      deviceName: Platform.operatingSystem,
      deviceId: deviceId,
      version: kAppVersion,
    ),
  );
  final fallback = FileCredentialStore(File('${dir.path}/credentials.json'));
  final credentials = validation != null
      ? fallback
      : windowsKeychainOrFallback(fallback);
  final servers = FileServerListStore(File('${dir.path}/servers.json'));
  final pinStore = FilePinStore(File('${dir.path}/private_pin.json'));
  final accessStore = CredentialServerAccessStore(credentials);
  try {
    await ServerConfigurationMigration(
      configuration: servers.file,
      credentials: credentials,
      accessStore: accessStore,
      readLegacyVerifier: () async => (await pinStore.load())?.toJson(),
    ).migrate();
  } catch (_) {
    throw ConfigurationUpgradeFailure(dir.path);
  }
  final access = ServerAccessController(store: accessStore);
  final cloud = CloudCredentialStore(credentials);
  final plex = PlexAuthentication(
    device: client.device,
    readCredential: cloud.readCredential,
    writeCredential: cloud.writeCredential,
    deleteCredential: cloud.deleteCredential,
  );
  final sources = SourceSessionRegistry(
    access: access,
    store: servers,
    credentials: credentials,
    createClient: client.createDetached,
    createProviderClient: (type) =>
        MediaServerProviders.create(type, client.device),
    sessionIdentityVerifier: (server, value, attached) =>
        verifyProviderIdentity(plex, server, value, attached),
  );
  await sources.load();
  final controller = AuthController(
    client: client,
    credentials: credentials,
    servers: servers,
    sources: sources,
    plexAuthentication: plex,
    providerClientFactory: (type) =>
        MediaServerProviders.create(type, client.device),
    serverAccess: access,
  );
  controller.backupImportKeys = defaultBackupImportKeys;
  // Public server info includes the version check. It must not hold the
  // startup spinner: the shell paints from the saved list, then confirms.
  await controller.restore(waitForNetwork: false);
  return controller;
}
