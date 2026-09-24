import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

/// 手机「我的」：当前身份、线路、倍速和弹幕来源。
class PhoneMinePage extends StatefulWidget {
  const PhoneMinePage({super.key});

  static const userKey = Key('phone-mine-user');
  static const serverKey = Key('phone-mine-server');
  static const currentLineKey = Key('phone-mine-current-line');
  static const lineKey = Key('phone-mine-line');
  static const failureKey = Key('phone-mine-line-failure');
  static const danmakuServerKey = Key('phone-mine-danmaku-server');
  static const danmakuAppIdKey = Key('phone-mine-danmaku-app-id');
  static const danmakuTokenKey = Key('phone-mine-danmaku-token');
  static const tokenVisibilityKey = Key('phone-mine-token-visibility');
  static const floatingNavKey = Key('phone-nav-floating');

  static const playbackRates = <double>[0.5, 1.0, 1.25, 1.5, 2.0];

  static Key lineOptionKey(String lineId) => Key('phone-mine-line-$lineId');

  static Key rateKey(double rate) => Key('phone-mine-rate-$rate');

  static Key cacheLimitKey(int limitMiB) =>
      Key('phone-mine-cache-limit-$limitMiB');

  @override
  State<PhoneMinePage> createState() => _PhoneMinePageState();
}

class _PhoneMinePageState extends State<PhoneMinePage> {
  final _danmakuServer = TextEditingController();
  final _danmakuAppId = TextEditingController();
  final _danmakuToken = TextEditingController();
  final _danmakuServerFocus = FocusNode();
  final _danmakuAppIdFocus = FocusNode();
  final _danmakuTokenFocus = FocusNode();

  PlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  PhoneNavStyleController? _localNav;
  double _rate = 1;
  bool _loaded = false;
  bool _tokenVisible = false;

  @override
  void initState() {
    super.initState();
    _danmakuServerFocus.addListener(_onDanmakuServerFocus);
    _danmakuAppIdFocus.addListener(_onDanmakuAppIdFocus);
    _danmakuTokenFocus.addListener(_onDanmakuTokenFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    _loaded = true;
    unawaited(_load());
    if (PhoneNavStyle.maybeOf(context) == null) {
      final local = PhoneNavStyleController();
      _localNav = local;
      unawaited(local.load());
    }
  }

  @override
  void dispose() {
    _danmakuServerFocus.removeListener(_onDanmakuServerFocus);
    _danmakuAppIdFocus.removeListener(_onDanmakuAppIdFocus);
    _danmakuTokenFocus.removeListener(_onDanmakuTokenFocus);
    _danmakuServerFocus.dispose();
    _danmakuAppIdFocus.dispose();
    _danmakuTokenFocus.dispose();
    _danmakuServer.dispose();
    _danmakuAppId.dispose();
    _danmakuToken.dispose();
    _localNav?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final injected = PlayerScope.of(context).settingsStore;
    final inner = injected ?? await openPlayerSettingsStore();
    final store = _MergingPlayerSettingsStore(inner);
    final settings = await store.read();
    if (!mounted) {
      return;
    }
    setState(() {
      _store = store;
      _settings = settings;
      _rate = settings.effectivePlaybackRate;
    });
    _syncDanmakuFields();
  }

  void _onDanmakuServerFocus() {
    if (!_danmakuServerFocus.hasFocus) {
      unawaited(_commitDanmaku());
    }
  }

  void _onDanmakuAppIdFocus() {
    if (!_danmakuAppIdFocus.hasFocus) {
      unawaited(_commitDanmaku());
    }
  }

  void _onDanmakuTokenFocus() {
    if (!_danmakuTokenFocus.hasFocus) {
      unawaited(_commitDanmaku());
    }
  }

  void _syncDanmakuFields() {
    if (!_danmakuServerFocus.hasFocus) {
      final server = _settings.danmakuServer ?? '';
      if (_danmakuServer.text != server) {
        _danmakuServer.text = server;
      }
    }
    if (!_danmakuAppIdFocus.hasFocus) {
      final appId = _settings.danmakuAppId ?? '';
      if (_danmakuAppId.text != appId) {
        _danmakuAppId.text = appId;
      }
    }
    if (!_danmakuTokenFocus.hasFocus) {
      final token = _settings.danmakuToken ?? '';
      if (_danmakuToken.text != token) {
        _danmakuToken.text = token;
      }
    }
  }

  /// 空地址写入空串，读取时表示继续用官方源。
  Future<void> _commitDanmaku() async {
    final store = _store;
    if (store == null) {
      return;
    }
    final server = _danmakuServer.text.trim();
    final appId = _danmakuAppId.text.trim();
    final token = _danmakuToken.text.trim();
    if (server == (_settings.danmakuServer ?? '') &&
        appId == (_settings.danmakuAppId ?? '') &&
        token == (_settings.danmakuToken ?? '')) {
      return;
    }
    try {
      await store.write(
        PlayerSettings(
          danmakuServer: server,
          danmakuAppId: appId,
          danmakuToken: token,
        ),
      );
      _settings = await store.read();
    } catch (_) {}
  }

  Future<void> _saveRate(double rate) async {
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.write(PlayerSettings(playbackRate: rate));
      if (!mounted) {
        return;
      }
      setState(() => _rate = rate);
    } catch (_) {}
  }

  Future<void> _saveCacheLimit(int limitMiB) async {
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.write(PlayerSettings(diskCacheLimitMiB: limitMiB));
      final settings = await store.read();
      if (!mounted) {
        return;
      }
      setState(() => _settings = settings);
    } catch (_) {}
  }

  Future<void> _switchLine(String serverId, String lineId) async {
    final auth = AuthScope.of(context);
    await auth.switchTo(serverId, lineId: lineId);
    if (!mounted || !auth.isLoggedIn) {
      return;
    }
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null) {
      return;
    }
    await catalog.reload();
  }

  Future<void> _lines() async {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .65,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              l10n.mobileLine,
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            for (final server in auth.savedServers) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text('${server.name} · ${server.username}'),
              ),
              for (final line in server.lines)
                _lineOption(auth, server.id, line),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lineOption(AuthController auth, String serverId, ServerLine line) {
    final selected =
        auth.session?.server.id == serverId &&
        auth.session?.server.activeLine?.id == line.id;
    return ListTile(
      key: PhoneMinePage.lineOptionKey(line.id),
      minTileHeight: AppSpacing.huge,
      contentPadding: EdgeInsets.zero,
      title: Text(line.hostLabel),
      selected: selected,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () {
        Navigator.pop(context);
        unawaited(_switchLine(serverId, line.id));
      },
    );
  }

  Widget _group(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xs),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }

  Widget _floatingNav(BuildContext context, AppLocalizations l10n) {
    final shared = PhoneNavStyle.maybeOf(context);
    final nav = shared ?? _localNav;
    if (nav == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: nav,
      builder: (context, _) {
        return _group(
          context,
          title: l10n.phoneAppearanceGroup,
          children: [
            SwitchListTile(
              key: PhoneMinePage.floatingNavKey,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.phoneFloatingNav),
              subtitle: Text(l10n.phoneFloatingNavHint),
              value: nav.floating,
              onChanged: (value) => unawaited(nav.setFloating(value)),
            ),
          ],
        );
      },
    );
  }

  Widget _fieldLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Align(alignment: Alignment.centerLeft, child: Text(label)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final session = auth.session;
    final lineLabel = session?.server.activeLine?.hostLabel ?? '';
    final failure = auth.failure;
    final cacheLimit =
        _settings.diskCacheLimitMiB ?? PlayerRuntimeDefaults.diskCacheLimitMiB;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mobileMine)),
      body: ListView(
        key: const PageStorageKey('mobile-mine-scroll'),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person,
                  size: 32,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session?.username ?? '',
                      key: PhoneMinePage.userKey,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      session?.server.name ?? '',
                      key: PhoneMinePage.serverKey,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (lineLabel.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        lineLabel,
                        key: PhoneMinePage.currentLineKey,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (failure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              embyFailureMessage(l10n, failure),
              key: PhoneMinePage.failureKey,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _group(
            context,
            title: l10n.mobileAccountServerGroup,
            children: [
              ListTile(
                key: PhoneMinePage.lineKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.mobileLine),
                onTap: _lines,
              ),
              ListTile(
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add),
                title: Text(l10n.mobileAddServer),
                onTap: () => context.push('${AppRoutes.connect}?add=1'),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppSpacing.huge),
                ),
                onPressed: auth.isBusy ? null : auth.logout,
                child: Text(l10n.logout),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _floatingNav(context, l10n),
          const SizedBox(height: AppSpacing.lg),
          _group(
            context,
            title: l10n.mobilePlaybackGroup,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.mobileSpeed,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                l10n.settingsAppliesToNewPlayback,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final rate in PhoneMinePage.playbackRates)
                    ChoiceChip(
                      key: PhoneMinePage.rateKey(rate),
                      label: Text('${rate}x'),
                      selected: _rate == rate,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: _store == null
                          ? null
                          : (_) => unawaited(_saveRate(rate)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.settingsDanmakuService,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                l10n.settingsDanmakuServiceHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              _fieldLabel(context, l10n.settingsDanmakuServer),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                key: PhoneMinePage.danmakuServerKey,
                controller: _danmakuServer,
                focusNode: _danmakuServerFocus,
                enabled: _store != null,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => unawaited(_commitDanmaku()),
                decoration: InputDecoration(
                  hintText: l10n.settingsDanmakuServerHint,
                ),
              ),
              _fieldLabel(context, l10n.settingsDanmakuAppId),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                key: PhoneMinePage.danmakuAppIdKey,
                controller: _danmakuAppId,
                focusNode: _danmakuAppIdFocus,
                enabled: _store != null,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => unawaited(_commitDanmaku()),
                decoration: InputDecoration(
                  hintText: l10n.settingsDanmakuAppIdHint,
                ),
              ),
              _fieldLabel(context, l10n.settingsDanmakuToken),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                key: PhoneMinePage.danmakuTokenKey,
                controller: _danmakuToken,
                focusNode: _danmakuTokenFocus,
                enabled: _store != null,
                obscureText: !_tokenVisible,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_commitDanmaku()),
                decoration: InputDecoration(
                  hintText: l10n.settingsDanmakuTokenHint,
                  suffixIcon: IconButton(
                    key: PhoneMinePage.tokenVisibilityKey,
                    tooltip: _tokenVisible
                        ? l10n.settingsHideToken
                        : l10n.settingsShowToken,
                    onPressed: () =>
                        setState(() => _tokenVisible = !_tokenVisible),
                    icon: Icon(
                      _tokenVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _group(
            context,
            title: l10n.mobileCacheGroup,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.settingsDiskCacheLimit,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                l10n.settingsDiskCacheLimitHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final limit in SettingsPage.diskCacheLimitChoices)
                    ChoiceChip(
                      key: PhoneMinePage.cacheLimitKey(limit),
                      label: Text(l10n.settingsCacheSize(limit / 1024)),
                      selected: cacheLimit == limit,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: _store == null
                          ? null
                          : (_) => unawaited(_saveCacheLimit(limit)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _group(
            context,
            title: l10n.mobileAboutGroup,
            children: [
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.appName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    l10n.mobileVersion(kAppVersion),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ],
      ),
    );
  }
}

/// 注入的内存存储会整份替换。先合并再写，只改倍速或弹幕地址时保留其它字段。
class _MergingPlayerSettingsStore implements PlayerSettingsStore {
  _MergingPlayerSettingsStore(this._inner);

  final PlayerSettingsStore _inner;

  @override
  Future<PlayerSettings> read() => _inner.read();

  @override
  Future<void> write(PlayerSettings settings) async {
    final current = await _inner.read();
    final merged = Map<String, dynamic>.from(current.toJson());
    for (final entry in settings.toJson().entries) {
      final existing = merged[entry.key];
      merged[entry.key] = existing is Map && entry.value is Map
          ? <String, dynamic>{
              ...Map<String, dynamic>.from(existing),
              ...Map<String, dynamic>.from(entry.value as Map),
            }
          : entry.value;
    }
    await _inner.write(PlayerSettings.fromJson(merged));
  }
}
