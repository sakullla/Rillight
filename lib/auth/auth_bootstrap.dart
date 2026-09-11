import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/windows_credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

Future<AuthController> createProductionAuth() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}/rillight');
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
  final controller = AuthController(
    client: client,
    credentials: windowsKeychainOrFallback(fallback),
    servers: FileServerListStore(File('${dir.path}/servers.json')),
  );
  await controller.restore();
  return controller;
}
