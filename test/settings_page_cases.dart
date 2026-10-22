import 'helpers/cupertino_test_app.dart';
import 'helpers/widget_harness.dart';
import 'helpers/settle.dart';
import 'helpers/image_cache_fixture.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/webdav/webdav_backup.dart';
import 'package:rillight/webdav/webdav_client.dart';
import 'package:rillight/webdav/webdav_config.dart';

/// 记录 restore() 调用次数的控制器;其余行为与内存实现一致。
class _RestoreCountingAuth extends AuthController {
  _RestoreCountingAuth(CredentialStore credentials)
    : super(
        client: EmbyClient(
          device: const ClientDeviceInfo(
            clientName: 'Rillight',
            deviceName: 'test',
            deviceId: 'rillight-webdav-settings-test',
            version: '0.1.0',
          ),
        ),
        credentials: credentials,
        servers: MemoryServerListStore(),
      );

  int restoreCalls = 0;

  @override
  Future<void> restore({bool waitForNetwork = true}) async {
    restoreCalls++;
  }
}

/// 合成 WebDAV 客户端:按注入结果应答,记录上传字节,不起网络。
class _FakeWebDavClient extends WebDavClient {
  _FakeWebDavClient({this.connection, this.downloadResult})
    : super(address: 'http://192.0.2.1/dav', username: 'user', password: 'p');

  final WebDavConnectionResult? connection;
  final WebDavDownloadResult? downloadResult;
  Uint8List? uploadedBytes;

  @override
  Future<WebDavConnectionResult> testConnection() async =>
      connection ?? const WebDavConnectionSuccess();

  @override
  Future<WebDavUploadResult> upload(Uint8List bytes) async {
    uploadedBytes = bytes;
    return const WebDavUploadSuccess();
  }

  @override
  Future<WebDavDownloadResult> download() async =>
      downloadResult ?? WebDavDownloadSuccess(Uint8List(0));
}

/// 内存 WebDAV 配置存储:替代 webdav.json 的真实读写,
/// 使页面动作链全程无磁盘 IO、无真实事件循环依赖。
class _MemoryWebDavConfigStore extends WebDavConfigStore {
  _MemoryWebDavConfigStore([this._config = const WebDavConfig()])
    : super(File('memory-webdav.json'));

  WebDavConfig _config;

  @override
  Future<WebDavConfig> load() async => _config;

  @override
  Future<void> save(WebDavConfig config) async => _config = config;
}

void main() {
  setUp(isolateImageCache);

  Future<void> pumpPage(
    WidgetTester tester, {
    required PlayerSettingsStore store,
    TargetPlatform platform = TargetPlatform.windows,
    AuthController? auth,
    WebDavConfigStore? webdavStore,
    WebDavClient Function(WebDavConfig config)? webdavClientFactory,
    Future<Map<String, dynamic>> Function(
      Directory directory,
      CredentialStore credentials,
    )?
    webdavCollector,
    Future<WebDavApplyResult> Function(
      List<int> bytes,
      Directory directory,
      CredentialStore credentials,
    )?
    webdavApplier,
  }) async {
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget page = SettingsPage(
      settingsStore: store,
      platform: platform,
      // 注入内存 store 时目录只作占位:采集与应用由注入桩接管,不落盘。
      webdavDirectory: webdavStore == null ? null : Directory('webdav-memory'),
      webdavStore: webdavStore,
      webdavClientFactory: webdavClientFactory,
      webdavBundleCollector: webdavCollector,
      webdavBundleApplier: webdavApplier,
    );
    if (auth != null) {
      page = AuthScope(controller: auth, child: page);
    }
    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: CupertinoPageScaffold(child: page),
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
    // 外观预览缩略窗的 hero 色块是 accentContainer 实色,不再与 secondary 渐变。
    final heroes = find.byKey(const ValueKey('appearance-preview-hero'));
    expect(heroes, findsWidgets);
    for (final hero in tester.widgetList<Container>(heroes)) {
      final box = hero.decoration! as BoxDecoration;
      expect(box.gradient, isNull);
      expect(
        box.color,
        anyOf(
          AppUiTheme.lightTones.accentContainer,
          AppUiTheme.darkTones.accentContainer,
        ),
      );
    }

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

  const seededConfig = WebDavConfig(
    address: 'https://192.0.2.5:5006/dav',
    username: 'user',
    password: 'secret-pass',
    directory: 'rillight',
  );

  testWidgets('webdav section shows fields, masked password and actions', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    await pumpPage(
      tester,
      store: store,
      webdavStore: _MemoryWebDavConfigStore(seededConfig),
    );
    await expandSection(tester, '备份与同步');

    expect(find.byKey(SettingsPage.webDavAddressFieldKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavUsernameFieldKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavPasswordFieldKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavDirectoryFieldKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavTestConnectionKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavBackupKey), findsOneWidget);
    expect(find.byKey(SettingsPage.webDavRestoreKey), findsOneWidget);
    // 已存配置回显,密码输入保持遮蔽。
    expect(
      tester
          .widget<AppTextField>(find.byKey(SettingsPage.webDavAddressFieldKey))
          .controller!
          .text,
      seededConfig.address,
    );
    expect(
      tester
          .widget<CupertinoTextField>(
            find.descendant(
              of: find.byKey(SettingsPage.webDavPasswordFieldKey),
              matching: find.byType(CupertinoTextField),
            ),
          )
          .obscureText,
      isTrue,
    );
  }, tags: ['integration']);

  testWidgets('webdav configuration saves on commit and echoes after reload', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final webdavStore = _MemoryWebDavConfigStore();
    await pumpPage(tester, store: store, webdavStore: webdavStore);
    await expandSection(tester, '备份与同步');

    await tester.enterText(
      find.byKey(SettingsPage.webDavAddressFieldKey),
      'https://192.0.2.7/dav',
    );
    await tester.enterText(
      find.byKey(SettingsPage.webDavUsernameFieldKey),
      'media',
    );
    await tester.enterText(
      find.byKey(SettingsPage.webDavPasswordFieldKey),
      'pass-1234',
    );
    await tester.enterText(
      find.byKey(SettingsPage.webDavDirectoryFieldKey),
      'backup',
    );
    // 切到别的分类即离开输入框,与弹幕服务一致在失焦时提交;
    // 提交链全程内存 Future,settle 即确定性落库。
    final appearance = find.byKey(const ValueKey('settings-section-外观'));
    await tester.ensureVisible(appearance);
    await tester.tap(
      find.descendant(of: appearance, matching: find.text('外观')),
    );
    await settle(tester);

    final saved = await webdavStore.load();
    expect(saved.address, 'https://192.0.2.7/dav');
    expect(saved.username, 'media');
    expect(saved.password, 'pass-1234');
    expect(saved.directory, 'backup');

    // 重进设置页仍回显,密码继续脱敏。
    await pumpPage(tester, store: store, webdavStore: webdavStore);
    await expandSection(tester, '备份与同步');
    expect(
      tester
          .widget<AppTextField>(find.byKey(SettingsPage.webDavUsernameFieldKey))
          .controller!
          .text,
      'media',
    );
    expect(
      tester
          .widget<AppTextField>(find.byKey(SettingsPage.webDavPasswordFieldKey))
          .controller!
          .text,
      'pass-1234',
    );
    expect(
      tester
          .widget<CupertinoTextField>(
            find.descendant(
              of: find.byKey(SettingsPage.webDavPasswordFieldKey),
              matching: find.byType(CupertinoTextField),
            ),
          )
          .obscureText,
      isTrue,
    );
  }, tags: ['integration']);

  testWidgets('test connection maps each outcome to a distinct notice', (
    tester,
  ) async {
    final cases = <(WebDavConnectionResult, String)>[
      (const WebDavConnectionSuccess(), '连接成功'),
      (const WebDavConnectionCredentialError(401), '账号或密码错误'),
      (const WebDavConnectionDirectoryMissing(404), '备份目录不存在，请先创建或修改目录'),
      (const WebDavConnectionHttpError(500), '服务器返回错误（HTTP 500）'),
      (const WebDavConnectionUnreachable(null), '无法连接服务器，请检查地址与网络'),
    ];
    for (final (result, message) in cases) {
      final store = MemoryPlayerSettingsStore();
      final fake = _FakeWebDavClient(connection: result);
      await pumpPage(
        tester,
        store: store,
        webdavStore: _MemoryWebDavConfigStore(seededConfig),
        webdavClientFactory: (_) => fake,
      );
      await expandSection(tester, '备份与同步');
      await tester.tap(find.byKey(SettingsPage.webDavTestConnectionKey));
      await settle(tester);
      expect(find.text(message), findsOneWidget, reason: message);
    }
  }, tags: ['integration']);

  testWidgets('backup uploads a bundle and reports the timestamp', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final bundle = <String, dynamic>{
      'format': 'rillight-backup',
      'version': 1,
      'created_at': 1,
      'servers': {
        'servers': [
          {'id': 'source-a', 'name': 'Main'},
        ],
      },
      'credentials': {},
      'prefs': {},
    };
    final auth = _RestoreCountingAuth(MemoryCredentialStore());
    Directory? seenDirectory;
    CredentialStore? seenCredentials;
    final fake = _FakeWebDavClient();
    await pumpPage(
      tester,
      store: store,
      auth: auth,
      webdavStore: _MemoryWebDavConfigStore(seededConfig),
      webdavClientFactory: (_) => fake,
      webdavCollector: (directory, credentials) async {
        seenDirectory = directory;
        seenCredentials = credentials;
        return bundle;
      },
    );
    await expandSection(tester, '备份与同步');

    await tester.tap(find.byKey(SettingsPage.webDavBackupKey));
    await settle(tester);

    expect(
      find.textContaining(RegExp('备份完成 · \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}')),
      findsOneWidget,
    );
    // 注入采集器收到页面传入的凭据,上传字节即其返回的 bundle。
    expect(seenCredentials, same(auth.credentials));
    expect(seenDirectory, isNotNull);
    final uploaded = fake.uploadedBytes;
    expect(uploaded, isNotNull);
    final uploadedBundle = jsonDecode(utf8.decode(uploaded!));
    expect(uploadedBundle['format'], 'rillight-backup');
    expect((uploadedBundle['servers'] as Map)['servers'], hasLength(1));
    // 备份动作不改登录态。
    expect(auth.restoreCalls, 0);
  }, tags: ['integration']);

  testWidgets('backup reports local corruption instead of crashing', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final fake = _FakeWebDavClient();
    await pumpPage(
      tester,
      store: store,
      auth: _RestoreCountingAuth(MemoryCredentialStore()),
      webdavStore: _MemoryWebDavConfigStore(seededConfig),
      webdavClientFactory: (_) => fake,
      // 采集链抛 FormatException 走本地损坏分支,不再写坏 servers.json。
      webdavCollector: (directory, credentials) async =>
          throw const FormatException('Invalid local configuration'),
    );
    await expandSection(tester, '备份与同步');

    const corruptionNotice = '本地配置文件损坏，本次操作已取消';
    await tester.tap(find.byKey(SettingsPage.webDavBackupKey));
    await settle(tester);

    expect(find.text(corruptionNotice), findsOneWidget);
    expect(fake.uploadedBytes, isNull);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('restore applies the bundle, reloads auth and asks nothing', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final webdavStore = _MemoryWebDavConfigStore(seededConfig);
    final auth = _RestoreCountingAuth(MemoryCredentialStore());
    const restoredConfig = WebDavConfig(
      address: 'https://192.0.2.9/dav',
      username: 'next',
      password: 'next-pass',
      directory: 'sync',
    );
    final bundleBytes = Uint8List.fromList(utf8.encode('synthetic-bundle'));
    List<int>? appliedBytes;
    CredentialStore? appliedCredentials;
    final fake = _FakeWebDavClient(
      downloadResult: WebDavDownloadSuccess(bundleBytes),
    );
    await pumpPage(
      tester,
      store: store,
      auth: auth,
      webdavStore: webdavStore,
      webdavClientFactory: (_) => fake,
      webdavApplier: (bytes, directory, credentials) async {
        appliedBytes = bytes;
        appliedCredentials = credentials;
        // 模拟 bundle 覆盖 webdav.json,供原位重载回填表单。
        await webdavStore.save(restoredConfig);
        return const WebDavApplySuccess(needsReload: true);
      },
    );
    await expandSection(tester, '备份与同步');

    // 应用与重载链全程内存 Future,settle 即确定性完成。
    await tester.tap(find.byKey(SettingsPage.webDavRestoreKey));
    await settle(tester);

    expect(find.text('已恢复'), findsOneWidget);
    // 无二次确认弹窗,动作一次点击直接完成并触发了原位重载。
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(auth.restoreCalls, 1);
    // 应用器收到下载字节与页面凭据。
    expect(appliedBytes, bundleBytes);
    expect(appliedCredentials, same(auth.credentials));
    // bundle 里的 WebDAV 配置覆盖本地后,表单回填新值。
    expect(
      tester
          .widget<AppTextField>(find.byKey(SettingsPage.webDavAddressFieldKey))
          .controller!
          .text,
      'https://192.0.2.9/dav',
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('restore distinguishes no backup and rejected bundles', (
    tester,
  ) async {
    final noBackup = _FakeWebDavClient(
      downloadResult: const WebDavDownloadNoBackup(),
    );
    final rejectedBytes = Uint8List.fromList(utf8.encode('not a backup'));
    final rejected = _FakeWebDavClient(
      downloadResult: WebDavDownloadSuccess(rejectedBytes),
    );
    for (final (fake, message) in [
      (noBackup, '服务器上还没有备份文件'),
      (rejected, '备份文件校验未通过，本地数据未改动'),
    ]) {
      final store = MemoryPlayerSettingsStore();
      final webdavStore = _MemoryWebDavConfigStore(seededConfig);
      final auth = _RestoreCountingAuth(MemoryCredentialStore());
      var applierCalls = 0;
      await pumpPage(
        tester,
        store: store,
        auth: auth,
        webdavStore: webdavStore,
        webdavClientFactory: (_) => fake,
        // 校验拒绝的应用器:零写入,直接返回拒绝。
        webdavApplier: (bytes, directory, credentials) async {
          applierCalls++;
          return const WebDavApplyRejected(WebDavBackupError.malformed);
        },
      );
      await expandSection(tester, '备份与同步');
      await tester.tap(find.byKey(SettingsPage.webDavRestoreKey));
      await settle(tester);
      expect(find.text(message), findsOneWidget, reason: message);
      // 拒绝路径零写入:配置保持原样,不触发原位重载。
      final config = await webdavStore.load();
      expect(config.address, seededConfig.address);
      expect(auth.restoreCalls, 0);
      if (identical(fake, rejected)) {
        expect(applierCalls, 1);
      } else {
        expect(applierCalls, 0);
      }
    }
  }, tags: ['integration']);

  testWidgets(
    'webdav actions without an address point to configuration first',
    (tester) async {
      final store = MemoryPlayerSettingsStore();
      await pumpPage(
        tester,
        store: store,
        auth: _RestoreCountingAuth(MemoryCredentialStore()),
        webdavStore: _MemoryWebDavConfigStore(),
        webdavClientFactory: (_) => _FakeWebDavClient(),
      );
      await expandSection(tester, '备份与同步');

      const missingAddressNotice = '请先填写 WebDAV 服务器地址';
      await tester.tap(find.byKey(SettingsPage.webDavBackupKey));
      await settle(tester);
      expect(find.text(missingAddressNotice), findsOneWidget);

      await tester.tap(find.byKey(SettingsPage.webDavRestoreKey));
      await settle(tester);
      expect(find.text(missingAddressNotice), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
