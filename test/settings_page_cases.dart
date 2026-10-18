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
  Future<void> restore() async {
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

void main() {
  setUp(isolateImageCache);

  /// 页面动作链里的真实文件 IO 必须在真实事件循环里发起并完成;
  /// 与 update_verification_ui 相同的 runAsync 窗口模式。
  Future<void> runInRealLoop(
    WidgetTester tester,
    Future<void> Function() action, {
    bool Function()? done,
    Duration budget = const Duration(seconds: 5),
  }) async {
    await tester.runAsync<void>(() async {
      await action();
      final end = DateTime.now().add(budget);
      while (DateTime.now().isBefore(end)) {
        if (done != null && done()) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await settle(tester);
  }

  /// 先让 initState 里的 webdav.json 加载完成,再断言回显。逐轮开窗,
  /// 让 fake zone 里挂起的读链在窗口边界推进。
  Future<void> flushWebDavLoad(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync<void>(() => Future<void>.delayed(Duration.zero));
    }
    await settle(tester);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required PlayerSettingsStore store,
    TargetPlatform platform = TargetPlatform.windows,
    AuthController? auth,
    Directory? webdavDirectory,
    WebDavClient Function(WebDavConfig config)? webdavClientFactory,
  }) async {
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget page = SettingsPage(
      settingsStore: store,
      platform: platform,
      webdavDirectory: webdavDirectory,
      webdavClientFactory: webdavClientFactory,
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
    if (webdavDirectory != null) {
      await flushWebDavLoad(tester);
    }
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

  Directory webDavTempDir() {
    final dir = Directory.systemTemp.createTempSync('rillight-webdav-ui');
    addTearDown(() {
      // 页面可能仍持有未决 IO 句柄;清理尽力而为,失败留给系统临时目录。
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on Object {
        // ignore: avoid_catches_without_on_clauses
      }
    });
    return dir;
  }

  void seedConfig(Directory dir, WebDavConfig config) {
    File('${dir.path}/webdav.json')
        .writeAsStringSync(jsonEncode(config.toJson()));
  }

  WebDavConfig readStoredConfig(Directory dir) => WebDavConfig.fromJson(
    Map<String, dynamic>.from(
      jsonDecode(File('${dir.path}/webdav.json').readAsStringSync()) as Map,
    ),
  );

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
    final dir = webDavTempDir();
    seedConfig(dir, seededConfig);
    await pumpPage(tester, store: store, webdavDirectory: dir);
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
    final dir = webDavTempDir();
    await pumpPage(tester, store: store, webdavDirectory: dir);
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
    // 保存是真实文件写入,在真实事件循环窗口内等待落盘。
    final stored = File('${dir.path}/webdav.json');
    final appearance = find.byKey(const ValueKey('settings-section-外观'));
    await tester.ensureVisible(appearance);
    await runInRealLoop(
      tester,
      () => tester.tap(
        find.descendant(of: appearance, matching: find.text('外观')),
      ),
      done: () =>
          stored.existsSync() &&
          stored.readAsStringSync().contains('https://192.0.2.7/dav'),
    );

    final saved = readStoredConfig(dir);
    expect(saved.address, 'https://192.0.2.7/dav');
    expect(saved.username, 'media');
    expect(saved.password, 'pass-1234');
    expect(saved.directory, 'backup');

    // 重进设置页仍回显,密码继续脱敏。
    await pumpPage(tester, store: store, webdavDirectory: dir);
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
      final dir = webDavTempDir();
      seedConfig(dir, seededConfig);
      final fake = _FakeWebDavClient(connection: result);
      await pumpPage(
        tester,
        store: store,
        webdavDirectory: dir,
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
    final dir = webDavTempDir();
    seedConfig(dir, seededConfig);
    File('${dir.path}/servers.json').writeAsStringSync(
      jsonEncode({
        'servers': [
          {'id': 'source-a', 'name': 'Main'},
        ],
      }),
    );
    final auth = _RestoreCountingAuth(MemoryCredentialStore());
    final fake = _FakeWebDavClient();
    await pumpPage(
      tester,
      store: store,
      auth: auth,
      webdavDirectory: dir,
      webdavClientFactory: (_) => fake,
    );
    await expandSection(tester, '备份与同步');

    await runInRealLoop(
      tester,
      () => tester.tap(find.byKey(SettingsPage.webDavBackupKey)),
      done: () => fake.uploadedBytes != null,
    );

    expect(
      find.textContaining(RegExp('备份完成 · \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}')),
      findsOneWidget,
    );
    final uploaded = fake.uploadedBytes;
    expect(uploaded, isNotNull);
    final bundle = jsonDecode(utf8.decode(uploaded!));
    expect(bundle['format'], 'rillight-backup');
    expect((bundle['servers'] as Map)['servers'], hasLength(1));
    // 备份动作不改登录态。
    expect(auth.restoreCalls, 0);
  }, tags: ['integration']);

  testWidgets('backup reports local corruption instead of crashing', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final dir = webDavTempDir();
    seedConfig(dir, seededConfig);
    File('${dir.path}/servers.json').writeAsStringSync('{ not json');
    final fake = _FakeWebDavClient();
    await pumpPage(
      tester,
      store: store,
      auth: _RestoreCountingAuth(MemoryCredentialStore()),
      webdavDirectory: dir,
      webdavClientFactory: (_) => fake,
    );
    await expandSection(tester, '备份与同步');

    // 采集链在真实事件循环里跑到本地损坏分支。
    await tester.runAsync<void>(
      () => tester.tap(find.byKey(SettingsPage.webDavBackupKey)),
    );
    // 不能用固定预算等待:CI 慢机上真实文件 IO 后的反馈渲染晚于预算耗尽,
    // 需逐轮"真实 IO 窗口 + 帧推进"直到文案出现。
    const corruptionNotice = '本地配置文件损坏，本次操作已取消';
    for (var i = 0; i < 100; i++) {
      await tester.runAsync<void>(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await settle(tester);
      if (find.text(corruptionNotice).evaluate().isNotEmpty) break;
    }

    expect(find.text(corruptionNotice), findsOneWidget);
    expect(fake.uploadedBytes, isNull);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('restore applies the bundle, reloads auth and asks nothing', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final dir = webDavTempDir();
    seedConfig(dir, seededConfig);
    final auth = _RestoreCountingAuth(MemoryCredentialStore());
    final bundleBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'rillight-backup',
          'version': 1,
          'created_at': 1,
          'servers': {
            'servers': [
              {'id': 'source-restored', 'name': 'Restored'},
            ],
          },
          'credentials': {},
          'prefs': {},
          'webdav': {
            'address': 'https://192.0.2.9/dav',
            'username': 'next',
            'password': 'next-pass',
            'directory': 'sync',
          },
        }),
      ),
    );
    final fake = _FakeWebDavClient(
      downloadResult: WebDavDownloadSuccess(bundleBytes),
    );
    await pumpPage(
      tester,
      store: store,
      auth: auth,
      webdavDirectory: dir,
      webdavClientFactory: (_) => fake,
    );
    await expandSection(tester, '备份与同步');

    // 应用与重载链都是真实文件 IO,在窗口内等到原位重载完成。
    await runInRealLoop(
      tester,
      () => tester.tap(find.byKey(SettingsPage.webDavRestoreKey)),
      done: () => auth.restoreCalls == 1,
    );

    expect(find.text('已恢复'), findsOneWidget);
    // 无二次确认弹窗,动作一次点击直接完成并触发了原位重载。
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(auth.restoreCalls, 1);
    // bundle 里的 WebDAV 配置覆盖本地后,表单回填新值。
    expect(
      tester
          .widget<AppTextField>(find.byKey(SettingsPage.webDavAddressFieldKey))
          .controller!
          .text,
      'https://192.0.2.9/dav',
    );
    final servers =
        jsonDecode(File('${dir.path}/servers.json').readAsStringSync()) as Map;
    expect((servers['servers'] as List), hasLength(1));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('restore distinguishes no backup and rejected bundles', (
    tester,
  ) async {
    final noBackup = _FakeWebDavClient(
      downloadResult: const WebDavDownloadNoBackup(),
    );
    final rejected = _FakeWebDavClient(
      downloadResult: WebDavDownloadSuccess(
        Uint8List.fromList(utf8.encode('not a backup')),
      ),
    );
    for (final (fake, message) in [
      (noBackup, '服务器上还没有备份文件'),
      (rejected, '备份文件校验未通过，本地数据未改动'),
    ]) {
      final store = MemoryPlayerSettingsStore();
      final dir = webDavTempDir();
      seedConfig(dir, seededConfig);
      File('${dir.path}/servers.json')
          .writeAsStringSync(jsonEncode({'servers': []}));
      await pumpPage(
        tester,
        store: store,
        auth: _RestoreCountingAuth(MemoryCredentialStore()),
        webdavDirectory: dir,
        webdavClientFactory: (_) => fake,
      );
      await expandSection(tester, '备份与同步');
      await tester.tap(find.byKey(SettingsPage.webDavRestoreKey));
      await settle(tester);
      expect(find.text(message), findsOneWidget, reason: message);
      // 拒绝路径零写入,servers.json 保持原样。
      final servers = jsonDecode(
        File('${dir.path}/servers.json').readAsStringSync(),
      ) as Map;
      expect(servers['servers'], isEmpty);
    }
  }, tags: ['integration']);

  testWidgets(
    'webdav actions without an address point to configuration first',
    (tester) async {
      final store = MemoryPlayerSettingsStore();
      final dir = webDavTempDir();
      await pumpPage(
        tester,
        store: store,
        auth: _RestoreCountingAuth(MemoryCredentialStore()),
        webdavDirectory: dir,
        webdavClientFactory: (_) => _FakeWebDavClient(),
      );
      await expandSection(tester, '备份与同步');

      await tester.tap(find.byKey(SettingsPage.webDavBackupKey));
      await settle(tester);
      expect(find.text('请先填写 WebDAV 服务器地址'), findsOneWidget);

      await tester.tap(find.byKey(SettingsPage.webDavRestoreKey));
      await settle(tester);
      expect(find.text('请先填写 WebDAV 服务器地址'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
