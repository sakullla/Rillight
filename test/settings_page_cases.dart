import 'helpers/image_cache_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
  setUp(isolateImageCache);

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

  testWidgets('shows the stored settings and changing the disk cache limit '
      'persists and echoes', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        diskCacheLimitMiB: 4096,
        hardwareDecoding: HardwareDecodingMode.off,
      ),
    );
    await pumpPage(tester, store: store);

    // 读:控件回显已存设置。
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

    // 写:切换磁盘缓冲上限并落盘回显。
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
}
