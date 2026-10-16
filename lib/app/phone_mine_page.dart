import 'updates/update_check.dart';
import '../auth/provider_connect_dialog.dart';
import '../media_server/capabilities.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/app/ui/app_icons.dart';

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

  void _openSettings() {
    final l10n = AppLocalizations.of(context);
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (context) => CupertinoPageScaffold(
          navigationBar: PhoneTopBar(title: Text(l10n.settings)),
          child: SettingsPage(
            showTitle: false,
            settingsStore: PlayerScope.of(context).settingsStore,
          ),
        ),
      ),
    );
  }

  Future<void> _openPrivate() async {
    if (await SessionActions.ensurePrivateAccess(context) && mounted) {
      context.push('/private');
    }
  }

  Widget _group(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.xs),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  AppDivider(
                    height: 1,
                    indent: 56,
                    color: scheme.onSurface.withValues(alpha: .06),
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final session = auth.session;
    final lineLabel = session?.server.activeLine?.hostLabel ?? '';
    final failure = auth.failure;
    final lineSwitchFailure = auth.lineSwitchFailure;
    final name = session?.username ?? '';
    final initial = name.trim().isEmpty
        ? null
        : String.fromCharCode(name.trim().runes.first).toUpperCase();
    final canChangePassword =
        auth.client.serviceType == MediaServerType.plex ||
        auth.client.capabilities[ServiceCapability.changePassword].isAvailable;
    return CupertinoPageScaffold(
      navigationBar: PhoneTopBar(title: Text(l10n.mobileMine)),
      child: ListView(
        key: const PageStorageKey('mobile-mine-scroll'),
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // 身份卡：头像、用户名、服务器与线路。整张卡点开服务器管理。
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(scheme.surfaceContainerHigh, scheme.primary, .22)!,
                  scheme.surfaceContainer,
                ],
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: AppSurfaceAction(
              onTap: _lines,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primary,
                            Color.lerp(
                              scheme.primary,
                              const Color(0xFF7A3E00),
                              .55,
                            )!,
                          ],
                        ),
                      ),
                      child: initial == null
                          ? Icon(
                              AppIcons.person,
                              fill: AppIcons.filled,
                              size: 30,
                              color: scheme.onPrimary,
                            )
                          : Text(
                              initial,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            key: PhoneMinePage.userKey,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            session == null
                                ? ''
                                : '${session.server.serviceType.name} · ${session.server.displayName}',
                            key: PhoneMinePage.serverKey,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (lineLabel.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  AppIcons.lan,
                                  fill: AppIcons.filled,
                                  size: 13,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    lineLabel,
                                    key: PhoneMinePage.currentLineKey,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      AppIcons.chevronRight,
                      fill: AppIcons.filled,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (failure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              embyFailureMessage(l10n, failure),
              key: PhoneMinePage.failureKey,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          if (lineSwitchFailure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.lineSwitchFailed(lineSwitchFailure.detail),
              key: PhoneMinePage.lineSwitchFailureKey,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          // 常用入口：两列磁贴，图标落在强调色浅底上。
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = AppSpacing.sm;
              final columns =
                  MediaQuery.textScalerOf(context).scale(14) / 14 > 1.5 ? 1 : 2;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              final tiles = <Widget>[
                _MineTile(
                  key: PhoneMinePage.lineKey,
                  icon: AppIcons.server,
                  label: l10n.phoneServerManagement,
                  onTap: _lines,
                ),
                _MineTile(
                  icon: AppIcons.addCircle,
                  label: l10n.mobileAddServer,
                  onTap: () => context.push('${AppRoutes.connect}?add=1'),
                ),
                _MineTile(
                  key: PhoneMinePage.privateKey,
                  icon: AppIcons.shield,
                  label: l10n.aggregationPrivate,
                  onTap: _openPrivate,
                ),
                _MineTile(
                  key: PhoneMinePage.settingsKey,
                  icon: AppIcons.settings,
                  label: l10n.settings,
                  onTap: _openSettings,
                ),
              ];
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final tile in tiles) SizedBox(width: width, child: tile),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.xl),
          _group(
            context,
            title: l10n.mobileAccountServerGroup,
            children: [
              if (canChangePassword)
                AppListTile(
                  key: PhoneMinePage.changePasswordKey,
                  minTileHeight: 52,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                  leading: const Icon(AppIcons.lock, fill: AppIcons.filled),
                  title: Text(
                    auth.client.serviceType == MediaServerType.plex
                        ? l10n.providerAccountManage
                        : l10n.changePassword,
                  ),
                  trailing: Icon(
                    AppIcons.chevronRight,
                    fill: AppIcons.filled,
                    size: 16,
                    color: scheme.onSurfaceVariant,
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
                minTileHeight: 52,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                ),
                leading: Icon(
                  AppIcons.logout,
                  fill: AppIcons.filled,
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.appName,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      l10n.mobileVersion(kAppVersion),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const UpdateCheck(),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「我的」常用入口磁贴：左侧强调色圆底图标，右侧名称。
class _MineTile extends StatelessWidget {
  const _MineTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      clipBehavior: Clip.antiAlias,
      child: AppSurfaceAction(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .16),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      icon,
                      fill: AppIcons.filled,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
