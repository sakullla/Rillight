import 'dart:convert';
import 'dart:io';

import 'helpers/image_cache_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

/// File store merge-write, in memory. Widget tests cannot await
/// [FilePlayerSettingsStore] locks inside fake async without deadlocking.
class _MergingPlayerSettingsStore implements PlayerSettingsStore {
  _MergingPlayerSettingsStore(this._value);

  PlayerSettings _value;
  PlayerSettings? lastWrite;

  @override
  Future<PlayerSettings> read() async => _value;

  @override
  Future<void> write(PlayerSettings settings) async {
    lastWrite = settings;
    final merged = Map<String, dynamic>.from(_value.toJson());
    for (final entry in settings.toJson().entries) {
      final existing = merged[entry.key];
      merged[entry.key] = existing is Map && entry.value is Map
          ? <String, dynamic>{
              ...Map<String, dynamic>.from(existing),
              ...Map<String, dynamic>.from(entry.value),
            }
          : entry.value;
    }
    _value = PlayerSettings.fromJson(merged);
  }
}

void main() {
  setUp(isolateImageCache);

  File tempSettingsFile(String name) {
    final file = File(
      '${Directory.systemTemp.path}/rillight-settings-page-$name-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
      final lock = File('${file.path}.lock');
      if (lock.existsSync()) {
        lock.deleteSync();
      }
    });
    return file;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required PlayerSettingsStore store,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SettingsPage(settingsStore: store, platform: platform),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the stored settings', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        diskCacheLimitMiB: 4096,
        hardwareDecoding: HardwareDecodingMode.off,
      ),
    );
    await pumpPage(tester, store: store);

    expect(
      tester
          .widget<DropdownButton<int>>(
            find.byKey(SettingsPage.diskCacheLimitKey),
          )
          .value,
      4096,
    );
    expect(
      tester
          .widget<DropdownButton<HardwareDecodingMode>>(
            find.byKey(SettingsPage.hardwareDecodingKey),
          )
          .value,
      HardwareDecodingMode.off,
    );
    expect(
      tester
          .widget<DropdownButton<HardwareDecoderBackend>>(
            find.byKey(SettingsPage.decoderBackendKey),
          )
          .value,
      HardwareDecoderBackend.auto,
    );
  }, tags: ['integration']);

  testWidgets('changing the disk cache limit persists and echoes', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        diskCacheLimitMiB: 4096,
        hardwareDecoding: HardwareDecodingMode.off,
      ),
    );
    await pumpPage(tester, store: store);

    await tester.tap(find.byKey(SettingsPage.diskCacheLimitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.0 GB').last);
    await tester.pumpAndSettle();

    final settings = await store.read();
    expect(settings.diskCacheLimitMiB, 1024);
    // 其他已存字段不被清掉。
    expect(settings.hardwareDecoding, HardwareDecodingMode.off);
    expect(
      tester
          .widget<DropdownButton<int>>(
            find.byKey(SettingsPage.diskCacheLimitKey),
          )
          .value,
      1024,
    );
  }, tags: ['integration']);

  testWidgets('restore defaults writes explicit defaults', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        diskCacheLimitMiB: 4096,
        hardwareDecoding: HardwareDecodingMode.off,
        hardwareDecoder: HardwareDecoderBackend.nvdec,
      ),
    );
    await pumpPage(tester, store: store);

    await tester.tap(find.byKey(SettingsPage.restoreDefaultsKey));
    await tester.pumpAndSettle();

    final settings = await store.read();
    expect(settings.diskCacheLimitMiB, PlayerRuntimeDefaults.diskCacheLimitMiB);
    expect(settings.hardwareDecoding, HardwareDecodingMode.auto);
    expect(settings.hardwareDecoder, HardwareDecoderBackend.auto);
    // 音量不属于本页管理,恢复默认不覆盖已存音量。
    expect(settings.volume, 40);
  }, tags: ['integration']);

  testWidgets('shows stored danmaku service fields', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        danmakuServer: 'https://dan.example.com',
        danmakuAppId: 'app-id',
        danmakuToken: 'secret',
      ),
    );
    await pumpPage(tester, store: store);

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuServerFieldKey))
          .controller
          ?.text,
      'https://dan.example.com',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuAppIdFieldKey))
          .controller
          ?.text,
      'app-id',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuTokenFieldKey))
          .controller
          ?.text,
      'secret',
    );
  }, tags: ['integration']);

  testWidgets('changing danmaku service fields persists', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        diskCacheLimitMiB: 4096,
        danmakuServer: 'https://dan.example.com',
        danmakuAppId: 'app-id',
        danmakuToken: 'secret',
      ),
    );
    await pumpPage(tester, store: store);

    await tester.enterText(
      find.byKey(SettingsPage.danmakuServerFieldKey),
      'https://custom.example',
    );
    await tester.enterText(
      find.byKey(SettingsPage.danmakuAppIdFieldKey),
      'app-2',
    );
    await tester.enterText(
      find.byKey(SettingsPage.danmakuTokenFieldKey),
      'tok-2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    final settings = await store.read();
    expect(settings.danmakuServer, 'https://custom.example');
    expect(settings.danmakuAppId, 'app-2');
    expect(settings.danmakuToken, 'tok-2');
    expect(settings.volume, 40);
    expect(settings.diskCacheLimitMiB, 4096);
  }, tags: ['integration']);

  testWidgets('large font scale persists without rewriting other fields', (
    tester,
  ) async {
    const initial = PlayerSettings(
      volume: 42,
      diskCacheLimitMiB: 4096,
      danmakuServer: 'https://dan.example.com',
      danmakuAppId: 'app-id',
      danmakuToken: 'secret',
      danmakuDisplay: DanmakuDisplaySettings(fontScale: 1.0),
    );
    final file = tempSettingsFile('font-scale');
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(initial.toJson()),
    );
    final fileStore = FilePlayerSettingsStore(file);
    final store = _MergingPlayerSettingsStore(initial);
    await pumpPage(tester, store: store);

    final large = find.descendant(
      of: find.byKey(DanmakuKeys.fontScale),
      matching: find.text('大'),
    );
    await tester.ensureVisible(large);
    await tester.pump();
    await tester.tap(large);
    await tester.pump();

    final pageSettings = await store.read();
    expect(pageSettings.danmakuDisplay!.fontScale, 1.25);
    expect(store.lastWrite!.volume, isNull);
    expect(store.lastWrite!.diskCacheLimitMiB, isNull);
    expect(store.lastWrite!.danmakuServer, isNull);
    expect(store.lastWrite!.danmakuAppId, isNull);
    expect(store.lastWrite!.danmakuToken, isNull);

    final loaded = await tester.runAsync(() async {
      await fileStore.write(store.lastWrite!);
      return fileStore.read();
    });
    expect(loaded!.danmakuDisplay!.fontScale, 1.25);
    expect(loaded.volume, 42);
    expect(loaded.diskCacheLimitMiB, 4096);
    expect(loaded.danmakuServer, 'https://dan.example.com');
    expect(loaded.danmakuAppId, 'app-id');
    expect(loaded.danmakuToken, 'secret');
  }, tags: ['integration']);

  testWidgets('keyword chips persist, delete, and echo after rebuild', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    await pumpPage(tester, store: store);

    final field = find.byKey(DanmakuKeys.keywordInput);
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '剧透');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsOneWidget);
    expect((await store.read()).danmakuDisplay?.blockedKeywords, ['剧透']);

    tester
        .widget<InputChip>(find.byKey(DanmakuKeys.keywordChip('剧透')))
        .onDeleted!();
    await tester.pump();

    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsNothing);
    expect((await store.read()).danmakuDisplay?.blockedKeywords, isEmpty);

    await pumpPage(tester, store: store);
    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsNothing);
    expect((await store.read()).danmakuDisplay?.blockedKeywords, isEmpty);
  }, tags: ['integration']);

  testWidgets('danmaku display restore writes defaults', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        danmakuDisplay: DanmakuDisplaySettings(
          fontScale: 1.25,
          blockedKeywords: ['剧透'],
        ),
      ),
    );
    await pumpPage(tester, store: store);

    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsOneWidget);
    final restore = find.byKey(DanmakuKeys.restoreDefaults);
    expect(restore, findsOneWidget);
    await tester.ensureVisible(restore);
    await tester.pump();
    await tester.tap(restore);
    await tester.pump();
    await tester.pump();

    expect((await store.read()).danmakuDisplay, const DanmakuDisplaySettings());
    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsNothing);
  }, tags: ['integration']);
}
