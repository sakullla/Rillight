import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/player/danmaku/danmaku_display_form.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

/// 设置页:播放器运行时选项(磁盘缓冲上限、硬件解码)与弹幕服务来源的查看与修改。
///
/// 读写统一走 [PlayerSettingsStore];更改即时持久化,对新起播生效。
/// 音量不入本页,由播放器控制层维护。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.settingsStore, this.platform});

  /// 测试注入;运行时留空用当前平台。
  final PlayerSettingsStore? settingsStore;
  final TargetPlatform? platform;

  static const diskCacheLimitKey = Key('settings-disk-cache-limit');
  static const hardwareDecodingKey = Key('settings-hardware-decoding');
  static const decoderBackendKey = Key('settings-decoder-backend');
  static const danmakuServerFieldKey = Key('settings-danmaku-server');
  static const danmakuAppIdFieldKey = Key('settings-danmaku-app-id');
  static const danmakuTokenFieldKey = Key('settings-danmaku-token');
  static const restoreDefaultsKey = Key('settings-restore-defaults');
  static const tokenVisibilityKey = Key('settings-token-visibility');
  static const columnKey = Key('settings-column');

  /// 设置正文限宽,避免标签贴左、控件贴窗沿。
  static const double columnMaxWidth = 680;

  /// 播放选项下拉的统一宽度,避免「2.0 GB」和「自动」缩成一串长短不一的胶囊。
  static const double choiceControlWidth = 176;

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
    setState(() => _settings = _mergeSettings(_settings, next));
    _syncDanmakuControllers();
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.write(next);
    } catch (_) {}
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

  /// 弹幕服务保存:与本页既有行一致,携带本页管理的全部字段做整页写。
  ///
  /// 未由本页写入的字段(弹幕显示参数、按剧记忆等)由 store 合并写保留;
  /// 空串显式覆盖旧值即清除(回官方源),弹幕控制器读取时把空串按未配置解析。
  Future<void> _saveDanmakuService(String server, String appId, String token) {
    return _save(
      PlayerSettings(
        volume: _settings.clampedVolume,
        diskCacheLimitMiB: _settings.diskCacheLimitMiB,
        hardwareDecoding:
            _settings.hardwareDecoding ?? HardwareDecodingMode.auto,
        hardwareDecoder:
            _settings.hardwareDecoder ?? HardwareDecoderBackend.auto,
        danmakuServer: server,
        danmakuAppId: appId,
        danmakuToken: token,
      ),
    );
  }

  Future<void> _restoreDefaults() {
    // 与 PlayerRuntimeOptions.defaultSettings 一致的显式默认值,
    // 另以空串清除自定义弹幕服务(合并写下 null 不覆盖旧值)。
    return _save(
      PlayerSettings(
        volume: _settings.clampedVolume,
        diskCacheLimitMiB: PlayerRuntimeDefaults.diskCacheLimitMiB,
        hardwareDecoding: HardwareDecodingMode.auto,
        hardwareDecoder: HardwareDecoderBackend.auto,
        danmakuServer: '',
        danmakuAppId: '',
        danmakuToken: '',
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
            constraints: const BoxConstraints(
              maxWidth: SettingsPage.columnMaxWidth,
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
                  icon: Icons.play_circle_outline_rounded,
                  title: l10n.settingsPlayback,
                  subtitle: l10n.settingsAppliesToNewPlayback,
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
                    _SettingsChoiceRow(
                      label: l10n.settingsDiskCacheLimit,
                      hint: l10n.settingsDiskCacheLimitHint,
                      child: _SettingsDropdown<int>(
                        dropdownKey: SettingsPage.diskCacheLimitKey,
                        value: effectiveLimit,
                        items: [
                          for (final limit in limitChoices)
                            DropdownMenuItem(
                              value: limit,
                              child: Text(l10n.settingsCacheSize(limit / 1024)),
                            ),
                        ],
                        onChanged: _loaded
                            ? (value) {
                                if (value != null) {
                                  _save(
                                    PlayerSettings(
                                      volume: _settings.clampedVolume,
                                      diskCacheLimitMiB: value,
                                      hardwareDecoding: decoding,
                                      hardwareDecoder: backend,
                                      danmakuServer: _settings.danmakuServer,
                                      danmakuAppId: _settings.danmakuAppId,
                                      danmakuToken: _settings.danmakuToken,
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                    ),
                    _SettingsChoiceRow(
                      label: l10n.settingsHardwareDecoding,
                      hint: l10n.settingsHardwareDecodingHint,
                      child: _SettingsDropdown<HardwareDecodingMode>(
                        dropdownKey: SettingsPage.hardwareDecodingKey,
                        value: decoding,
                        items: [
                          DropdownMenuItem(
                            value: HardwareDecodingMode.auto,
                            child: Text(l10n.settingsHardwareDecodingAuto),
                          ),
                          DropdownMenuItem(
                            value: HardwareDecodingMode.on,
                            child: Text(l10n.settingsHardwareDecodingOn),
                          ),
                          DropdownMenuItem(
                            value: HardwareDecodingMode.off,
                            child: Text(l10n.settingsHardwareDecodingOff),
                          ),
                        ],
                        onChanged: _loaded
                            ? (value) {
                                if (value != null) {
                                  _save(
                                    PlayerSettings(
                                      volume: _settings.clampedVolume,
                                      diskCacheLimitMiB:
                                          _settings.diskCacheLimitMiB,
                                      hardwareDecoding: value,
                                      hardwareDecoder: backend,
                                      danmakuServer: _settings.danmakuServer,
                                      danmakuAppId: _settings.danmakuAppId,
                                      danmakuToken: _settings.danmakuToken,
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                    ),
                    _SettingsChoiceRow(
                      label: l10n.settingsDecoderBackend,
                      hint: l10n.settingsDecoderBackendHint,
                      child: _SettingsDropdown<HardwareDecoderBackend>(
                        dropdownKey: SettingsPage.decoderBackendKey,
                        value: backends.contains(backend)
                            ? backend
                            : HardwareDecoderBackend.auto,
                        items: [
                          for (final value in backends)
                            DropdownMenuItem(
                              value: value,
                              child: Text(_backendLabel(l10n, value)),
                            ),
                        ],
                        onChanged: _loaded && backends.length > 1
                            ? (value) {
                                if (value != null) {
                                  _save(
                                    PlayerSettings(
                                      volume: _settings.clampedVolume,
                                      diskCacheLimitMiB:
                                          _settings.diskCacheLimitMiB,
                                      hardwareDecoding: decoding,
                                      hardwareDecoder: value,
                                      danmakuServer: _settings.danmakuServer,
                                      danmakuAppId: _settings.danmakuAppId,
                                      danmakuToken: _settings.danmakuToken,
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _SettingsSection(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: l10n.danmakuSettings,
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
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _SettingsSection(
                  icon: Icons.subtitles_outlined,
                  title: l10n.settingsDanmakuService,
                  subtitle: l10n.settingsDanmakuServiceHint,
                  children: [
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
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Center(
                      child: Icon(icon, size: 20, color: scheme.onSurface),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(child: trailing!),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.8),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsChoiceRow extends StatelessWidget {
  const _SettingsChoiceRow({
    required this.label,
    required this.hint,
    required this.child,
  });

  final String label;
  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          SizedBox(width: SettingsPage.choiceControlWidth, child: child),
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

class _SettingsDropdown<T> extends StatelessWidget {
  const _SettingsDropdown({
    required this.dropdownKey,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final Key dropdownKey;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.inputDecorationTheme.fillColor ?? scheme.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            key: dropdownKey,
            value: value,
            isExpanded: true,
            borderRadius: BorderRadius.circular(AppRadii.md),
            alignment: AlignmentDirectional.centerStart,
            icon: Icon(
              Icons.expand_more_rounded,
              color: scheme.onSurfaceVariant,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
            ),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}
