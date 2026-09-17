import 'dart:typed_data';

import 'package:rillight/media_image/media_image.dart';

/// Full-page fixtures must not use the user's disk cache or retain negative
/// image results from another fake server. Actual image/HTTP tests own theirs.
void isolateImageCache() {
  MediaImage.debugClearCache();
  MediaImage.debugResetCacheConfiguration();
  MediaImageCache.instance.debugSetDiskStore(_MemoryImageDisk());
}

class _MemoryImageDisk implements MediaImageDiskStore {
  final _bytes = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => _bytes[key];

  @override
  Future<void> write(String key, Uint8List data) async => _bytes[key] = data;

  @override
  Future<void> remove(String key) async => _bytes.remove(key);

  @override
  Future<void> clear() async => _bytes.clear();
}
