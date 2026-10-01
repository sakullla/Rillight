import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'player-process stop drops decoded images and leaves the browse cache',
    () async {
      const decodedKey = 'episode-decoded';
      const imageId = (
        serverId: 'server',
        itemId: 'episode',
        type: 'Primary',
        maxWidth: 120,
      );
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      addTearDown(() {
        MediaImage.debugResetCacheConfiguration();
        configurePaintingImageCache(playerProcess: false);
        PaintingBinding.instance.imageCache.clear();
      });

      configurePaintingImageCache(playerProcess: true);
      await MediaImageCache.instance.load(
        serverId: imageId.serverId,
        itemId: imageId.itemId,
        type: imageId.type,
        maxWidth: imageId.maxWidth,
        fetch: () async => bytes,
      );
      await _retainDecodedFrame(decodedKey);
      expect(_peek(imageId), bytes);
      expect(
        PaintingBinding.instance.imageCache.containsKey(decodedKey),
        isTrue,
      );

      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => _IdleCore(),
      );
      addTearDown(backend.dispose);
      await backend.stop();
      expect(_peek(imageId), isNull);
      expect(
        PaintingBinding.instance.imageCache.containsKey(decodedKey),
        isFalse,
      );

      MediaImage.debugResetCacheConfiguration();
      configurePaintingImageCache(playerProcess: false);
      await MediaImageCache.instance.load(
        serverId: imageId.serverId,
        itemId: imageId.itemId,
        type: imageId.type,
        maxWidth: imageId.maxWidth,
        fetch: () async => bytes,
      );
      await _retainDecodedFrame(decodedKey);
      await backend.stop();
      expect(_peek(imageId), bytes);
      expect(
        PaintingBinding.instance.imageCache.containsKey(decodedKey),
        isTrue,
      );
    },
  );
}

Uint8List? _peek(
  ({String serverId, String itemId, String type, int maxWidth}) id,
) {
  return MediaImageCache.instance.peek(
    serverId: id.serverId,
    itemId: id.itemId,
    type: id.type,
    maxWidth: id.maxWidth,
  );
}

Future<void> _retainDecodedFrame(Object key) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(2, 2);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      Future<ImageInfo>.value(ImageInfo(image: image)),
    ),
  );
  await Future<void>.delayed(Duration.zero);
}

class _IdleCore implements CorePlayer {
  @override
  Stream<CorePlayerEvent> get events => const Stream.empty();

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async => const {};

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async => const {};

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Widget buildView({Key? key}) => const SizedBox.shrink();

  @override
  Future<Map<String, dynamic>> surfaceStatus() async => const {};
}
