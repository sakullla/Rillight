import '../updates/update_check.dart';
import '../product.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/webdav/webdav_backup.dart';
import 'package:rillight/webdav/webdav_client.dart';
import 'package:rillight/webdav/webdav_config.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/player/danmaku/danmaku_display_form.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/playback_output_panel.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/phone_subtitle_settings.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 设置页:展开/收起外观、播放与弹幕配置,按需调整二级选项。
///
/// 读写统一走 [PlayerSettingsStore];更改即时持久化,对新起播生效。
/// 音量不入本页,由播放器控制层维护。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.settingsStore,
    this.platform,
    this.appearance,
    this.showTitle = true,
    this.auth,
    this.webdavStore,
    this.webdavDirectory,
    this.webdavClientFactory,
    this.webdavBundleCollector,
    this.webdavBundleApplier,
  });

  /// 测试注入;运行时留空用当前平台。
  final bool showTitle;
  final PlayerSettingsStore? settingsStore;
  final TargetPlatform? platform;

  /// 测试注入的外观控制器;运行时留空走 [AppearanceScope]。
  final AppearanceController? appearance;

  /// 测试注入的鉴权控制器;运行时留空走 [AuthScope]。
  /// WebDAV 恢复后经它触发凭据与服务器列表的原位重载。
  final AuthController? auth;

  /// 测试注入的 WebDAV 配置存储;运行时按应用支持目录落 webdav.json。
  final WebDavConfigStore? webdavStore;

  /// 测试注入的备份根目录;采集与应用 bundle 都在这里。
  final Directory? webdavDirectory;

  /// 测试注入的客户端工厂;运行时直接按配置构造真实客户端。
  final WebDavClient Function(WebDavConfig config)? webdavClientFactory;

  /// 测试注入的 bundle 采集器;运行时直接采集本地文件。
  final Future<Map<String, dynamic>> Function(
    Directory directory,
    CredentialStore credentials,
  )?
  webdavBundleCollector;

  /// 测试注入的 bundle 应用器;运行时直接应用下载字节。
  final Future<WebDavApplyResult> Function(
    List<int> bytes,
    Directory directory,
    CredentialStore credentials,
  )?
  webdavBundleApplier;

  static const diskCacheLimitKey = Key('settings-disk-cache-limit');
  static const hardwareDecodingKey = Key('settings-hardware-decoding');
  static const decoderBackendKey = Key('settings-decoder-backend');
  static const appearanceKey = Key('settings-appearance');
  static const danmakuServerFieldKey = Key('settings-danmaku-server');
  static const danmakuAppIdFieldKey = Key('settings-danmaku-app-id');
  static const danmakuTokenFieldKey = Key('settings-danmaku-token');
  static const restoreDefaultsKey = Key('settings-restore-defaults');
  static const tokenVisibilityKey = Key('settings-token-visibility');
  static const webDavAddressFieldKey = Key('settings-webdav-address');
  static const webDavUsernameFieldKey = Key('settings-webdav-username');
  static const webDavPasswordFieldKey = Key('settings-webdav-password');
  static const webDavDirectoryFieldKey = Key('settings-webdav-directory');
  static const webDavPasswordVisibilityKey = Key(
    'settings-webdav-password-visibility',
  );
  static const webDavTestConnectionKey = Key('settings-webdav-test-connection');
  static const webDavBackupKey = Key('settings-webdav-backup');
  static const webDavRestoreKey = Key('settings-webdav-restore');
  static const columnKey = Key('settings-column');
  static const navKey = Key('settings-nav');

  /// 窗口不窄于此宽度时改为左侧分类、右侧内容的两栏布局。
  static const double twoPaneMinWidth = 840;
  static const double twoPaneMaxWidth = 1120;
  static const double navWidth = 280;

  /// 设置正文限宽,避免标签贴左、控件贴窗沿。
  static const double columnMaxWidth = 800;

  /// 可选的磁盘缓冲上限档位(MiB)。
  static const diskCacheLimitChoices = <int>[512, 1024, 2048, 4096, 8192];

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _danmakuServerController = TextEditingController();
  final _danmakuAppIdController = TextEditingController();
  final _danmakuTokenController = TextEditingController();
  final _danmakuServerFocus = FocusNode();
  final _danmakuAppIdFocus = FocusNode();
  final _danmakuTokenFocus = FocusNode();
  final _webdavAddressController = TextEditingController();
  final _webdavUsernameController = TextEditingController();
  final _webdavPasswordController = TextEditingController();
  final _webdavDirectoryController = TextEditingController();
  final _webdavAddressFocus = FocusNode();
  final _webdavUsernameFocus = FocusNode();
  final _webdavPasswordFocus = FocusNode();
  final _webdavDirectoryFocus = FocusNode();

  PlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  var _loaded = false;
  var _tokenVisible = false;

  WebDavConfigStore? _webdavStore;
  Directory? _webdavDirectory;
  WebDavConfig _webdavConfig = const WebDavConfig();
  var _webdavLoaded = false;
  var _webdavPasswordVisible = false;
  _WebDavAction? _webdavAction;

  /// 宽窗口两栏布局里当前打开的分类标题;null 表示默认分类。
  String? _selectedSection;
  var _saveRevision = 0;
  Future<void> _pendingWrites = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _danmakuServerFocus.addListener(_handleDanmakuServerFocusChange);
    _danmakuAppIdFocus.addListener(_handleDanmakuAppIdFocusChange);
    _danmakuTokenFocus.addListener(_handleDanmakuTokenFocusChange);
    for (final node in _webDavFocusNodes) {
      node.addListener(_handleWebDavFocusChange);
    }
    _load();
    _loadWebDav();
  }

  @override
  void dispose() {
    _danmakuServerFocus.removeListener(_handleDanmakuServerFocusChange);
    _danmakuAppIdFocus.removeListener(_handleDanmakuAppIdFocusChange);
    _danmakuTokenFocus.removeListener(_handleDanmakuTokenFocusChange);
    for (final node in _webDavFocusNodes) {
      node.removeListener(_handleWebDavFocusChange);
    }
    _danmakuServerFocus.dispose();
    _danmakuAppIdFocus.dispose();
    _danmakuTokenFocus.dispose();
    _danmakuServerController.dispose();
    _danmakuAppIdController.dispose();
    _danmakuTokenController.dispose();
    _webdavAddressFocus.dispose();
    _webdavUsernameFocus.dispose();
    _webdavPasswordFocus.dispose();
    _webdavDirectoryFocus.dispose();
    _webdavAddressController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    _webdavDirectoryController.dispose();
    super.dispose();
  }

  List<FocusNode> get _webDavFocusNodes => [
    _webdavAddressFocus,
    _webdavUsernameFocus,
    _webdavPasswordFocus,
    _webdavDirectoryFocus,
  ];

  Future<void> _load() async {
    try {
      final store = widget.settingsStore ?? await openPlayerSettingsStore();
      final settings = await store.read();
      if (!mounted) {
        return;
      }
      setState(() {
        _store = store;
        _settings = settings;
        _loaded = true;
      });
      _syncDanmakuControllers();
    } catch (_) {
      if (mounted) {
        setState(() => _loaded = true);
      }
    }
  }

  Future<void> _save(PlayerSettings next) async {
    if (_store == null) {
      _saveFailed();
      return;
    }
    final previous = _settings;
    final revision = ++_saveRevision;
    final merged = _mergeSettings(_settings, next);
    setState(() => _settings = merged);
    _syncDanmakuControllers();
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      final write = _pendingWrites.then((_) => store.writePatch(next));
      _pendingWrites = write.then<void>((_) {}, onError: (Object _) {});
      await write;
    } catch (_) {
      if (mounted) {
        if (revision == _saveRevision) {
          setState(() => _settings = previous);
          _syncDanmakuControllers();
        }
        _saveFailed();
      }
    }
  }

  void _saveFailed() {
    AppNoticeHost.of(context)
        .show(AppLocalizations.of(context).settingsSaveFailed);
  }

  /// 弹幕显示只携带 [PlayerSettings.danmakuDisplay],其余字段留 null 走合并写。
  Future<void> _saveDanmakuDisplay(DanmakuDisplaySettings next) {
    return _save(PlayerSettings(danmakuDisplay: next));
  }

  TargetPlatform get _platform => widget.platform ?? defaultTargetPlatform;

  /// WebDAV 动作可用:配置已加载且没有动作进行中。
  bool get _webDavIdle => _webdavLoaded && _webdavAction == null;

  void _handleDanmakuServerFocusChange() {
    // 失焦即提交,点击页面其他区域也能保存输入。
    if (!_danmakuServerFocus.hasFocus) {
      _commitDanmakuService();
    }
  }

  void _handleDanmakuAppIdFocusChange() {
    if (!_danmakuAppIdFocus.hasFocus) {
      _commitDanmakuService();
    }
  }

  void _handleDanmakuTokenFocusChange() {
    if (!_danmakuTokenFocus.hasFocus) {
      _commitDanmakuService();
    }
  }

  /// 提交弹幕服务输入:与已存值一致时不写,避免无谓落盘。
  void _commitDanmakuService() {
    final server = _danmakuServerController.text.trim();
    final appId = _danmakuAppIdController.text.trim();
    final token = _danmakuTokenController.text.trim();
    if (server == (_settings.danmakuServer ?? '') &&
        appId == (_settings.danmakuAppId ?? '') &&
        token == (_settings.danmakuToken ?? '')) {
      return;
    }
    unawaited(_saveDanmakuService(server, appId, token));
  }

  /// 弹幕服务保存:只写入本次输入,保留播放进程管理的音量等字段。
  ///
  /// 未由本页写入的字段(弹幕显示参数、按剧记忆等)由 store 合并写保留;
  /// 空串显式覆盖旧值即清除(回官方源),弹幕控制器读取时把空串按未配置解析。
  Future<void> _saveDanmakuService(String server, String appId, String token) {
    return _save(
      PlayerSettings(
        danmakuServer: server,
        danmakuAppId: appId,
        danmakuToken: token,
      ),
    );
  }

  Future<void> _restoreDefaults() {
    // 只恢复播放分类,弹幕服务与显示样式由各自分类维护。
    return _save(
      PlayerSettings(
        diskCacheLimitMiB: PlayerRuntimeDefaults.diskCacheLimitMiB,
        hardwareDecoding: HardwareDecodingMode.auto,
        hardwareDecoder: HardwareDecoderBackend.auto,
        playbackRate: 1,
        phoneSubtitles: const PhoneSubtitleSettings(),
        skipIntroEnabled: true,
        skipOutroEnabled: true,
      ),
    );
  }

  /// 页面状态中的弹幕服务值回填输入框(加载完成/恢复默认时);
  /// 正在输入的字段不打扰。
  void _syncDanmakuControllers() {
    if (!_danmakuServerFocus.hasFocus) {
      final server = _settings.danmakuServer ?? '';
      if (_danmakuServerController.text != server) {
        _danmakuServerController.text = server;
      }
    }
    if (!_danmakuAppIdFocus.hasFocus) {
      final appId = _settings.danmakuAppId ?? '';
      if (_danmakuAppIdController.text != appId) {
        _danmakuAppIdController.text = appId;
      }
    }
    if (!_danmakuTokenFocus.hasFocus) {
      final token = _settings.danmakuToken ?? '';
      if (_danmakuTokenController.text != token) {
        _danmakuTokenController.text = token;
      }
    }
  }

  AuthController? get _authController =>
      widget.auth ?? AuthScope.maybeOf(context);

  /// 生产备份根目录:与 [createProductionAuth] 同一应用支持目录,
  /// 校验环境可用环境变量隔离到一次性目录。
  Future<Directory> _defaultWebDavDirectory() async {
    final validation = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
    if (validation != null && validation.isNotEmpty) {
      if (!Directory(validation).isAbsolute) {
        throw ArgumentError('Validation directory must be absolute');
      }
      return Directory(validation);
    }
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/rillight');
  }

  Future<void> _loadWebDav() async {
    try {
      final directory =
          widget.webdavDirectory ?? await _defaultWebDavDirectory();
      final store =
          widget.webdavStore ??
          WebDavConfigStore(File('${directory.path}/webdav.json'));
      final config = await store.load();
      if (!mounted) {
        return;
      }
      _webdavDirectory = directory;
      _webdavStore = store;
      _webdavConfig = config;
      _syncWebDavControllers();
      setState(() => _webdavLoaded = true);
    } on FormatException {
      // 配置损坏时保留原文件;空表单重新保存即可修复。
      if (!mounted) {
        return;
      }
      setState(() => _webdavLoaded = true);
      AppNoticeHost.of(context)
          .show(AppLocalizations.of(context).settingsWebDavLocalConfigCorrupt);
    } on Object {
      if (mounted) {
        setState(() => _webdavLoaded = true);
      }
    }
  }

  void _handleWebDavFocusChange() {
    for (final node in _webDavFocusNodes) {
      if (node.hasFocus) {
        return;
      }
    }
    unawaited(_commitWebDavConfig());
  }

  WebDavConfig get _currentWebDavConfig => WebDavConfig(
    address: _webdavAddressController.text.trim(),
    username: _webdavUsernameController.text.trim(),
    password: _webdavPasswordController.text,
    directory: _webdavDirectoryController.text.trim(),
  );

  bool _webDavConfigEquals(WebDavConfig a, WebDavConfig b) =>
      a.address == b.address &&
      a.username == b.username &&
      a.password == b.password &&
      a.directory == b.directory;

  /// 提交表单到 webdav.json;与已存值一致时不写。失败给出可重试提示。
  Future<bool> _commitWebDavConfig() async {
    final store = _webdavStore;
    if (store == null || !_webdavLoaded) {
      return false;
    }
    final config = _currentWebDavConfig;
    if (_webDavConfigEquals(config, _webdavConfig)) {
      return true;
    }
    try {
      await store.save(config);
      _webdavConfig = config;
      return true;
    } on Object {
      if (mounted) {
        AppNoticeHost.of(context)
            .show(AppLocalizations.of(context).settingsWebDavSaveFailed);
      }
      return false;
    }
  }

  void _syncWebDavControllers() {
    void sync(TextEditingController controller, FocusNode focus, String value) {
      if (!focus.hasFocus && controller.text != value) {
        controller.text = value;
      }
    }

    sync(_webdavAddressController, _webdavAddressFocus, _webdavConfig.address);
    sync(
      _webdavUsernameController,
      _webdavUsernameFocus,
      _webdavConfig.username,
    );
    sync(
      _webdavPasswordController,
      _webdavPasswordFocus,
      _webdavConfig.password,
    );
    sync(
      _webdavDirectoryController,
      _webdavDirectoryFocus,
      _webdavConfig.directory,
    );
  }

  WebDavClient _webDavClientFor(WebDavConfig config) =>
      widget.webdavClientFactory?.call(config) ??
      WebDavClient.fromConfig(config);

  /// 动作前置:先落盘表单,未配置地址时给出指引而不是静默失败。
  Future<bool> _beginWebDavAction(_WebDavAction action) async {
    if (_webdavAction != null) {
      return false;
    }
    if (!await _commitWebDavConfig()) {
      return false;
    }
    if (_webdavConfig.address.isEmpty) {
      if (mounted) {
        AppNoticeHost.of(context)
            .show(AppLocalizations.of(context).settingsWebDavNotConfigured);
      }
      return false;
    }
    setState(() => _webdavAction = action);
    return true;
  }

  void _finishWebDavAction() {
    if (mounted) {
      setState(() => _webdavAction = null);
    }
  }

  String _webDavFailureMessage(
    AppLocalizations l10n,
    WebDavFailureKind kind,
    int? statusCode, {
    required String fallback,
  }) => switch (kind) {
    WebDavFailureKind.credentialError => l10n.settingsWebDavCredentialError,
    WebDavFailureKind.unreachable => l10n.settingsWebDavUnreachable,
    WebDavFailureKind.httpError =>
      statusCode != null ? l10n.settingsWebDavHttpError(statusCode) : fallback,
  };

  Future<void> _testWebDavConnection() async {
    final l10n = AppLocalizations.of(context);
    if (!await _beginWebDavAction(_WebDavAction.testing)) {
      return;
    }
    try {
      final result = await _webDavClientFor(_webdavConfig).testConnection();
      if (!mounted) {
        return;
      }
      AppNoticeHost.of(context).show(switch (result) {
        WebDavConnectionSuccess() => l10n.settingsWebDavConnectionOk,
        WebDavConnectionCredentialError() => l10n.settingsWebDavCredentialError,
        WebDavConnectionDirectoryMissing() =>
          l10n.settingsWebDavDirectoryMissing,
        WebDavConnectionHttpError(:final statusCode) =>
          l10n.settingsWebDavHttpError(statusCode),
        WebDavConnectionUnreachable() => l10n.settingsWebDavUnreachable,
      });
    } finally {
      _finishWebDavAction();
    }
  }

  String _webDavTimestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  Future<void> _backupToWebDav() async {
    final l10n = AppLocalizations.of(context);
    final auth = _authController;
    final directory = _webdavDirectory;
    if (!await _beginWebDavAction(_WebDavAction.backingUp)) {
      return;
    }
    try {
      if (auth == null || directory == null) {
        if (mounted) {
          AppNoticeHost.of(context).show(l10n.settingsWebDavBackupFailed);
        }
        return;
      }
      Map<String, dynamic> bundle;
      try {
        final collect = widget.webdavBundleCollector ?? collectBackupBundle;
        bundle = await collect(directory, auth.credentials);
      } on FormatException {
        if (mounted) {
          AppNoticeHost.of(context).show(l10n.settingsWebDavLocalConfigCorrupt);
        }
        return;
      } on Object {
        if (mounted) {
          AppNoticeHost.of(context).show(l10n.settingsWebDavBackupFailed);
        }
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(bundle)));
      final result = await _webDavClientFor(_webdavConfig).upload(bytes);
      if (!mounted) {
        return;
      }
      AppNoticeHost.of(context).show(switch (result) {
        WebDavUploadSuccess() => l10n.settingsWebDavBackupDone(
          _webDavTimestamp(),
        ),
        WebDavUploadFailure(:final kind, :final statusCode) =>
          _webDavFailureMessage(
            l10n,
            kind,
            statusCode,
            fallback: l10n.settingsWebDavBackupFailed,
          ),
      });
    } finally {
      _finishWebDavAction();
    }
  }

  Future<void> _restoreFromWebDav() async {
    final l10n = AppLocalizations.of(context);
    final auth = _authController;
    final directory = _webdavDirectory;
    if (!await _beginWebDavAction(_WebDavAction.restoring)) {
      return;
    }
    try {
      if (auth == null || directory == null) {
        if (mounted) {
          AppNoticeHost.of(context).show(l10n.settingsWebDavRestoreFailed);
        }
        return;
      }
      final download = await _webDavClientFor(_webdavConfig).download();
      if (!mounted) {
        return;
      }
      if (download is WebDavDownloadNoBackup) {
        AppNoticeHost.of(context).show(l10n.settingsWebDavNoBackup);
        return;
      }
      if (download is WebDavDownloadFailure) {
        AppNoticeHost.of(context).show(
          _webDavFailureMessage(
            l10n,
            download.kind,
            download.statusCode,
            fallback: l10n.settingsWebDavRestoreFailed,
          ),
        );
        return;
      }
      final apply = widget.webdavBundleApplier ?? applyBackupBundleBytes;
      final applied = await apply(
        (download as WebDavDownloadSuccess).bytes,
        directory,
        auth.credentials,
      );
      if (!mounted) {
        return;
      }
      if (applied is WebDavApplyRejected) {
        // 校验拒绝时零写入,本地数据保持原样。
        AppNoticeHost.of(context).show(l10n.settingsWebDavRestoreRejected);
        return;
      }
      await _reloadAfterRestore();
      if (mounted) {
        AppNoticeHost.of(context).show(l10n.settingsWebDavRestored);
      }
    } on Object {
      if (mounted) {
        AppNoticeHost.of(context).show(l10n.settingsWebDavRestoreFailed);
      }
    } finally {
      _finishWebDavAction();
    }
  }

  /// 恢复成功后的原位重载:bundle 可能改写了 webdav.json 与服务器列表,
  /// 先回填表单,再经 [AuthController.restore] 重建服务器列表与登录态。
  Future<void> _reloadAfterRestore() async {
    final store = _webdavStore;
    if (store != null) {
      try {
        _webdavConfig = await store.load();
        _syncWebDavControllers();
      } on Object {
        // 表单保持旧值即可,不影响已完成的恢复。
      }
    }
    final auth = _authController;
    if (auth == null) {
      return;
    }
    try {
      await auth.sources.load();
    } on Object {
      // 注册表加载失败时仍尝试控制器恢复。
    }
    try {
      await auth.restore();
    } on Object {
      // 恢复动作本身不弹失败:文件已应用,重载失败由界面各自呈现。
    }
  }

  /// 顶栏叠在内容上,正文下沉到返回钮与窗口按钮之下。
  double _overlayTop(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) {
      return 0;
    }
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    if (!hasChrome) {
      return AppShell.topBarHeight;
    }
    return kWindowChromeHeight > AppShell.topBarHeight
        ? kWindowChromeHeight
        : AppShell.topBarHeight;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final appearance = widget.appearance ?? AppearanceScope.maybeOf(context);
    final nav = PhoneNavStyle.maybeOf(context);
    final backends = PlayerRuntimeOptions.availableBackends(_platform);
    final limitChoices = <int>[...SettingsPage.diskCacheLimitChoices];
    final effectiveLimit = PlayerRuntimeOptions.effectiveDiskCacheLimitMiB(
      _settings,
    );
    if (!limitChoices.contains(effectiveLimit)) {
      limitChoices.add(effectiveLimit);
      limitChoices.sort();
    }
    final decoding = _settings.hardwareDecoding ?? HardwareDecodingMode.auto;
    final backend = _settings.hardwareDecoder ?? HardwareDecoderBackend.auto;
    final showPageTitle =
        widget.showTitle &&
        context.findAncestorWidgetOfExactType<AppShell>() == null;

    final sections = <_SettingsSectionSpec>[
      _SettingsSectionSpec(
        icon: AppIcons.info,
        title: l10n.mobileAboutGroup,
        subtitle: '$kProductName · $kAppVersion',
        children: const [UpdateCheck()],
      ),
      _SettingsSectionSpec(
        icon: AppIcons.appearance,
        title: l10n.settingsAppearance,
        subtitle: (appearance?.style ?? AppearanceStyle.system).label(l10n),
        children: [
          if (nav != null)
            ListenableBuilder(
              listenable: nav,
              builder: (context, _) => AppSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.phoneFloatingNav),
                subtitle: Text(l10n.phoneFloatingNavHint),
                value: nav.floating,
                onChanged: (value) => unawaited(nav.setFloating(value)),
              ),
            ),
          Builder(
            builder: (context) {
              final current = appearance?.style ?? AppearanceStyle.system;
              VoidCallback? choose(AppearanceStyle value) => appearance == null
                  ? null
                  : () => unawaited(appearance.setStyle(value));
              if (_TwoPaneScope.of(context)) {
                return _AppearancePreviews(
                  key: SettingsPage.appearanceKey,
                  current: current,
                  labelOf: (value) => value.label(l10n),
                  onSelect: choose,
                );
              }
              return _SettingsOptionBlock(
                key: SettingsPage.appearanceKey,
                options: [
                  for (final value in AppearanceStyle.values)
                    PlayerOption(
                      key: ValueKey('settings-appearance-${value.name}'),
                      label: value.label(l10n),
                      selected: current == value,
                      onPressed: choose(value),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      _SettingsSectionSpec(
        icon: AppIcons.playbackSection,
        title: l10n.settingsPlayback,
        subtitle:
            '${_settings.effectivePlaybackRate}× · ${l10n.settingsCacheSize(effectiveLimit / 1024)}',
        trailing: AppButton.icon(
          key: SettingsPage.restoreDefaultsKey,
          onPressed: _loaded ? _restoreDefaults : null,
          style: AppButtonStyle(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          ),
          icon: const Icon(AppIcons.replay, fill: AppIcons.filled),
          label: Text(l10n.settingsRestoreDefaults),
          variant: AppButtonVariant.plain,
        ),
        children: [
          PhoneSubtitleSettingsControls(
            value: _settings.effectivePhoneSubtitles,
            onChanged: (value) =>
                unawaited(_save(PlayerSettings(phoneSubtitles: value))),
          ),
          const AppDivider(),
          Padding(
            key: const Key('settings-playback-rate'),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.playbackRate,
                  style: AppUiTheme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                PlayerRateGrid(
                  selected: _settings.effectivePlaybackRate,
                  enabled: _loaded,
                  onSelected: (value) =>
                      unawaited(_save(PlayerSettings(playbackRate: value))),
                ),
              ],
            ),
          ),
          AppSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.settingsSkipIntro),
            subtitle: Text(l10n.settingsSkipIntroHint),
            value: _settings.isSkipIntroEnabled,
            onChanged: !_loaded
                ? null
                : (value) =>
                      unawaited(_save(PlayerSettings(skipIntroEnabled: value))),
          ),
          AppSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.settingsSkipOutro),
            subtitle: Text(l10n.settingsSkipOutroHint),
            value: _settings.isSkipOutroEnabled,
            onChanged: !_loaded
                ? null
                : (value) =>
                      unawaited(_save(PlayerSettings(skipOutroEnabled: value))),
          ),
          _SettingsOptionBlock(
            key: SettingsPage.diskCacheLimitKey,
            label: l10n.settingsDiskCacheLimit,
            options: [
              for (final limit in limitChoices)
                PlayerOption(
                  key: ValueKey('settings-cache-$limit'),
                  label: l10n.settingsCacheSize(limit / 1024),
                  selected: limit == effectiveLimit,
                  onPressed: _loaded
                      ? () => unawaited(
                          _save(PlayerSettings(diskCacheLimitMiB: limit)),
                        )
                      : null,
                ),
            ],
          ),
          _SettingsOptionBlock(
            key: SettingsPage.hardwareDecodingKey,
            label: l10n.settingsHardwareDecoding,
            options: [
              for (final mode in HardwareDecodingMode.values)
                PlayerOption(
                  key: ValueKey('settings-decoding-${mode.name}'),
                  label: switch (mode) {
                    HardwareDecodingMode.auto =>
                      l10n.settingsHardwareDecodingAuto,
                    HardwareDecodingMode.on => l10n.settingsHardwareDecodingOn,
                    HardwareDecodingMode.off =>
                      l10n.settingsHardwareDecodingOff,
                  },
                  selected: mode == decoding,
                  onPressed: _loaded
                      ? () => unawaited(
                          _save(PlayerSettings(hardwareDecoding: mode)),
                        )
                      : null,
                ),
            ],
          ),
          if (backends.length > 1)
            _SettingsOptionBlock(
              key: SettingsPage.decoderBackendKey,
              label: l10n.settingsDecoderBackend,
              options: [
                for (final value in backends)
                  PlayerOption(
                    key: ValueKey('settings-backend-${value.name}'),
                    label: _backendLabel(l10n, value),
                    selected:
                        value ==
                        (backends.contains(backend)
                            ? backend
                            : HardwareDecoderBackend.auto),
                    onPressed: _loaded
                        ? () => unawaited(
                            _save(PlayerSettings(hardwareDecoder: value)),
                          )
                        : null,
                  ),
              ],
            ),
        ],
      ),
      _SettingsSectionSpec(
        icon: AppIcons.output,
        title: l10n.playbackOutputSection,
        subtitle: l10n.settingsOutputSummary,
        children: [
          const PlaybackOutputPanel(status: PlaybackOutputStatus.unknown),
        ],
      ),
      _SettingsSectionSpec(
        icon: AppIcons.danmaku,
        title: l10n.settingsDanmakuConfiguration,
        subtitle: l10n.settingsDanmakuConfigurationSummary,
        trailing: AppButton.icon(
          key: DanmakuKeys.restoreDefaults,
          onPressed: _loaded
              ? () => _saveDanmakuDisplay(const DanmakuDisplaySettings())
              : null,
          style: AppButtonStyle(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          ),
          icon: const Icon(AppIcons.replay, fill: AppIcons.filled),
          label: Text(l10n.danmakuRestoreDefaults),
          variant: AppButtonVariant.plain,
        ),
        children: [
          DanmakuDisplayForm(
            value: _settings.danmakuDisplay ?? const DanmakuDisplaySettings(),
            onChanged: _loaded ? _saveDanmakuDisplay : (_) {},
            layout: DanmakuFormLayout.settings,
          ),
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.lg,
              bottom: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settingsDanmakuService,
                  style: AppUiTheme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.settingsDanmakuServiceHint,
                  style: AppUiTheme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _SettingsField(
            label: l10n.settingsDanmakuServer,
            child: AppTextField(
              key: SettingsPage.danmakuServerFieldKey,
              controller: _danmakuServerController,
              focusNode: _danmakuServerFocus,
              enabled: _loaded,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) {
                _commitDanmakuService();
                _danmakuAppIdFocus.requestFocus();
              },
              placeholder: l10n.settingsDanmakuServerHint,
            ),
          ),
          _SettingsField(
            label: l10n.settingsDanmakuAppId,
            child: AppTextField(
              key: SettingsPage.danmakuAppIdFieldKey,
              controller: _danmakuAppIdController,
              focusNode: _danmakuAppIdFocus,
              enabled: _loaded,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) {
                _commitDanmakuService();
                _danmakuTokenFocus.requestFocus();
              },
              placeholder: l10n.settingsDanmakuAppIdHint,
            ),
          ),
          _SettingsField(
            label: l10n.settingsDanmakuToken,
            child: AppTextField(
              key: SettingsPage.danmakuTokenFieldKey,
              controller: _danmakuTokenController,
              focusNode: _danmakuTokenFocus,
              enabled: _loaded,
              obscureText: !_tokenVisible,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _commitDanmakuService(),
              placeholder: l10n.settingsDanmakuTokenHint,
              suffix: AppIconButton(
                key: SettingsPage.tokenVisibilityKey,
                tooltip: _tokenVisible
                    ? l10n.settingsHideToken
                    : l10n.settingsShowToken,
                onPressed: () {
                  setState(() => _tokenVisible = !_tokenVisible);
                },
                icon: Icon(
                  AppIcons.visibility,
                  fill: _tokenVisible ? AppIcons.filled : AppIcons.outline,
                ),
              ),
            ),
          ),
        ],
      ),
      _SettingsSectionSpec(
        icon: AppIcons.cloud,
        title: l10n.settingsWebDavSection,
        subtitle: l10n.settingsWebDavSectionSummary,
        children: [
          _SettingsField(
            label: l10n.settingsWebDavAddress,
            child: AppTextField(
              key: SettingsPage.webDavAddressFieldKey,
              controller: _webdavAddressController,
              focusNode: _webdavAddressFocus,
              enabled: _webdavLoaded,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) {
                unawaited(_commitWebDavConfig());
                _webdavUsernameFocus.requestFocus();
              },
              placeholder: l10n.settingsWebDavAddressHint,
            ),
          ),
          _SettingsField(
            label: l10n.settingsWebDavUsername,
            child: AppTextField(
              key: SettingsPage.webDavUsernameFieldKey,
              controller: _webdavUsernameController,
              focusNode: _webdavUsernameFocus,
              enabled: _webdavLoaded,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) {
                unawaited(_commitWebDavConfig());
                _webdavPasswordFocus.requestFocus();
              },
            ),
          ),
          _SettingsField(
            label: l10n.settingsWebDavPassword,
            child: AppTextField(
              key: SettingsPage.webDavPasswordFieldKey,
              controller: _webdavPasswordController,
              focusNode: _webdavPasswordFocus,
              enabled: _webdavLoaded,
              obscureText: !_webdavPasswordVisible,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) {
                unawaited(_commitWebDavConfig());
                _webdavDirectoryFocus.requestFocus();
              },
              suffix: AppIconButton(
                key: SettingsPage.webDavPasswordVisibilityKey,
                tooltip: _webdavPasswordVisible
                    ? l10n.settingsWebDavPasswordHide
                    : l10n.settingsWebDavPasswordShow,
                onPressed: () {
                  setState(
                    () => _webdavPasswordVisible = !_webdavPasswordVisible,
                  );
                },
                icon: Icon(
                  AppIcons.visibility,
                  fill: _webdavPasswordVisible
                      ? AppIcons.filled
                      : AppIcons.outline,
                ),
              ),
            ),
          ),
          _SettingsField(
            label: l10n.settingsWebDavDirectory,
            child: AppTextField(
              key: SettingsPage.webDavDirectoryFieldKey,
              controller: _webdavDirectoryController,
              focusNode: _webdavDirectoryFocus,
              enabled: _webdavLoaded,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_commitWebDavConfig()),
              placeholder: l10n.settingsWebDavDirectoryHint,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                AppButton.icon(
                  key: SettingsPage.webDavTestConnectionKey,
                  onPressed: _webDavIdle
                      ? () => unawaited(_testWebDavConnection())
                      : null,
                  icon: const Icon(AppIcons.lan, fill: AppIcons.filled),
                  label: Text(l10n.settingsWebDavTestConnection),
                  variant: AppButtonVariant.tinted,
                ),
                AppButton.icon(
                  key: SettingsPage.webDavBackupKey,
                  onPressed: _webDavIdle
                      ? () => unawaited(_backupToWebDav())
                      : null,
                  icon: const Icon(AppIcons.cloud, fill: AppIcons.filled),
                  label: Text(l10n.settingsWebDavBackup),
                  variant: AppButtonVariant.outlined,
                ),
                AppButton.icon(
                  key: SettingsPage.webDavRestoreKey,
                  onPressed: _webDavIdle
                      ? () => unawaited(_restoreFromWebDav())
                      : null,
                  icon: const Icon(AppIcons.download, fill: AppIcons.filled),
                  label: Text(l10n.settingsWebDavRestore),
                  variant: AppButtonVariant.outlined,
                ),
              ],
            ),
          ),
        ],
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            !PresentationScope.isPhoneOf(context) &&
            constraints.maxWidth >= SettingsPage.twoPaneMinWidth;
        if (wide) {
          return _twoPane(context, sections, showPageTitle);
        }
        return _accordion(context, sections, showPageTitle);
      },
    );
  }

  /// 宽窗口:左侧分类、右侧内容。分类常驻,不必逐个展开找设置。
  Widget _twoPane(
    BuildContext context,
    List<_SettingsSectionSpec> sections,
    bool showPageTitle,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    // 关于放到最后;默认打开外观,而不是一张只有版本号的卡。
    final ordered = [
      for (final section in sections)
        if (section.title != l10n.mobileAboutGroup) section,
      for (final section in sections)
        if (section.title == l10n.mobileAboutGroup) section,
    ];
    final selected =
        ordered.where((s) => s.title == _selectedSection).firstOrNull ??
        ordered.first;
    final top = _overlayTop(context) + AppSpacing.xl;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        key: SettingsPage.columnKey,
        constraints: BoxConstraints(
          maxWidth: AppViewport.dp(
            SettingsPage.twoPaneMaxWidth,
            MediaQuery.sizeOf(context),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: SettingsPage.navWidth,
              child: ListView(
                key: SettingsPage.navKey,
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  top,
                  0,
                  AppSpacing.xl,
                ),
                children: [
                  if (showPageTitle) ...[
                    Text(l10n.settings, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  for (final section in ordered) ...[
                    _SettingsNavItem(
                      key: ValueKey('settings-section-${section.title}'),
                      icon: section.icon,
                      title: section.title,
                      selected: identical(section, selected),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _selectedSection = section.title);
                      },
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.xxl),
            Expanded(
              child: ListView(
                key: ValueKey('settings-pane-${selected.title}'),
                padding: EdgeInsets.fromLTRB(
                  0,
                  top,
                  AppSpacing.page,
                  AppSpacing.xxl,
                ),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selected.title,
                              style: theme.textTheme.headlineSmall,
                            ),
                            if (selected.subtitle != null) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                selected.subtitle!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (selected.trailing != null) selected.trailing!,
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _TwoPaneScope(
                    child: Container(
                      key: ValueKey('settings-section-body-${selected.title}'),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xl,
                        AppSpacing.md,
                        AppSpacing.xl,
                        AppSpacing.md,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadii.lg),
                        border: Border.all(color: AppEdge.of(theme.brightness)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (
                            var i = 0;
                            i < selected.children.length;
                            i++
                          ) ...[
                            if (i > 0) const AppDivider(height: AppSpacing.sm),
                            selected.children[i],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 窄窗口与手机:可折叠的分组卡。
  Widget _accordion(
    BuildContext context,
    List<_SettingsSectionSpec> sections,
    bool showPageTitle,
  ) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        _overlayTop(context) + AppSpacing.xl,
        AppSpacing.page,
        AppSpacing.xl,
      ),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            key: SettingsPage.columnKey,
            constraints: BoxConstraints(
              maxWidth: AppViewport.dp(
                SettingsPage.columnMaxWidth,
                MediaQuery.sizeOf(context),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showPageTitle) ...[
                  Text(
                    l10n.settings,
                    style: AppUiTheme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.lg),
                  _SettingsSection(
                    icon: sections[i].icon,
                    title: sections[i].title,
                    subtitle: sections[i].subtitle,
                    trailing: sections[i].trailing,
                    children: sections[i].children,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _backendLabel(AppLocalizations l10n, HardwareDecoderBackend backend) {
    switch (backend) {
      case HardwareDecoderBackend.d3d11va:
        return l10n.settingsBackendD3d11va;
      case HardwareDecoderBackend.nvdec:
        return l10n.settingsBackendNvdec;
      case HardwareDecoderBackend.videotoolbox:
        return l10n.settingsBackendVideotoolbox;
      case HardwareDecoderBackend.auto:
        return l10n.settingsBackendAuto;
    }
  }
}

/// WebDAV 分节动作的进行中状态;任一动作进行时三个按钮全部禁用。
enum _WebDavAction { testing, backingUp, restoring }

/// 页面内存态合并:补丁未携带的字段保持当前值,避免稀疏写把下拉框与服务输入清空。
PlayerSettings _mergeSettings(PlayerSettings current, PlayerSettings patch) {
  return PlayerSettings(
    volume: patch.volume ?? current.volume,
    diskCacheLimitMiB: patch.diskCacheLimitMiB ?? current.diskCacheLimitMiB,
    hardwareDecoding: patch.hardwareDecoding ?? current.hardwareDecoding,
    hardwareDecoder: patch.hardwareDecoder ?? current.hardwareDecoder,
    playbackRate: patch.playbackRate ?? current.playbackRate,
    skipIntroEnabled: patch.skipIntroEnabled ?? current.skipIntroEnabled,
    skipOutroEnabled: patch.skipOutroEnabled ?? current.skipOutroEnabled,
    updateReminderEnabled:
        patch.updateReminderEnabled ?? current.updateReminderEnabled,
    ignoredUpdateVersion:
        patch.ignoredUpdateVersion ?? current.ignoredUpdateVersion,
    phoneSubtitles: patch.phoneSubtitles ?? current.phoneSubtitles,
    seriesPreferences: patch.seriesPreferences.isNotEmpty
        ? patch.seriesPreferences
        : current.seriesPreferences,
    danmakuEnabled: patch.danmakuEnabled ?? current.danmakuEnabled,
    danmakuDisplay: patch.danmakuDisplay ?? current.danmakuDisplay,
    danmakuServer: patch.danmakuServer ?? current.danmakuServer,
    danmakuToken: patch.danmakuToken ?? current.danmakuToken,
    danmakuAppId: patch.danmakuAppId ?? current.danmakuAppId,
    danmakuSeriesMemories: patch.danmakuSeriesMemories.isNotEmpty
        ? patch.danmakuSeriesMemories
        : current.danmakuSeriesMemories,
  );
}

/// 标记两栏布局的正文区:外观等分类在宽窗口里换用更直观的呈现。
class _TwoPaneScope extends InheritedWidget {
  const _TwoPaneScope({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TwoPaneScope>() != null;

  @override
  bool updateShouldNotify(_TwoPaneScope oldWidget) => false;
}

/// 宽窗口的外观选择:每个选项是一扇缩略窗口,直接看到浅色/深色的样子。
class _AppearancePreviews extends StatelessWidget {
  const _AppearancePreviews({
    super.key,
    required this.current,
    required this.labelOf,
    required this.onSelect,
  });

  final AppearanceStyle current;
  final String Function(AppearanceStyle) labelOf;
  final VoidCallback? Function(AppearanceStyle) onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [
          for (final value in AppearanceStyle.values)
            _AppearancePreviewTile(
              key: ValueKey('settings-appearance-${value.name}'),
              style: value,
              label: labelOf(value),
              selected: value == current,
              onPressed: onSelect(value),
            ),
        ],
      ),
    );
  }
}

class _AppearancePreviewTile extends StatefulWidget {
  const _AppearancePreviewTile({
    super.key,
    required this.style,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final AppearanceStyle style;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  static const double width = 184;
  static const double height = 116;

  @override
  State<_AppearancePreviewTile> createState() => _AppearancePreviewTileState();
}

class _AppearancePreviewTileState extends State<_AppearancePreviewTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selected;
    final radius = BorderRadius.circular(AppRadii.lg);
    final preview = switch (widget.style) {
      AppearanceStyle.light => _mockWindow(AppUiTheme.lightTones),
      AppearanceStyle.dark => _mockWindow(AppUiTheme.darkTones),
      AppearanceStyle.system => Row(
        children: [
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: _AppearancePreviewTile.width,
                child: _mockWindow(AppUiTheme.lightTones),
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerRight,
                maxWidth: _AppearancePreviewTile.width,
                child: _mockWindow(AppUiTheme.darkTones),
              ),
            ),
          ),
        ],
      ),
    };
    return Semantics(
      selected: selected,
      label: widget.label,
      child: AppSurfaceAction(
        borderRadius: radius,
        onTap: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        child: SizedBox(
          width: _AppearancePreviewTile.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: AppMotion.durationOf(context, AppMotion.fast),
                curve: AppMotion.standard,
                height: _AppearancePreviewTile.height,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: selected
                        ? scheme.primary
                        : _hovered
                        ? scheme.outline
                        : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.lg - 3),
                  child: preview,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  AnimatedContainer(
                    duration: AppMotion.durationOf(context, AppMotion.fast),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? scheme.primary
                          : const Color(0x00000000),
                      border: Border.all(
                        color: selected ? scheme.primary : scheme.outline,
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? Icon(
                            AppIcons.check,
                            size: 13,
                            color: scheme.onPrimary,
                          )
                        : null,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    widget.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一扇缩略窗口:顶栏、hero 色块与一排海报,按给定色调着色。
  Widget _mockWindow(Tones tones) {
    Widget block(double w, double h, Color color, [double r = 3]) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(r),
      ),
    );
    return Container(
      width: _AppearancePreviewTile.width,
      color: tones.base,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              block(18, 5, tones.accent),
              const SizedBox(width: 4),
              block(14, 5, tones.surfaceHighest),
              const Spacer(),
              block(36, 7, tones.surfaceHigh, 4),
              const SizedBox(width: 4),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: tones.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Container(
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                colors: [tones.accentContainer, tones.secondaryContainer],
              ),
            ),
            padding: const EdgeInsets.all(6),
            alignment: Alignment.bottomLeft,
            child: block(28, 5, tones.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              for (var i = 0; i < 5; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(child: block(0, 30, tones.surfaceHigh)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 一个设置分类:图标、标题、摘要、标题行操作与正文。两种布局共用。
class _SettingsSectionSpec {
  const _SettingsSectionSpec({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;
}

/// 两栏布局左侧的分类行。选中为强调色浅底与实心图标,悬停给出轻底色。
class _SettingsNavItem extends StatefulWidget {
  const _SettingsNavItem({
    super.key,
    required this.icon,
    required this.title,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selected;
    final radius = BorderRadius.circular(AppRadii.md);
    return Semantics(
      selected: selected,
      child: AppSurfaceAction(
        borderRadius: radius,
        onTap: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          curve: AppMotion.standard,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected
                ? scheme.primaryContainer.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.72 : 1,
                  )
                : _hovered
                ? scheme.surfaceContainerHigh
                : const Color(0x00000000),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 20,
                fill: selected ? AppIcons.filled : AppIcons.outline,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppEdge.of(theme.brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: AppDisclosure(
        key: ValueKey('settings-section-$title'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        onExpansionChanged: (expanded) {
          if (!expanded) FocusScope.of(context).unfocus();
        },
        leading: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: SizedBox.square(
            dimension: 40,
            child: Icon(
              icon,
              fill: AppIcons.filled,
              size: 20,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        title: Text(title, style: theme.textTheme.titleMedium),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AppDivider(height: 8),
              if (trailing != null)
                Align(alignment: Alignment.centerRight, child: trailing),
              const SizedBox(height: AppSpacing.xs),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const AppDivider(height: AppSpacing.sm),
                children[i],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsOptionBlock extends StatelessWidget {
  const _SettingsOptionBlock({super.key, this.label, required this.options});

  final String? label;
  final List<PlayerOption> options;

  @override
  Widget build(BuildContext context) {
    final title = label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title, style: AppUiTheme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
          ],
          PlayerOptionGrid(options: options),
        ],
      ),
    );
  }
}

class _SettingsField extends StatelessWidget {
  const _SettingsField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          child,
        ],
      ),
    );
  }
}
