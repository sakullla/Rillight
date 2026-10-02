import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/player_bindings.dart';

/// 手机「我的」：当前身份、线路、倍速和弹幕来源。
class PhoneMinePage extends StatefulWidget {
  const PhoneMinePage({super.key});

  static const userKey = Key('phone-mine-user');
  static const serverKey = Key('phone-mine-server');
  static const currentLineKey = Key('phone-mine-current-line');
  static const lineKey = Key('phone-mine-line');
  static const failureKey = Key('phone-mine-line-failure');
  static const lineSwitchFailureKey = Key('phone-mine-line-switch-failure');
  static const danmakuServerKey = Key('phone-mine-danmaku-server');
  static const danmakuAppIdKey = Key('phone-mine-danmaku-app-id');
  static const danmakuTokenKey = Key('phone-mine-danmaku-token');
  static const tokenVisibilityKey = Key('phone-mine-token-visibility');
  static const floatingNavKey = Key('phone-nav-floating');

  static const playbackRates = <double>[0.5, 1.0, 1.25, 1.5, 2.0];

  static Key lineOptionKey(String lineId) => Key('phone-mine-line-$lineId');

  static Key lineAddKey(String serverId) =>
      Key('phone-mine-line-add-$serverId');

  static Key lineEditKey(String serverId, String lineId) =>
      Key('phone-mine-line-edit-$serverId-$lineId');

  static Key lineDeleteKey(String serverId, String lineId) =>
      Key('phone-mine-line-delete-$serverId-$lineId');

  static Key serverDeleteKey(String serverId) =>
      Key('phone-mine-server-delete-$serverId');

  static const serverDeleteConfirmKey = Key('phone-mine-server-delete-confirm');

  static const serverDeleteCancelKey = Key('phone-mine-server-delete-cancel');

  static const changePasswordKey = Key('phone-mine-change-password');
  static const settingsKey = Key('phone-mine-settings');

  static Key rateKey(double rate) => Key('phone-mine-rate-$rate');

  static Key cacheLimitKey(int limitMiB) =>
      Key('phone-mine-cache-limit-$limitMiB');

  @override
  State<PhoneMinePage> createState() => _PhoneMinePageState();
}

class _PhoneMinePageState extends State<PhoneMinePage> {
  /// 切换线路:成功后刷新目录。失败时保持当前线路、会话与已加载目录,
  /// 原因经 [AuthController.lineSwitchFailure] 在页面顶部以错误行展示。
  Future<void> _switchLine(String serverId, String lineId) async {
    final auth = AuthScope.of(context);
    await auth.switchTo(serverId, lineId: lineId);
    if (!mounted || !auth.isLoggedIn || auth.lineSwitchFailure != null) {
      return;
    }
    await _reloadCatalog();
  }

  Future<void> _reloadCatalog() async {
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null) {
      return;
    }
    await catalog.reload();
  }

  Future<void> _lines() => showPhoneServerManager(
    context,
    auth: AuthScope.of(context),
    onSelect: _switchLine,
    onCurrentLineChanged: () async {
      if (mounted) await _reloadCatalog();
    },
    onAddServer: () {
      if (mounted) context.push('${AppRoutes.connect}?add=1');
    },
  );

  Widget _group(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (title.isNotEmpty) const SizedBox(height: AppSpacing.xs),
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

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final session = auth.session;
    final lineLabel = session?.server.activeLine?.hostLabel ?? '';
    final failure = auth.failure;
    final lineSwitchFailure = auth.lineSwitchFailure;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mobileMine)),
      body: ListView(
        key: const PageStorageKey('mobile-mine-scroll'),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 32,
                    color: scheme.onSecondaryContainer,
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
                        session?.server.displayName ?? '',
                        key: PhoneMinePage.serverKey,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (lineLabel.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          lineLabel,
                          key: PhoneMinePage.currentLineKey,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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
          if (lineSwitchFailure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.lineSwitchFailed(lineSwitchFailure.detail),
              key: PhoneMinePage.lineSwitchFailureKey,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          _group(
            context,
            title: l10n.mobileAccountServerGroup,
            children: [
              ListTile(
                key: PhoneMinePage.lineKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.phoneServerManagement),
                subtitle: Text(l10n.phoneServerManagementHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: _lines,
              ),
              ListTile(
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add),
                title: Text(l10n.mobileAddServer),
                onTap: () => context.push('${AppRoutes.connect}?add=1'),
              ),
              ListTile(
                key: PhoneMinePage.changePasswordKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.password_outlined),
                title: Text(l10n.changePassword),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => ChangePasswordDialog(auth: auth),
                ),
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
          const SizedBox(height: AppSpacing.xl),
          _group(
            context,
            title: '',
            children: [
              ListTile(
                key: PhoneMinePage.settingsKey,
                leading: const Icon(Icons.tune_rounded),
                title: Text(l10n.settings),
                subtitle: Text(l10n.settingsCategoriesHint),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      appBar: AppBar(title: Text(l10n.settings)),
                      body: SettingsPage(
                        showTitle: false,
                        settingsStore: PlayerScope.of(context).settingsStore,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
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
