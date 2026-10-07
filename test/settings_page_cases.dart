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

  Future<void> expandSection(WidgetTester tester, String title) async {
    final section = find.byKey(ValueKey('settings-section-$title'));
    await tester.ensureVisible(section);
    await tester.tap(find.descendant(of: section, matching: find.text(title)));
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

    await expandSection(tester, '播放');

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

    await expandSection(tester, '播放');

    await tester.tap(find.byKey(SettingsPage.restoreDefaultsKey));
    await tester.pumpAndSettle();

    final settings = await store.read();
    expect(settings.diskCacheLimitMiB, PlayerRuntimeDefaults.diskCacheLimitMiB);
    expect(settings.hardwareDecoding, HardwareDecodingMode.auto);
    expect(settings.hardwareDecoder, HardwareDecoderBackend.auto);
    // 音量不属于本页管理,恢复默认不覆盖已存音量。
    expect(settings.volume, 40);
  }, tags: ['integration']);

  testWidgets(
    'phone subtitle preference saves independently and resets through shared editor',
    (tester) async {
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(volume: 54, playbackRate: 1.5),
      );
      await pumpPage(tester, store: store);
      await expandSection(tester, '播放');
      await tester.tap(find.byKey(const Key('phone-subtitle-extraLarge')));
      await tester.pumpAndSettle();
      expect(
        (await store.read()).effectivePhoneSubtitles.size,
        PhoneSubtitleSize.extraLarge,
      );
      await tester.tap(find.byKey(const Key('phone-subtitle-original')));
      await tester.pumpAndSettle();
      expect((await store.read()).effectivePhoneSubtitles.originalAss, isTrue);
      await tester.tap(find.byKey(const Key('phone-subtitle-reset')));
      await tester.pumpAndSettle();
      expect(
        (await store.read()).effectivePhoneSubtitles.size,
        PhoneSubtitleSize.standard,
      );
      expect((await store.read()).volume, 54);
      expect((await store.read()).playbackRate, 1.5);
    },
    tags: ['integration'],
  );

  testWidgets('sections collapse and skip switches persist independently', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 40));
    await pumpPage(tester, store: store);
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    await expandSection(tester, '播放');
    final switches = find.descendant(
      of: find.byKey(const ValueKey('settings-section-播放')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is SwitchListTile &&
            w.key != const Key('phone-subtitle-original'),
      ),
    );
    expect(switches, findsNWidgets(2));
    await tester.tap(switches.first);
    await tester.pumpAndSettle();
    expect((await store.read()).isSkipIntroEnabled, isFalse);
    expect((await store.read()).isSkipOutroEnabled, isTrue);
    await tester.tap(switches.last);
    await tester.pumpAndSettle();
    expect((await store.read()).isSkipOutroEnabled, isFalse);
    expect((await store.read()).volume, 40);
    await expandSection(tester, '播放');
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    await expandSection(tester, '播放');
    expect(tester.widget<SwitchListTile>(switches.first).value, isFalse);
    expect(tester.widget<SwitchListTile>(switches.last).value, isFalse);
  }, tags: ['integration']);

  testWidgets('settings changes preserve volume updated by the player', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 40));
    await pumpPage(tester, store: store);
    await store.write(const PlayerSettings(volume: 75));
    await expandSection(tester, '播放');
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w is SwitchListTile &&
                w.key != const Key('phone-subtitle-original'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect((await store.read()).volume, 75);
    expect((await store.read()).isSkipIntroEnabled, isFalse);
  }, tags: ['integration']);

  testWidgets(
    'danmaku shows preview and folds advanced options on narrow page',
    (tester) async {
      await pumpPage(tester, store: MemoryPlayerSettingsStore());
      tester.view.physicalSize = const Size(360, 1600);
      await tester.pumpAndSettle();
      await expandSection(tester, '弹幕配置');
      expect(find.text('样式预览'), findsOneWidget);
      expect(find.text('一起看剧，弹幕也清晰舒适'), findsOneWidget);
      final advanced = find.byKey(const ValueKey('danmaku-advanced-settings'));
      await tester.ensureVisible(advanced);
      await tester.tap(
        find.descendant(of: advanced, matching: find.byType(ListTile)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'danmaku configuration combines display and service and saves input on collapse',
    (tester) async {
      final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 40));
      await pumpPage(tester, store: store);
      expect(find.text('弹幕配置'), findsOneWidget);
      expect(find.text('弹幕服务'), findsNothing);
      await expandSection(tester, '弹幕配置');
      expect(find.text('样式预览'), findsOneWidget);
      expect(find.text('弹幕服务'), findsOneWidget);
      final field = find.byKey(SettingsPage.danmakuServerFieldKey);
      await tester.ensureVisible(field);
      await tester.enterText(field, 'https://danmaku.example.test');
      await expandSection(tester, '弹幕配置');
      expect(find.byKey(SettingsPage.danmakuServerFieldKey), findsNothing);
      expect(
        (await store.read()).danmakuServer,
        'https://danmaku.example.test',
      );
      expect((await store.read()).volume, 40);
      await expandSection(tester, '弹幕配置');
      expect(
        tester.widget<TextField>(field).controller!.text,
        'https://danmaku.example.test',
      );
    },
    tags: ['integration'],
  );

  testWidgets(
    'output section shows unknown actuals and saved enhancement requests',
    (tester) async {
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          volume: 40,
          frameInterpolation: FrameInterpolation.doubleRate,
          anime4k: Anime4kLevel.strong,
          denoise: 40,
          acceptLeaveNativeDolby: true,
        ),
      );
      await pumpPage(tester, store: store);
      await expandSection(tester, '实际输出');
      final picture = tester
          .widget<Text>(find.byKey(const Key('playback-output-video')))
          .data!;
      final audio = tester
          .widget<Text>(find.byKey(const Key('playback-output-audio')))
          .data!;
      expect(picture, contains('未知'));
      expect(picture, isNot(contains('杜比')));
      expect(audio, contains('未知'));
      expect(audio, isNot(contains('Atmos')));
      expect(find.textContaining('未在播放，实际输出未知'), findsWidgets);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('请求 双倍'),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('生效 未知'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-enhance-denoise')))
            .data,
        contains('请求 40'),
      );

      await tester.tap(find.byKey(const Key('playback-output-keep')));
      await tester.pumpAndSettle();
      expect((await store.read()).acceptLeaveNativeDolby, isFalse);
      expect(
        (await store.read()).frameInterpolation,
        FrameInterpolation.doubleRate,
      );
      expect((await store.read()).volume, 40);

      await tester.tap(find.byKey(const Key('playback-output-disable')));
      await tester.pumpAndSettle();
      final saved = await store.read();
      expect(saved.frameInterpolation, FrameInterpolation.off);
      expect(saved.anime4k, Anime4kLevel.off);
      expect(saved.denoise, 0);
      expect(saved.volume, 40);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('请求 关闭'),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('生效 未知'),
      );
    },
    tags: ['integration'],
  );

  testWidgets('settings output choices save enhancement and cancel leaves it', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        superResolution: SuperResolution.x2,
        denoise: 5,
      ),
    );
    await pumpPage(tester, store: store);
    await expandSection(tester, '实际输出');
    expect(find.byKey(const Key('playback-enhance-choices')), findsOneWidget);
    expect(find.byKey(const Key('playback-output-frame-rate')), findsNothing);

    final anime = find.byKey(const Key('playback-select-anime4k-strong'));
    await tester.ensureVisible(anime);
    await tester.tap(anime);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('playback-confirm-exclusive')), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('playback-confirm-exclusive-cancel')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect((await store.read()).superResolution, SuperResolution.x2);
    expect((await store.read()).anime4k, isNull);
    expect((await store.read()).volume, 40);

    await tester.ensureVisible(anime);
    await tester.tap(anime);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const Key('playback-confirm-exclusive-accept')),
    );
    await tester.pumpAndSettle();
    final saved = await store.read();
    expect(saved.anime4k, Anime4kLevel.strong);
    expect(saved.superResolution, SuperResolution.off);
    expect(saved.denoise, 5);
    expect(saved.volume, 40);
    expect(find.byKey(const Key('playback-confirm-leave-dolby')), findsNothing);

    final denoise = tester.widget<Slider>(
      find.byKey(const Key('playback-select-denoise')),
    );
    denoise.onChangeEnd!(25);
    await tester.pumpAndSettle();
    expect((await store.read()).denoise, 25);
    expect((await store.read()).sharpen, 0);
    final sharpen = tester.widget<Slider>(
      find.byKey(const Key('playback-select-sharpen')),
    );
    sharpen.onChangeEnd!(15);
    await tester.pumpAndSettle();
    expect((await store.read()).denoise, 25);
    expect((await store.read()).sharpen, 15);
    expect((await store.read()).anime4k, Anime4kLevel.strong);
    final doubled = find.byKey(
      const Key('playback-select-interpolation-double'),
    );
    await tester.ensureVisible(doubled);
    await tester.tap(doubled);
    await tester.pumpAndSettle();
    expect(
      (await store.read()).frameInterpolation,
      FrameInterpolation.doubleRate,
    );
    expect((await store.read()).acceptLeaveNativeDolby, isNot(isTrue));
  }, tags: ['integration']);
}
