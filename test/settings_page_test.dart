import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required PlayerSettingsStore store,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
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
  });

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
  });

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
  });

  testWidgets('lists nvdec on windows but not on macOS', (tester) async {
    final store = MemoryPlayerSettingsStore();
    await pumpPage(tester, store: store, platform: TargetPlatform.windows);
    await tester.tap(find.byKey(SettingsPage.decoderBackendKey));
    await tester.pumpAndSettle();
    expect(find.text('NVDEC'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await pumpPage(tester, store: store, platform: TargetPlatform.macOS);
    await tester.tap(find.byKey(SettingsPage.decoderBackendKey));
    await tester.pumpAndSettle();
    expect(find.text('NVDEC'), findsNothing);
    expect(find.text('VideoToolbox'), findsOneWidget);
  });

  testWidgets('shows the stored danmaku service values', (tester) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        danmakuServer: 'https://dan.example.com/ddplay',
        danmakuToken: 'secret',
      ),
    );
    await pumpPage(tester, store: store);

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuServerFieldKey))
          .controller!
          .text,
      'https://dan.example.com/ddplay',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuTokenFieldKey))
          .controller!
          .text,
      'secret',
    );
  });

  testWidgets(
    'saving the danmaku service persists without clearing other fields',
    (tester) async {
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          volume: 42,
          hardwareDecoding: HardwareDecodingMode.off,
        ),
      );
      await pumpPage(tester, store: store);

      await tester.enterText(
        find.byKey(SettingsPage.danmakuServerFieldKey),
        'https://dan.example.com/ddplay',
      );
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      await tester.enterText(
        find.byKey(SettingsPage.danmakuTokenFieldKey),
        'secret',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final settings = await store.read();
      expect(settings.danmakuServer, 'https://dan.example.com/ddplay');
      expect(settings.danmakuToken, 'secret');
      // 弹幕服务保存不清掉音量/解码等既有字段。
      expect(settings.volume, 42);
      expect(settings.hardwareDecoding, HardwareDecodingMode.off);
    },
  );

  testWidgets('clearing the server input falls back to the official source', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 42,
        danmakuServer: 'https://dan.example.com/ddplay',
        danmakuToken: 'secret',
      ),
    );
    await pumpPage(tester, store: store);

    await tester.enterText(find.byKey(SettingsPage.danmakuServerFieldKey), '');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    final settings = await store.read();
    // 空串覆盖旧值;弹幕控制器读取时按未配置(官方源)解析。
    expect(settings.danmakuServer, '');
    // 未编辑的令牌字段保持原值。
    expect(settings.danmakuToken, 'secret');
    expect(settings.volume, 42);
  });

  testWidgets('restore defaults clears the custom danmaku service', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        danmakuServer: 'https://dan.example.com/ddplay',
        danmakuToken: 'secret',
      ),
    );
    await pumpPage(tester, store: store);

    await tester.tap(find.byKey(SettingsPage.restoreDefaultsKey));
    await tester.pumpAndSettle();

    final settings = await store.read();
    // 空串/未配置都按官方源解析。
    expect((settings.danmakuServer ?? '').isEmpty, isTrue);
    expect((settings.danmakuToken ?? '').isEmpty, isTrue);
    // 音量不属于本页管理,恢复默认不覆盖已存音量。
    expect(settings.volume, 40);
    // 输入框同步清空。
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuServerFieldKey))
          .controller!
          .text,
      '',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsPage.danmakuTokenFieldKey))
          .controller!
          .text,
      '',
    );
  });
}
