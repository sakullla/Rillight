import 'helpers/cupertino_test_app.dart';
import 'helpers/widget_harness.dart';
import 'helpers/settle.dart';
import 'helpers/image_cache_fixture.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_setting_choices.dart';
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
      CupertinoTestApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: CupertinoPageScaffold(
          child: SettingsPage(settingsStore: store, platform: platform),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> expandSection(WidgetTester tester, String title) async {
    final section = find.byKey(ValueKey('settings-section-$title'));
    await tester.ensureVisible(section);
    await tester.tap(find.descendant(of: section, matching: find.text(title)));
    await settle(tester);
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

    // 读:选项格回显已存设置。
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-cache-4096')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-decoding-off')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-backend-auto')),
          )
          .selected,
      isTrue,
    );

    // 写:点选磁盘缓冲上限并落盘回显。
    await tester.tap(find.byKey(const ValueKey('settings-cache-1024')));
    await settle(tester);

    final settings = await store.read();
    expect(settings.diskCacheLimitMiB, 1024);
    // 其他已存字段不被清掉。
    expect(settings.hardwareDecoding, HardwareDecodingMode.off);
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-cache-1024')),
          )
          .selected,
      isTrue,
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
    await settle(tester);

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
      expect(find.byKey(const Key('phone-subtitle-reset')), findsNothing);
      await tester.tap(find.byKey(const Key('phone-subtitle-extraLarge')));
      await settle(tester);
      expect(
        (await store.read()).effectivePhoneSubtitles.size,
        PhoneSubtitleSize.extraLarge,
      );
      await tester.tap(find.byKey(const Key('phone-subtitle-original')));
      await settle(tester);
      expect((await store.read()).effectivePhoneSubtitles.originalAss, isTrue);
      await tester.tap(find.byKey(const Key('phone-subtitle-reset')));
      await settle(tester);
      expect(
        (await store.read()).effectivePhoneSubtitles.size,
        PhoneSubtitleSize.standard,
      );
      expect((await store.read()).volume, 54);
      expect((await store.read()).playbackRate, 1.5);
    },
    tags: ['integration'],
  );

  testWidgets('wide window shows category navigation and one open pane', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 40));
    await pumpPage(tester, store: store);
    expect(find.byKey(SettingsPage.navKey), findsOneWidget);
    // 默认打开外观;关于排在分类最后。
    expect(find.byKey(SettingsPage.appearanceKey), findsOneWidget);
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    final about = tester.getTopLeft(
      find.byKey(const ValueKey('settings-section-关于')),
    );
    final danmaku = tester.getTopLeft(
      find.byKey(const ValueKey('settings-section-弹幕配置')),
    );
    expect(about.dy, greaterThan(danmaku.dy));

    await expandSection(tester, '播放');
    expect(find.byKey(SettingsPage.appearanceKey), findsNothing);
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsOneWidget);
    final switches = find.descendant(
      of: find.byKey(const ValueKey('settings-section-body-播放')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is AppSwitchTile && w.key != const Key('phone-subtitle-original'),
      ),
    );
    expect(switches, findsNWidgets(2));
    await tester.tap(switches.first);
    await settle(tester);
    expect((await store.read()).isSkipIntroEnabled, isFalse);

    // 换到别的分类再回来,已存的值仍然回显。
    await expandSection(tester, '外观');
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    await expandSection(tester, '播放');
    expect(tester.widget<AppSwitchTile>(switches.first).value, isFalse);
    expect((await store.read()).volume, 40);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('sections collapse and skip switches persist independently', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 40));
    await pumpPage(tester, store: store);
    // 窄窗口仍是可折叠分组卡。
    tester.view.physicalSize = const Size(600, 2200);
    await settle(tester);
    expect(find.byKey(SettingsPage.navKey), findsNothing);
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    await expandSection(tester, '播放');
    final switches = find.descendant(
      of: find.byKey(const ValueKey('settings-section-播放')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is AppSwitchTile && w.key != const Key('phone-subtitle-original'),
      ),
    );
    expect(switches, findsNWidgets(2));
    await tester.tap(switches.first);
    await settle(tester);
    expect((await store.read()).isSkipIntroEnabled, isFalse);
    expect((await store.read()).isSkipOutroEnabled, isTrue);
    await tester.tap(switches.last);
    await settle(tester);
    expect((await store.read()).isSkipOutroEnabled, isFalse);
    expect((await store.read()).volume, 40);
    await expandSection(tester, '播放');
    expect(find.byKey(SettingsPage.diskCacheLimitKey), findsNothing);
    await expandSection(tester, '播放');
    expect(tester.widget<AppSwitchTile>(switches.first).value, isFalse);
    expect(tester.widget<AppSwitchTile>(switches.last).value, isFalse);
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
                w is AppSwitchTile &&
                w.key != const Key('phone-subtitle-original'),
          )
          .first,
    );
    await settle(tester);
    expect((await store.read()).volume, 75);
    expect((await store.read()).isSkipIntroEnabled, isFalse);
  }, tags: ['integration']);

  testWidgets(
    'danmaku shows preview and folds advanced options on narrow page',
    (tester) async {
      final store = MemoryPlayerSettingsStore();
      await pumpPage(tester, store: store);
      tester.view.physicalSize = const Size(360, 1600);
      await settle(tester);
      await expandSection(tester, '弹幕配置');
      expect(find.text('样式预览'), findsOneWidget);
      expect(find.text('一起看剧，弹幕也清晰舒适'), findsOneWidget);
      expect(find.byType(AppChoiceChip), findsNothing);
      final scroll = find.byKey(DanmakuKeys.typeScroll);
      await tester.ensureVisible(scroll);
      await tester.tap(scroll);
      await settle(tester);
      expect((await store.read()).danmakuDisplay?.showScroll, isFalse);
      final advanced = find.byKey(const ValueKey('danmaku-advanced-settings'));
      await tester.ensureVisible(advanced);
      await tester.tap(
        find.descendant(of: advanced, matching: find.byType(AppListTile)),
      );
      await settle(tester);
      expect(find.byType(AppSwitchTile), findsWidgets);
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
      // 两栏布局里切到别的分类即离开输入框,与折叠一样提交。
      await expandSection(tester, '外观');
      expect(find.byKey(SettingsPage.danmakuServerFieldKey), findsNothing);
      expect(
        (await store.read()).danmakuServer,
        'https://danmaku.example.test',
      );
      expect((await store.read()).volume, 40);
      await expandSection(tester, '弹幕配置');
      expect(
        tester.widget<AppTextField>(field).controller!.text,
        'https://danmaku.example.test',
      );
    },
    tags: ['integration'],
  );

  testWidgets(
    'output settings retain status without retired enhancement controls',
    (tester) async {
      final store = MemoryPlayerSettingsStore(
        PlayerSettings.fromJson({
          'frameInterpolation': 'double',
          'anime4k': 'strong',
          'superResolution': 'x2',
          'denoise': 100,
          'sharpen': 100,
        }),
      );
      await pumpPage(tester, store: store);
      await expandSection(tester, '实际输出');
      expect(find.byKey(const Key('playback-output-video')), findsOneWidget);
      expect(find.byKey(const Key('playback-output-audio')), findsOneWidget);
      expect(find.byKey(const Key('playback-enhance-choices')), findsNothing);
      for (final text in ['Anime4K', '通用超分', '降噪', '锐化', '补帧']) {
        expect(find.text(text), findsNothing);
      }
    },
    tags: ['integration'],
  );

  testWidgets('decoder backend is hidden when the platform has one choice', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    await pumpPage(tester, store: store, platform: TargetPlatform.android);
    await expandSection(tester, '播放');
    expect(find.byKey(SettingsPage.decoderBackendKey), findsNothing);
    expect(find.text('解码后端'), findsNothing);
    expect(find.byKey(SettingsPage.hardwareDecodingKey), findsOneWidget);
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-decoding-auto')),
          )
          .selected,
      isTrue,
    );
  }, tags: ['integration']);
}
