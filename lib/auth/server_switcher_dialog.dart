import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/login_widgets.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';

/// 可搜索的服务器切换面板,按条目构建,面向上百台服务器。
class ServerSwitcherDialog extends StatefulWidget {
  const ServerSwitcherDialog({
    super.key,
    required this.servers,
    required this.activeServerId,
    required this.activeLineId,
    required this.onSelect,
    required this.onAddServer,
    this.onImportBackup,
    required this.onLogout,
    required this.onDelete,
    required this.onChangePassword,
    required this.onAddLine,
    required this.onEditLine,
    required this.onDeleteLine,
    this.onManage,
    this.canChangePassword = true,
    this.externalAccountManagement = false,
  });

  final bool canChangePassword;
  final bool externalAccountManagement;
  final VoidCallback? onManage;
  final List<SavedServer> servers;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;
  final VoidCallback onAddServer;

  /// 从 Hills/小幻备份导入服务配置;为空时不显示该入口。
  final VoidCallback? onImportBackup;
  final VoidCallback onLogout;

  /// 删除一台已保存服务器;先弹确认框,确认后才回调。
  final void Function(String serverId) onDelete;

  /// 修改当前登录用户的密码。
  final VoidCallback onChangePassword;

  /// 给一台已保存服务器添加线路;只录地址,不改变当前线路。
  final void Function(String serverId) onAddLine;

  /// 修改一条线路的地址;仅地址变化,无 User-Agent 输入项。
  final void Function(String serverId, ServerLine line) onEditLine;

  /// 删除一条线路;只剩一条时按钮不可用,不会回调。
  final void Function(String serverId, ServerLine line) onDeleteLine;

  static const searchField = Key('server-switcher-search');
  static const panelKey = Key('server-switcher-panel');
  static const deleteConfirmKey = Key('server-delete-confirm');
  static const deleteCancelKey = Key('server-delete-cancel');
  static const changePasswordKey = Key('server-change-password');
  static const importBackupKey = Key('server-import-backup');

  static const privateKey = Key('server-switcher-private');

  static Key deleteKey(String serverId) => Key('server-delete-$serverId');

  static Key addLineKey(String serverId) => Key('server-add-line-$serverId');

  static Key editLineKey(String serverId, String lineId) =>
      Key('server-edit-line-$serverId-$lineId');

  static Key deleteLineKey(String serverId, String lineId) =>
      Key('server-delete-line-$serverId-$lineId');

  static Key lineOptionKey(String serverId, String lineId) =>
      Key('server-line-$serverId-$lineId');

  @override
  State<ServerSwitcherDialog> createState() => _ServerSwitcherDialogState();
}

class _ServerSwitcherDialogState extends State<ServerSwitcherDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _searchable =>
      widget.servers.length > 5 || _query.text.trim().isNotEmpty;

  List<SavedServer> get _filtered {
    final needle = _query.text.trim().toLowerCase();
    if (needle.isEmpty) {
      return widget.servers;
    }
    return [
      for (final server in widget.servers)
        if (_matches(server, needle)) server,
    ];
  }

  bool _matches(SavedServer server, String needle) {
    if (server.name.toLowerCase().contains(needle)) {
      return true;
    }
    if (server.baseUrl.toLowerCase().contains(needle)) {
      return true;
    }
    for (final line in server.lines) {
      if (line.address.toLowerCase().contains(needle) ||
          line.hostLabel.toLowerCase().contains(needle)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final filtered = _filtered;
    return AppModalFrame(
      backgroundColor: const Color(0x00000000),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.xxl,
      ),
      child: Container(
        decoration: BoxDecoration(color: scheme.surface),
        key: ServerSwitcherDialog.panelKey,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: AppViewport.fit(440, viewport.width - 64, viewport),
            maxHeight: AppViewport.fit(560, viewport.height * 0.88, viewport),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: Text(
                    l10n.switchServer,
                    style: AppUiTheme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),

                if (_searchable) ...[
                  AppTextField(
                    key: ServerSwitcherDialog.searchField,
                    controller: _query,
                    autofocus: widget.servers.length > 8,
                    onChanged: (_) => setState(() {}),
                    placeholder: l10n.searchServers,
                    prefix: const Icon(CupertinoIcons.search, size: 20),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],

                Flexible(
                  child: filtered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.xl,
                          ),
                          child: Center(child: Text(l10n.noSavedServers)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return _ServerTile(
                              server: filtered[index],
                              activeServerId: widget.activeServerId,
                              activeLineId: widget.activeLineId,
                              onSelect: widget.onSelect,
                              onDelete: widget.onDelete,
                              onAddLine: widget.onAddLine,
                              onEditLine: widget.onEditLine,
                              onDeleteLine: widget.onDeleteLine,
                            );
                          },
                        ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const AppDivider(height: 1),
                const SizedBox(height: AppSpacing.xs),
                _ActionTile(
                  key: SessionActions.addServerKey,
                  icon: CupertinoIcons.plus,
                  label: l10n.addServer,
                  onTap: widget.onAddServer,
                ),
                if (widget.onImportBackup != null)
                  _ActionTile(
                    key: ServerSwitcherDialog.importBackupKey,
                    icon: CupertinoIcons.square_arrow_down,
                    label: l10n.backupImportEntry,
                    onTap: widget.onImportBackup!,
                  ),
                if (widget.onManage != null)
                  _ActionTile(
                    key: const Key('server-manage-providers'),
                    icon: CupertinoIcons.person_crop_circle,
                    label: l10n.sourceManagement,
                    onTap: widget.onManage!,
                  ),
                if (widget.canChangePassword ||
                    widget.externalAccountManagement)
                  _ActionTile(
                    key: ServerSwitcherDialog.changePasswordKey,
                    icon: CupertinoIcons.lock,
                    label: widget.externalAccountManagement
                        ? l10n.providerAccountManage
                        : l10n.changePassword,
                    onTap: widget.onChangePassword,
                  ),
                _ActionTile(
                  icon: CupertinoIcons.square_arrow_right,
                  label: l10n.logout,
                  color: scheme.error,
                  onTap: widget.onLogout,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板底部的账户动作行:紧凑、圆角悬停,退出登录用警示色。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return AppListTile(
      leading: Icon(icon, size: 20),
      title: Text(label),
      onTap: onTap,
    );
  }
}

/// 行尾次要操作:悬停或键盘聚焦到该行时才浮现。
/// 隐去时仍保留占位与命中区域,行布局不跳动。
class _RevealActions extends StatefulWidget {
  const _RevealActions({required this.child});

  final Widget child;

  @override
  State<_RevealActions> createState() => _RevealActionsState();
}

class _RevealActionsState extends State<_RevealActions> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: _RevealScope(visible: visible, child: widget.child),
      ),
    );
  }
}

class _RevealScope extends InheritedWidget {
  const _RevealScope({required this.visible, required super.child});

  final bool visible;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RevealScope>()?.visible ??
      true;

  @override
  bool updateShouldNotify(_RevealScope oldWidget) =>
      oldWidget.visible != visible;
}

class _Revealed extends StatelessWidget {
  const _Revealed({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _RevealScope.of(context) ? 1 : 0,
      duration: AppMotion.durationOf(context, AppMotion.fast),
      child: child,
    );
  }
}

/// 当前项的勾:固定占位,有无勾选的行尾图标都对齐同一条竖线。
class _CheckSlot extends StatelessWidget {
  const _CheckSlot({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      child: checked
          ? Icon(
              CupertinoIcons.check_mark,
              size: 20,
              color: AppUiTheme.of(context).colorScheme.primary,
            )
          : null,
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.activeServerId,
    required this.activeLineId,
    required this.onSelect,
    required this.onDelete,
    required this.onAddLine,
    required this.onEditLine,
    required this.onDeleteLine,
  });

  final SavedServer server;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;
  final void Function(String serverId) onDelete;
  final void Function(String serverId) onAddLine;
  final void Function(String serverId, ServerLine line) onEditLine;
  final void Function(String serverId, ServerLine line) onDeleteLine;

  @override
  Widget build(BuildContext context) {
    final selectedServer = server.id == activeServerId;
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final deleteServerButton = AppIconButton(
      key: ServerSwitcherDialog.deleteKey(server.id),
      tooltip: l10n.deleteServer,
      icon: const Icon(CupertinoIcons.trash, size: 20),
      onPressed: () => _confirmDelete(context, l10n),
    );
    final selectedFill = scheme.primary.withValues(alpha: 0.10);
    final active = server.activeLine;
    if (active != null && server.lines.length <= 1) {
      // 单线路服务器:点击条目直接切换;行内提供添加与改址入口。
      // 删除线路在只剩一条时不提供。
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
        child: _RevealActions(
          child: AppListTile(
            selected: selectedServer,
            contentPadding: const EdgeInsets.only(
              left: AppSpacing.sm,
              right: AppSpacing.xs,
            ),
            leading: ServerTypeMark(type: server.serviceType, size: 28),
            title: Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: selectedServer
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : null,
            ),
            subtitle: Text(
              active.hostLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Revealed(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIconButton(
                        key: ServerSwitcherDialog.addLineKey(server.id),
                        tooltip: l10n.addLine,
                        icon: const Icon(CupertinoIcons.link, size: 20),
                        onPressed: () => onAddLine(server.id),
                      ),
                      AppIconButton(
                        key: ServerSwitcherDialog.editLineKey(
                          server.id,
                          active.id,
                        ),
                        tooltip: l10n.editLine,
                        icon: const Icon(CupertinoIcons.pencil, size: 20),
                        onPressed: () => onEditLine(server.id, active),
                      ),
                      deleteServerButton,
                    ],
                  ),
                ),
                _CheckSlot(checked: selectedServer),
              ],
            ),
            onTap: () => onSelect(server.id, active.id),
          ),
        ),
      );
    }
    return _RevealActions(
      child: AppDisclosure(
        backgroundColor: selectedServer ? selectedFill : null,
        tilePadding: const EdgeInsets.only(
          left: AppSpacing.sm,
          right: AppSpacing.xs,
        ),
        leading: ServerTypeMark(type: server.serviceType, size: 28),
        initiallyExpanded: selectedServer,
        title: Text(
          server.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: selectedServer
              ? const TextStyle(fontWeight: FontWeight.w600)
              : null,
        ),
        subtitle: server.lines.length > 1 || active == null
            ? Text(l10n.lineCount(server.lines.length))
            : Text(
                active.hostLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Revealed(child: deleteServerButton),
            _CheckSlot(checked: selectedServer),
          ],
        ),
        children: [
          for (final line in server.lines)
            _lineTile(context, line, selectedServer: selectedServer),
          AppListTile(
            key: ServerSwitcherDialog.addLineKey(server.id),
            contentPadding: const EdgeInsets.only(
              left: AppSpacing.xxxl,
              right: AppSpacing.md,
            ),
            leading: const Icon(CupertinoIcons.plus, size: 20),
            title: Text(l10n.addLine),
            onTap: () => onAddLine(server.id),
          ),
        ],
      ),
    );
  }

  /// 一条线路:点击切换;行内可改地址、删线路(只剩一条时删除不可用)。
  Widget _lineTile(
    BuildContext context,
    ServerLine line, {
    required bool selectedServer,
  }) {
    final l10n = AppLocalizations.of(context);
    return _RevealActions(
      child: AppListTile(
        key: ServerSwitcherDialog.lineOptionKey(server.id, line.id),
        contentPadding: const EdgeInsets.only(
          left: AppSpacing.xxxl,
          right: AppSpacing.md,
        ),
        title: Text(
          line.hostLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Revealed(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIconButton(
                    key: ServerSwitcherDialog.editLineKey(server.id, line.id),
                    tooltip: l10n.editLine,
                    icon: const Icon(CupertinoIcons.pencil, size: 20),
                    onPressed: () => onEditLine(server.id, line),
                  ),
                  AppIconButton(
                    key: ServerSwitcherDialog.deleteLineKey(server.id, line.id),
                    tooltip: l10n.deleteLine,
                    icon: const Icon(CupertinoIcons.link, size: 20),
                    onPressed: server.lines.length > 1
                        ? () => onDeleteLine(server.id, line)
                        : null,
                  ),
                ],
              ),
            ),
            _CheckSlot(checked: selectedServer && line.id == activeLineId),
          ],
        ),
        onTap: () => onSelect(server.id, line.id),
      ),
    );
  }

  /// 先确认再删除;取消不改动任何内容。
  Future<void> _confirmDelete(BuildContext context, AppLocalizations l10n) {
    return showAppDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppDialog(
          title: Text(l10n.deleteServer),
          content: Text(l10n.deleteServerConfirmMessage(server.name)),
          actions: [
            AppButton(
              key: ServerSwitcherDialog.deleteCancelKey,
              onPressed: () => Navigator.of(dialogContext).pop(),
              variant: AppButtonVariant.plain,
              child: Text(l10n.cancelAction),
            ),
            AppButton(
              key: ServerSwitcherDialog.deleteConfirmKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onDelete(server.id);
              },
              variant: AppButtonVariant.filled,
              child: Text(l10n.deleteServerConfirm),
            ),
          ],
        );
      },
    );
  }
}
