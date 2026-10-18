import 'dart:convert';
import 'dart:io';

import '../auth/credential_store.dart';

const kBackupFormat = 'rillight-backup';
const kBackupVersion = 1;

const kBackupServersFileName = 'servers.json';
const kBackupPinFileName = 'private_pin.json';
const kBackupWebDavFileName = 'webdav.json';
const kBackupCatalogCacheDirName = 'catalog_cache';

const kBackupPrefFileNames = <String, String>{
  'player_settings': 'player_settings.json',
  'phone_nav': 'phone_nav.json',
  'library_nav': 'library_nav.json',
  'tv_home_sections': 'tv_home_sections.json',
  'phone_home_sections': 'phone_home_sections.json',
  'recent_searches': 'recent_searches.json',
};

enum WebDavBackupError { unknownFormat, unsupportedVersion, malformed }

sealed class WebDavBundleValidation {
  const WebDavBundleValidation();
}

class WebDavBundleValid extends WebDavBundleValidation {
  const WebDavBundleValid(this.bundle);
  final Map<String, dynamic> bundle;
}

class WebDavBundleInvalid extends WebDavBundleValidation {
  const WebDavBundleInvalid(this.error);
  final WebDavBackupError error;
}

sealed class WebDavApplyResult {
  const WebDavApplyResult();
}

class WebDavApplySuccess extends WebDavApplyResult {
  const WebDavApplySuccess({required this.needsReload});
  final bool needsReload;
}

class WebDavApplyRejected extends WebDavApplyResult {
  const WebDavApplyRejected(this.error);
  final WebDavBackupError error;
}

Future<Map<String, dynamic>?> _readJsonOrNull(File file) async {
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Invalid local configuration document');
  }
  return Map<String, dynamic>.from(decoded);
}

/// Collects the local state into a `rillight-backup` v1 bundle document.
/// `device_id` and `catalog_cache/` never enter the bundle.
Future<Map<String, dynamic>> collectBackupBundle(
  Directory dir,
  CredentialStore credentialStore,
) async {
  final servers =
      await _readJsonOrNull(File('${dir.path}/$kBackupServersFileName')) ??
      <String, dynamic>{'servers': <Object?>[]};
  final ids = <String>{};
  final rawServers = servers['servers'];
  if (rawServers is List) {
    for (final item in rawServers) {
      final id = item is Map ? item['id'] : null;
      if (id is String && id.isNotEmpty) ids.add(id);
    }
  }
  final credentials = <String, dynamic>{};
  for (final id in ids) {
    final stored = await credentialStore.read(id);
    if (stored != null) credentials[id] = stored.toJson();
  }
  final prefs = <String, dynamic>{};
  for (final entry in kBackupPrefFileNames.entries) {
    final value = await _readJsonOrNull(File('${dir.path}/${entry.value}'));
    if (value != null) prefs[entry.key] = value;
  }
  final pin = await _readJsonOrNull(File('${dir.path}/$kBackupPinFileName'));
  final webdav = await _readJsonOrNull(
    File('${dir.path}/$kBackupWebDavFileName'),
  );
  return <String, dynamic>{
    'format': kBackupFormat,
    'version': kBackupVersion,
    'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'servers': servers,
    'credentials': credentials,
    'pin': ?pin,
    'prefs': prefs,
    'webdav': ?webdav,
  };
}

WebDavBundleValidation validateBackupDocument(Map<String, dynamic> bundle) {
  if (bundle['format'] != kBackupFormat) {
    return const WebDavBundleInvalid(WebDavBackupError.unknownFormat);
  }
  if (bundle['version'] != kBackupVersion) {
    return const WebDavBundleInvalid(WebDavBackupError.unsupportedVersion);
  }
  if (bundle['servers'] is! Map) {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  final credentials = bundle['credentials'];
  if (credentials is! Map || credentials.values.any((v) => v is! Map)) {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  final prefs = bundle['prefs'];
  if (prefs is! Map || prefs.values.any((v) => v is! Map)) {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  final pin = bundle['pin'];
  if (pin != null && pin is! Map) {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  final webdav = bundle['webdav'];
  if (webdav != null && webdav is! Map) {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  return WebDavBundleValid(bundle);
}

WebDavBundleValidation validateBackupBundle(List<int> bytes) {
  Map<String, dynamic> decoded;
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) {
      return const WebDavBundleInvalid(WebDavBackupError.malformed);
    }
    decoded = Map<String, dynamic>.from(value);
  } on Object {
    return const WebDavBundleInvalid(WebDavBackupError.malformed);
  }
  return validateBackupDocument(decoded);
}

/// Applies a bundle in place. Everything is validated (including credential
/// deserialization) before the first write, so a rejection writes nothing.
Future<WebDavApplyResult> applyBackupBundle(
  Map<String, dynamic> bundle,
  Directory dir,
  CredentialStore credentialStore,
) async {
  final validation = validateBackupDocument(bundle);
  if (validation is WebDavBundleInvalid) {
    return WebDavApplyRejected(validation.error);
  }
  final credentials = <String, StoredCredentials>{};
  for (final entry in (bundle['credentials'] as Map).entries) {
    try {
      credentials['${entry.key}'] = StoredCredentials.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    } on Object {
      return const WebDavApplyRejected(WebDavBackupError.malformed);
    }
  }
  await _writeJson(
    File('${dir.path}/$kBackupServersFileName'),
    bundle['servers']!,
  );
  for (final entry in kBackupPrefFileNames.entries) {
    final value = (bundle['prefs'] as Map)[entry.key];
    if (value != null) {
      await _writeJson(File('${dir.path}/${entry.value}'), value as Map);
    }
  }
  if (bundle['pin'] != null) {
    await _writeJson(
      File('${dir.path}/$kBackupPinFileName'),
      bundle['pin']! as Map,
    );
  }
  if (bundle['webdav'] != null) {
    await _writeJson(
      File('${dir.path}/$kBackupWebDavFileName'),
      bundle['webdav']! as Map,
    );
  }
  for (final entry in credentials.entries) {
    await credentialStore.write(entry.key, entry.value);
  }
  await _clearDirectoryContents(
    Directory('${dir.path}/$kBackupCatalogCacheDirName'),
  );
  return const WebDavApplySuccess(needsReload: true);
}

Future<WebDavApplyResult> applyBackupBundleBytes(
  List<int> bytes,
  Directory dir,
  CredentialStore credentialStore,
) async {
  final validation = validateBackupBundle(bytes);
  if (validation is WebDavBundleInvalid) {
    return WebDavApplyRejected(validation.error);
  }
  return applyBackupBundle(
    (validation as WebDavBundleValid).bundle,
    dir,
    credentialStore,
  );
}

Future<void> _writeJson(File file, Map value) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(file.path);
}

Future<void> _clearDirectoryContents(Directory directory) async {
  if (!await directory.exists()) return;
  await for (final child in directory.list()) {
    if (child is Directory) {
      await child.delete(recursive: true);
    } else {
      await child.delete();
    }
  }
}
