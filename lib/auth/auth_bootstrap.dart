import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/windows_credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/pin_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

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
    device: EmbyDeviceInfo(
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
  final access = RegionAccessController(verifier: await pinStore.load());
  final sources = SourceSessionRegistry(
    access: access,
    store: servers,
    credentials: credentials,
    createClient: () => EmbyClient(device: client.device),
  );
  await sources.load();
  final controller = AuthController(
    client: client,
    credentials: credentials,
    servers: servers,
    sources: sources,
    persistPin: pinStore.save,
  );
  await controller.restore();
  return controller;
}
