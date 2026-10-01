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
import 'package:rillight/auth/library_counts_panel.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
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

  Future<void> _lines() async {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: auth,
        builder: (sheetContext, _) {
          final sheetL10n = AppLocalizations.of(sheetContext);
          return FractionallySizedBox(
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
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${server.name} · ${server.username}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          key: PhoneMinePage.serverDeleteKey(server.id),
                          tooltip: sheetL10n.deleteServer,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => unawaited(
                            _confirmDeleteServer(sheetContext, auth, server),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final line in server.lines)
                    _lineOption(auth, sheetL10n, server, line),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: PhoneMinePage.lineAddKey(server.id),
                      onPressed: () => unawaited(_addLine(auth, server)),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(sheetL10n.addLine),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// 先确认再删除;取消不改动任何内容。删除当前服务器时回到登录页。
  Future<void> _confirmDeleteServer(
    BuildContext sheetContext,
    AuthController auth,
    SavedServer server,
  ) async {
    final l10n = AppLocalizations.of(sheetContext);
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.deleteServer),
          content: Text(l10n.deleteServerConfirmMessage(server.name)),
          actions: [
            TextButton(
              key: PhoneMinePage.serverDeleteCancelKey,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              key: PhoneMinePage.serverDeleteConfirmKey,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.deleteServerConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    final wasCurrent = auth.session?.server.id == server.id;
    await auth.deleteServer(server.id);
    if (!mounted) {
      return;
    }
    // 删除当前服务器后路由已回登录页,收起底部面板避免盖住登录表单。
    if (wasCurrent) {
      Navigator.of(context).pop();
    }
  }

  Widget _lineOption(
    AuthController auth,
    AppLocalizations l10n,
    SavedServer server,
    ServerLine line,
  ) {
    final serverId = server.id;
    final selected =
        auth.session?.server.id == serverId &&
        auth.session?.server.activeLine?.id == line.id;
    return ListTile(
      key: PhoneMinePage.lineOptionKey(line.id),
      minTileHeight: AppSpacing.huge,
      contentPadding: EdgeInsets.zero,
      title: Text(line.hostLabel),
      selected: selected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: PhoneMinePage.lineEditKey(server.id, line.id),
            tooltip: l10n.editLine,
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: () => unawaited(_editLine(auth, server, line)),
          ),
          IconButton(
            key: PhoneMinePage.lineDeleteKey(server.id, line.id),
            tooltip: l10n.deleteLine,
            icon: const Icon(Icons.link_off, size: 20),
            onPressed: server.lines.length > 1
                ? () => unawaited(_deleteLine(auth, server, line))
                : null,
          ),
          if (selected) const Icon(Icons.check),
        ],
      ),
      onTap: () {
        Navigator.pop(context);
        unawaited(_switchLine(serverId, line.id));
      },
    );
  }

  /// 添加线路:只录地址,不改变当前线路,面板内列表即时刷新。
  Future<void> _addLine(AuthController auth, SavedServer server) async {
    final address = await showLineAddressDialog(context);
    if (address == null || !mounted) {
      return;
    }
    await auth.addLine(server.id, address);
  }

  /// 修改线路地址:仅地址变化,无 UA 输入项;改的是当前线路时,
  /// 之后浏览与播放走新地址并刷新目录。
  Future<void> _editLine(
    AuthController auth,
    SavedServer server,
    ServerLine line,
  ) async {
    final address = await showLineAddressDialog(
      context,
      initialAddress: line.address,
    );
    if (address == null || !mounted) {
      return;
    }
    final wasActive =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    final changed = await auth.updateLineAddress(server.id, line.id, address);
    if (!changed || !mounted) {
      return;
    }
    if (wasActive) {
      await _reloadCatalog();
    }
  }

  /// 删除线路:只剩一条时不执行(按钮已不可用,控制器同样兜底);
  /// 删除当前线路后客户端挂到剩余线路并刷新目录。
  Future<void> _deleteLine(
    AuthController auth,
    SavedServer server,
    ServerLine line,
  ) async {
    final wasActive =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    await auth.deleteLine(server.id, line.id);
    if (!mounted || !wasActive) {
      return;
    }
    await _reloadCatalog();
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
            title: l10n.librarySize,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: LibraryCountsPanel(
                  counts: auth.libraryCounts,
                  loading: auth.libraryCountsLoading,
                  failure: auth.libraryCountsFailure,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          _group(
            context,
            title: l10n.settings,
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
