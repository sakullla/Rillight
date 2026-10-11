import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/seek_preview.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart' show kTinyPng;
import '../helpers/image_cache_fixture.dart';

class _Preview implements MediaPreview {
  _Preview(this.itemId);
  @override
  final String itemId;
  Future<PreviewFrame?> Function(Duration) read = (_) async =>
      PreviewFrame(bytes: kTinyPng);
  @override
  CapabilityStatus get availability => const CapabilityStatus(
    CapabilityAvailability.available,
    reason: 'Synthetic preview',
  );
  @override
  Future<PreviewFrame?> frameAt(Duration position) => read(position);
  @override
  Future<void> close() async {}
}

class _PreviewClient implements MediaServerClient {
  final previews = <String, _Preview>{};
  final chapterRequests = <(String, int)>[];
  @override
  Future<MediaPreview?> openPreview(String itemId) async =>
      previews.putIfAbsent(itemId, () => _Preview(itemId));
  @override
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  }) async {
    chapterRequests.add((itemId, index));
    return kTinyPng;
  }

  @override
  bool get hasSession => true;
  @override
  Uri get baseUrl => Uri.parse('https://preview.invalid');
  @override
  String get userId => 'synthetic';
  @override
  MediaServerClient createDetached() => this;
  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late _PreviewClient client;
  late PlayerController controller;
  late AuthController auth;
  late double selected;

  setUp(() {
    isolateImageCache();
    selected = 0;
    client = _PreviewClient();
    auth = AuthController.memory(client: client);
    controller = PlayerController(
      client: client,
      itemId: 'first',
      backend: FakeVideoBackend(),
      window: PlayerWindow(),
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    )..duration = const Duration(minutes: 10);
  });

  tearDown(() {
    controller.dispose();
    auth.dispose();
    MediaImage.debugClearCache();
    MediaImage.debugResetCacheConfiguration();
  });

  Widget subject(double fraction) => MaterialApp(
    home: AuthScope(
      controller: auth,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: SeekPreview(
              controller: controller,
              dragValue: fraction,
              child: Slider(value: fraction, onChanged: (v) => selected = v),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> moveTo(WidgetTester tester, double fraction) async {
    await tester.pumpWidget(subject(fraction));
    await tester.pump(const Duration(milliseconds: 151));
    // Tile decoding completes through the engine outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Future<_Preview> showFrame(WidgetTester tester) async {
    await tester.pumpWidget(subject(0));
    await moveTo(tester, .25);
    expect(find.byType(Image), findsOneWidget);
    return client.previews['first']!;
  }

  for (final failure in [
    'frame request',
    'damaged tile',
    'out of bounds tile',
  ]) {
    testWidgets('$failure clears the old preview and preserves slider input', (
      tester,
    ) async {
      final preview = await showFrame(tester);
      preview.read = (_) async {
        if (failure == 'frame request') throw StateError('Frame unavailable');
        return PreviewFrame(
          bytes: failure == 'damaged tile' ? kTinyPng.sublist(0, 8) : kTinyPng,
          tile: PreviewTile(
            x: failure == 'out of bounds tile' ? 999 : 0,
            y: 0,
            width: 1,
            height: 1,
          ),
        );
      };
      await moveTo(tester, .75);
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsNothing);
      expect(find.text('07:30'), findsOneWidget);
      await tester.tap(find.byType(Slider));
      expect(selected, closeTo(.5, .02));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('frame failure falls back to the real chapter image', (
    tester,
  ) async {
    final preview = await showFrame(tester);
    controller.item = const MediaItem(
      id: 'first',
      name: 'Film',
      type: 'Movie',
      chapters: [
        ItemChapter(
          name: 'Chapter',
          startPosition: Duration(minutes: 5),
          imageTag: 'chapter-tag',
          imageIndex: 4,
        ),
      ],
    );
    preview.read = (_) async => throw StateError('Frame unavailable');
    await moveTo(tester, .75);
    expect(tester.takeException(), isNull);
    expect(client.chapterRequests, [('first', 4)]);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final boundary in ['new position', 'new item', 'disposed']) {
    testWidgets('late frame failure cannot mutate preview after $boundary', (
      tester,
    ) async {
      final preview = await showFrame(tester);
      final pending = Completer<PreviewFrame?>();
      preview.read = (_) => pending.future;
      await moveTo(tester, .5);
      preview.read = (_) async => PreviewFrame(bytes: kTinyPng);
      if (boundary == 'disposed') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        if (boundary == 'new item') controller.itemId = 'second';
        await moveTo(tester, .75);
        expect(find.byType(Image), findsOneWidget);
      }
      pending.completeError(StateError('Late unavailable frame'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (boundary != 'disposed') {
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('07:30'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
