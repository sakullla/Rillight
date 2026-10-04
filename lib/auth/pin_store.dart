import 'dart:convert';
import 'dart:io';

import 'region_access.dart';

/// Only stores the versioned salted verifier; unlocking is never persisted.
class FilePinStore {
  FilePinStore(this.file);
  final File file;
  Future<PinVerifier?> load() async {
    if (!await file.exists()) return null;
    // Corruption fails closed instead of silently disabling an existing PIN.
    return PinVerifier.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
    );
  }

  Future<void> save(PinVerifier verifier) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(verifier.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
