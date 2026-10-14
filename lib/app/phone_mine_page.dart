import '../auth/provider_connect_dialog.dart';
import '../media_server/capabilities.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/session_actions.dart';
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

  static const privateKey = Key('phone-mine-private');
  static const settingsKey = Key('phone-mine-settings');

  static Key rateKey(double rate) => Key('phone-mine-rate-$rate');

  static Key cacheLimitKey(int limitMiB) =>
      Key('phone-mine-cache-limit-$limitMiB');

  @override
  State<PhoneMinePage> createState() => _PhoneMinePageState();
}

class _PhoneMinePageState extends State<PhoneMinePage> {
  Future<void> _lines() =>
      showPhoneServerManagerSheet(context, AuthScope.of(context));

  Widget _group(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: AppUiTheme.of(context).textTheme.titleSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (title.isNotEmpty) const SizedBox(height: AppSpacing.xs),
        Container(
          decoration: BoxDecoration(
            color: AppUiTheme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(color: scheme.outlineVariant),
          ),
          margin: EdgeInsets.zero,
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
    final scheme = AppUiTheme.of(context).colorScheme;
    final session = auth.session;
    final lineLabel = session?.server.activeLine?.hostLabel ?? '';
    final failure = auth.failure;
    final lineSwitchFailure = auth.lineSwitchFailure;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.mobileMine)),
      child: ListView(
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
                Container(
                  width: (28) * 2,
                  height: (28) * 2,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.secondaryContainer,
                  ),
                  child: Icon(
                    CupertinoIcons.person,
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
                        style: AppUiTheme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        session == null
                            ? ''
                            : '${session.server.serviceType.name} · ${session.server.displayName}',
                        key: PhoneMinePage.serverKey,
                        style: AppUiTheme.of(context).textTheme.titleMedium,
                      ),
                      if (lineLabel.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          lineLabel,
                          key: PhoneMinePage.currentLineKey,
                          style: AppUiTheme.of(context).textTheme.bodyMedium
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
              style: AppUiTheme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.error),
            ),
          ],
          if (lineSwitchFailure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.lineSwitchFailed(lineSwitchFailure.detail),
              key: PhoneMinePage.lineSwitchFailureKey,
              style: AppUiTheme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          _group(
            context,
            title: l10n.mobileAccountServerGroup,
            children: [
              AppListTile(
                key: PhoneMinePage.lineKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.cube_box),
                title: Text(l10n.phoneServerManagement),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: _lines,
              ),
              AppListTile(
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.plus),
                title: Text(l10n.mobileAddServer),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => context.push('${AppRoutes.connect}?add=1'),
              ),
              if (auth.client.serviceType == MediaServerType.plex ||
                  auth
                      .client
                      .capabilities[ServiceCapability.changePassword]
                      .isAvailable)
                AppListTile(
                  key: PhoneMinePage.changePasswordKey,
                  minTileHeight: AppSpacing.huge,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(CupertinoIcons.lock),
                  title: Text(
                    auth.client.serviceType == MediaServerType.plex
                        ? l10n.providerAccountManage
                        : l10n.changePassword,
                  ),
                  onTap: auth.client.serviceType == MediaServerType.plex
                      ? () => showProviderAccountSettings(context)
                      : () => showAppDialog<void>(
                          context: context,
                          builder: (dialogContext) =>
                              ChangePasswordDialog(auth: auth),
                        ),
                ),
              AppListTile(
                key: PhoneMinePage.privateKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.lock),
                title: Text(l10n.aggregationPrivate),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () async {
                  if (await SessionActions.ensurePrivateAccess(context) &&
                      context.mounted) {
                    context.push('/private');
                  }
                },
              ),
              AppListTile(
                key: PhoneMinePage.settingsKey,
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.slider_horizontal_3),
                title: Text(l10n.settings),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (context) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                        middle: Text(l10n.settings),
                      ),
                      child: SettingsPage(
                        showTitle: false,
                        settingsStore: PlayerScope.of(context).settingsStore,
                      ),
                    ),
                  ),
                ),
              ),
              AppListTile(
                minTileHeight: AppSpacing.huge,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  CupertinoIcons.square_arrow_right,
                  color: scheme.error,
                ),
                title: Text(l10n.logout, style: TextStyle(color: scheme.error)),
                onTap: auth.isBusy ? null : auth.logout,
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
                      style: AppUiTheme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    l10n.mobileVersion(kAppVersion),
                    style: AppUiTheme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
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
