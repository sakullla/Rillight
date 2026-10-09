import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
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
  });

  /// 测试注入;运行时留空用当前平台。
  final bool showTitle;
  final PlayerSettingsStore? settingsStore;
  final TargetPlatform? platform;

  /// 测试注入的外观控制器;运行时留空走 [AppearanceScope]。
  final AppearanceController? appearance;

  static const diskCacheLimitKey = Key('settings-disk-cache-limit');
  static const hardwareDecodingKey = Key('settings-hardware-decoding');
  static const decoderBackendKey = Key('settings-decoder-backend');
  static const appearanceKey = Key('settings-appearance');
  static const danmakuServerFieldKey = Key('settings-danmaku-server');
  static const danmakuAppIdFieldKey = Key('settings-danmaku-app-id');
  static const danmakuTokenFieldKey = Key('settings-danmaku-token');
  static const restoreDefaultsKey = Key('settings-restore-defaults');
  static const tokenVisibilityKey = Key('settings-token-visibility');
  static const columnKey = Key('settings-column');

  /// 设置正文限宽,避免标签贴左、控件贴窗沿。
  static const double columnMaxWidth = 680;

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

  PlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  var _loaded = false;
  var _tokenVisible = false;
  var _saveRevision = 0;
  Future<void> _pendingWrites = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _danmakuServerFocus.addListener(_handleDanmakuServerFocusChange);
    _danmakuAppIdFocus.addListener(_handleDanmakuAppIdFocusChange);
    _danmakuTokenFocus.addListener(_handleDanmakuTokenFocusChange);
    _load();
  }

  @override
  void dispose() {
    _danmakuServerFocus.removeListener(_handleDanmakuServerFocusChange);
    _danmakuAppIdFocus.removeListener(_handleDanmakuAppIdFocusChange);
    _danmakuTokenFocus.removeListener(_handleDanmakuTokenFocusChange);
    _danmakuServerFocus.dispose();
    _danmakuAppIdFocus.dispose();
    _danmakuTokenFocus.dispose();
    _danmakuServerController.dispose();
    _danmakuAppIdController.dispose();
    _danmakuTokenController.dispose();
    super.dispose();
  }

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsSaveFailed)),
    );
  }

  /// 弹幕显示只携带 [PlayerSettings.danmakuDisplay],其余字段留 null 走合并写。
  Future<void> _saveDanmakuDisplay(DanmakuDisplaySettings next) {
    return _save(PlayerSettings(danmakuDisplay: next));
  }

  TargetPlatform get _platform => widget.platform ?? defaultTargetPlatform;

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
        frameInterpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
  }

  Future<void> _saveEnhancement(VideoEnhancementSelection selection) {
    return _save(
      PlayerSettings(
        frameInterpolation: selection.interpolation,
        anime4k: selection.anime4k,
        superResolution: selection.superResolution,
        denoise: selection.denoise,
        sharpen: selection.sharpen,
        acceptLeaveNativeDolby: selection.acceptLeaveNativeDolby,
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
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
                _SettingsSection(
                  icon: Icons.brightness_6_outlined,
                  title: l10n.settingsAppearance,
                  subtitle: (appearance?.style ?? AppearanceStyle.system).label(
                    l10n,
                  ),
                  children: [
                    if (nav != null)
                      ListenableBuilder(
                        listenable: nav,
                        builder: (context, _) => SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.phoneFloatingNav),
                          subtitle: Text(l10n.phoneFloatingNavHint),
                          value: nav.floating,
                          onChanged: (value) =>
                              unawaited(nav.setFloating(value)),
                        ),
                      ),
                    _SettingsOptionBlock(
                      key: SettingsPage.appearanceKey,
                      options: [
                        for (final value in AppearanceStyle.values)
                          PlayerOption(
                            key: ValueKey('settings-appearance-${value.name}'),
                            label: value.label(l10n),
                            selected:
                                (appearance?.style ?? AppearanceStyle.system) ==
                                value,
                            onPressed: appearance == null
                                ? null
                                : () => unawaited(appearance.setStyle(value)),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _SettingsSection(
                  icon: Icons.play_circle_outline_rounded,
                  title: l10n.settingsPlayback,
                  subtitle:
                      '${_settings.effectivePlaybackRate}× · ${l10n.settingsCacheSize(effectiveLimit / 1024)}',
                  trailing: TextButton.icon(
                    key: SettingsPage.restoreDefaultsKey,
                    onPressed: _loaded ? _restoreDefaults : null,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore_rounded),
                    label: Text(l10n.settingsRestoreDefaults),
                  ),
                  children: [
                    PhoneSubtitleSettingsControls(
                      value: _settings.effectivePhoneSubtitles,
                      onChanged: (value) => unawaited(
                        _save(PlayerSettings(phoneSubtitles: value)),
                      ),
                    ),
                    const Divider(),
                    Padding(
                      key: const Key('settings-playback-rate'),
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.playbackRate,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          PlayerRateGrid(
                            selected: _settings.effectivePlaybackRate,
                            enabled: _loaded,
                            onSelected: (value) => unawaited(
                              _save(PlayerSettings(playbackRate: value)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.settingsSkipIntro),
                      subtitle: Text(l10n.settingsSkipIntroHint),
                      value: _settings.isSkipIntroEnabled,
                      onChanged: !_loaded
                          ? null
                          : (value) => unawaited(
                              _save(PlayerSettings(skipIntroEnabled: value)),
                            ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.settingsSkipOutro),
                      subtitle: Text(l10n.settingsSkipOutroHint),
                      value: _settings.isSkipOutroEnabled,
                      onChanged: !_loaded
                          ? null
                          : (value) => unawaited(
                              _save(PlayerSettings(skipOutroEnabled: value)),
                            ),
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
                                    _save(
                                      PlayerSettings(diskCacheLimitMiB: limit),
                                    ),
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
                              HardwareDecodingMode.on =>
                                l10n.settingsHardwareDecodingOn,
                              HardwareDecodingMode.off =>
                                l10n.settingsHardwareDecodingOff,
                            },
                            selected: mode == decoding,
                            onPressed: _loaded
                                ? () => unawaited(
                                    _save(
                                      PlayerSettings(hardwareDecoding: mode),
                                    ),
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
                                      _save(
                                        PlayerSettings(hardwareDecoder: value),
                                      ),
                                    )
                                  : null,
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _SettingsSection(
                  icon: Icons.tune_rounded,
                  title: l10n.playbackOutputSection,
                  subtitle: l10n.playbackOutputIdle,
                  children: [
                    PlaybackOutputPanel(
                      status: PlaybackOutputStatus.unknown,
                      saved: _settings.videoEnhancement,
                      playbackRate: _settings.effectivePlaybackRate,
                      onDisable: () => _saveEnhancement(
                        const VideoEnhancementSelection(
                          interpolation: FrameInterpolation.off,
                          anime4k: Anime4kLevel.off,
                          superResolution: SuperResolution.off,
                          denoise: 0,
                          sharpen: 0,
                          acceptLeaveNativeDolby: false,
                        ),
                      ),
                      onKeepOutput: () {
                        final current = _settings.videoEnhancement;
                        return _saveEnhancement(
                          VideoEnhancementSelection(
                            interpolation: current.interpolation,
                            anime4k: current.anime4k,
                            superResolution: current.superResolution,
                            denoise: current.denoise,
                            sharpen: current.sharpen,
                            acceptLeaveNativeDolby: false,
                          ),
                        );
                      },
                      onSelect: _loaded ? _saveEnhancement : null,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _SettingsSection(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: l10n.settingsDanmakuConfiguration,
                  subtitle: l10n.settingsDanmakuConfigurationSummary,
                  trailing: TextButton.icon(
                    key: DanmakuKeys.restoreDefaults,
                    onPressed: _loaded
                        ? () => _saveDanmakuDisplay(
                            const DanmakuDisplaySettings(),
                          )
                        : null,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore_rounded),
                    label: Text(l10n.danmakuRestoreDefaults),
                  ),
                  children: [
                    DanmakuDisplayForm(
                      value:
                          _settings.danmakuDisplay ??
                          const DanmakuDisplaySettings(),
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
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            l10n.settingsDanmakuServiceHint,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    _SettingsField(
                      label: l10n.settingsDanmakuServer,
                      child: TextField(
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
                        decoration: InputDecoration(
                          hintText: l10n.settingsDanmakuServerHint,
                        ),
                      ),
                    ),
                    _SettingsField(
                      label: l10n.settingsDanmakuAppId,
                      child: TextField(
                        key: SettingsPage.danmakuAppIdFieldKey,
                        controller: _danmakuAppIdController,
                        focusNode: _danmakuAppIdFocus,
                        enabled: _loaded,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) {
                          _commitDanmakuService();
                          _danmakuTokenFocus.requestFocus();
                        },
                        decoration: InputDecoration(
                          hintText: l10n.settingsDanmakuAppIdHint,
                        ),
                      ),
                    ),
                    _SettingsField(
                      label: l10n.settingsDanmakuToken,
                      child: TextField(
                        key: SettingsPage.danmakuTokenFieldKey,
                        controller: _danmakuTokenController,
                        focusNode: _danmakuTokenFocus,
                        enabled: _loaded,
                        obscureText: !_tokenVisible,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _commitDanmakuService(),
                        decoration: InputDecoration(
                          hintText: l10n.settingsDanmakuTokenHint,
                          suffixIcon: IconButton(
                            key: SettingsPage.tokenVisibilityKey,
                            tooltip: _tokenVisible
                                ? l10n.settingsHideToken
                                : l10n.settingsShowToken,
                            onPressed: () {
                              setState(() => _tokenVisible = !_tokenVisible);
                            },
                            icon: Icon(
                              _tokenVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
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
    phoneSubtitles: patch.phoneSubtitles ?? current.phoneSubtitles,
    frameInterpolation: patch.frameInterpolation ?? current.frameInterpolation,
    anime4k: patch.anime4k ?? current.anime4k,
    superResolution: patch.superResolution ?? current.superResolution,
    denoise: patch.denoise ?? current.denoise,
    sharpen: patch.sharpen ?? current.sharpen,
    acceptLeaveNativeDolby:
        patch.acceptLeaveNativeDolby ?? current.acceptLeaveNativeDolby,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('settings-section-$title'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        shape: const Border(),
        collapsedShape: const Border(),
        onExpansionChanged: (expanded) {
          if (!expanded) FocusScope.of(context).unfocus();
        },
        leading: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
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
              if (trailing != null)
                Align(alignment: Alignment.centerRight, child: trailing),
              const SizedBox(height: AppSpacing.sm),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
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
            Text(title, style: Theme.of(context).textTheme.titleSmall),
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
    final theme = Theme.of(context);
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
