import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

/// 设置页:播放器运行时选项(磁盘缓冲上限、硬件解码)的查看与修改。
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
  static const restoreDefaultsKey = Key('settings-restore-defaults');

  /// 可选的磁盘缓冲上限档位(MiB)。
  static const diskCacheLimitChoices = <int>[512, 1024, 2048, 4096, 8192];

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  PlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
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
    } catch (_) {
      if (mounted) {
        setState(() => _loaded = true);
      }
    }
  }

  Future<void> _save(PlayerSettings next) async {
    setState(() => _settings = next);
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.write(next);
    } catch (_) {}
  }

  TargetPlatform get _platform => widget.platform ?? defaultTargetPlatform;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
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

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.settings,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            OutlinedButton(
              key: SettingsPage.restoreDefaultsKey,
              onPressed: _loaded
                  ? () => _save(
                      PlayerRuntimeOptions.defaultSettings(
                        volume: _settings.clampedVolume,
                      ),
                    )
                  : null,
              child: Text(l10n.settingsRestoreDefaults),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.settingsPlayback,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _SettingsRow(
          label: l10n.settingsDiskCacheLimit,
          child: DropdownButton<int>(
            key: SettingsPage.diskCacheLimitKey,
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
                        ),
                      );
                    }
                  }
                : null,
          ),
        ),
        _SettingsRow(
          label: l10n.settingsHardwareDecoding,
          child: DropdownButton<HardwareDecodingMode>(
            key: SettingsPage.hardwareDecodingKey,
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
                          diskCacheLimitMiB: _settings.diskCacheLimitMiB,
                          hardwareDecoding: value,
                          hardwareDecoder: backend,
                        ),
                      );
                    }
                  }
                : null,
          ),
        ),
        _SettingsRow(
          label: l10n.settingsDecoderBackend,
          child: DropdownButton<HardwareDecoderBackend>(
            key: SettingsPage.decoderBackendKey,
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
                          diskCacheLimitMiB: _settings.diskCacheLimitMiB,
                          hardwareDecoding: decoding,
                          hardwareDecoder: value,
                        ),
                      );
                    }
                  }
                : null,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.settingsAppliesToNewPlayback,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          child,
        ],
      ),
    );
  }
}
