import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/session_subtitle_files.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart'
    show SourceReference;
import 'package:rillight/player/player_host_command.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../helpers/synthetic_source_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-subtitle-menu',
  version: '0.1.0',
);

void main() {
  setUp(isolateImageCache);
  late RillightApp app;
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;
  late MemoryPlaybackSessionSnapshotStore snapshots;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
    snapshots = MemoryPlaybackSessionSnapshotStore();
  });

  PlayerBindings bindings(PlaybackRuntime? runtime) {
    return PlayerBindings(
      runtime: runtime,
      createBackend: () => backend,
      window: window,
      controlsHideAfter: const Duration(days: 1),
      snapshotStore: snapshots,
      settingsStore: MemoryPlayerSettingsStore(),
    );
  }

  Future<void> pumpLoggedIn(WidgetTester tester) async {
    final auth = SyntheticSourceAuth(
      adapter: adapter,
      device: _device,
      libraryIds: {'view-movies', 'view-tv'},
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    final runtime = await tester.runAsync(auth.runtime);
    app = RillightApp(auth: auth, playerBindings: bindings(runtime));
    await tester.pumpWidget(app);
    await settle(tester);
  }

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    final libraryId = server.items
        .firstWhere((item) => item.id == itemId)
        .parentId!;
    final account = await tester.runAsync(
      () => app.auth.sources.acquireAccount(
        app.auth.session!.server.id,
        region: AccessRegion.ordinary,
        libraryId: libraryId,
      ),
    );
    final permit = app.auth.sources.permit(account!, libraryId: libraryId);
    app.router.go(
      '/item/$itemId',
      extra: PlayerHostOpenItemCommand(
        itemId: itemId,
        source: SourceReference(account: account, itemId: itemId),
        libraryId: libraryId,
        regionGeneration: permit.regionGeneration,
      ),
    );
    await tester.pumpWidget(app);
    await settle(tester);
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      if (find.byKey(PlayerKeys.playPause).evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('player controls did not appear');
  }

  PlayerController controllerOf(WidgetTester tester) {
    return tester.state<PlayerPageState>(find.byType(PlayerPage)).controller!;
  }

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.runAsync(
      () => app.windowHost.close().timeout(const Duration(seconds: 5)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    app.router.dispose();
    await tester.pump();
    await tester.runAsync(
      () => app.playerBindings.runtime!.history.close().timeout(
        const Duration(seconds: 5),
      ),
    );
    app.auth.dispose();
  }

  void withTwoSubtitleStreams() {
    final item = server.items.firstWhere((entry) => entry.id == 'movie-up');
    item.mediaStreams = const [
      FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
      FakeMediaStream(
        index: 1,
        type: 'Audio',
        codec: 'aac',
        language: 'jpn',
        displayTitle: 'Japanese',
        isDefault: true,
      ),
      FakeMediaStream(
        index: 2,
        type: 'Subtitle',
        codec: 'ass',
        language: 'chi',
        displayTitle: '中文',
        isDefault: true,
        isTextSubtitleStream: true,
      ),
      FakeMediaStream(
        index: 3,
        type: 'Subtitle',
        codec: 'subrip',
        language: 'eng',
        displayTitle: 'English',
        isTextSubtitleStream: true,
      ),
    ];
  }

  testWidgets(
    'desktop subtitle menu edits both slots and imports a local file',
    (tester) async {
      withTwoSubtitleStreams();
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      final controller = controllerOf(tester);
      controller.onUserActivity();
      await tester.pumpAndSettle();
      expect(controller.subtitleStreamIndex, 2);
      expect(controller.secondarySubtitleStreamIndex, isNull);

      await tester.tap(find.byKey(PlayerKeys.subtitle));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-subtitle-panel')), findsOneWidget);
      expect(find.byKey(const Key('player-subtitle-import')), findsOneWidget);
      expect(
        find.byKey(const Key('player-subtitle-slot-primary')),
        findsOneWidget,
      );

      // 切到次字幕槽并选择 English:主字幕保持不变。
      await tester.tap(find.text('次字幕').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-subtitle-slot-secondary')),
        findsOneWidget,
      );
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(controller.secondarySubtitleStreamIndex, 3);
      expect(backend.secondarySubtitleIndex, 3);
      expect(controller.subtitleStreamIndex, 2);
      // 选择后菜单关闭并交还焦点。
      expect(find.byKey(const Key('player-subtitle-panel')), findsNothing);

      // 主槽选择已被次槽占用的来源时被拒绝并提示。
      await tester.tap(find.byKey(PlayerKeys.subtitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主字幕').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-subtitle-slot-primary')),
        findsOneWidget,
      );
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(controller.subtitleStreamIndex, 2, reason: '被次槽占用的来源在主槽不可选');
      expect(find.text('该来源已在另一字幕槽位使用'), findsWidgets);
      final englishTile = find.ancestor(
        of: find.text('English').last,
        matching: find.byType(ListTile),
      );
      expect(
        tester.widget<ListTile>(englishTile).onTap,
        isNull,
        reason: '被占用的选项直接禁用',
      );

      // 会话导入:注入假选择器,导入后文件进入两槽候选列表。
      const srt = '1\n00:00:01,000 --> 00:00:02,000\n导入的本地字幕\n';
      await tester.runAsync(() async {
        controller.subtitleFilePicker = _StaticPicker(
          Uint8List.fromList(utf8.encode(srt)),
          'local.srt',
        );
        final outcome = await controller.importSubtitleFile();
        expect(outcome, SubtitleImportOutcome.added);
      });
      await tester.pumpAndSettle();
      expect(controller.sessionSubtitleFiles, hasLength(1));
      final imported = controller.sessionSubtitleFiles.single;

      await tester.tap(find.text('local.srt').last);
      await tester.pumpAndSettle();
      expect(controller.primarySubtitleFileId, imported.id);
      expect(controller.subtitleStreamIndex, isNull);
      expect(backend.subtitleUri?.scheme, 'file');
      expect(backend.secondarySubtitleIndex, 3, reason: '主槽换文件不影响次字幕');
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    },
    tags: ['integration'],
  );
}

class _StaticPicker implements AppFilePicker {
  _StaticPicker(this.bytes, this.fileName);

  final Uint8List bytes;
  final String fileName;

  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    return PickedAppFile(
      fileName: fileName,
      length: bytes.length,
      read: (limit) async => bytes,
    );
  }
}
