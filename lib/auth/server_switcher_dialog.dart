import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/emby_mark.dart';
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
    required this.onLogout,
    required this.onDelete,
    required this.onChangePassword,
    required this.onAddLine,
    required this.onEditLine,
    required this.onDeleteLine,
  });

  final List<SavedServer> servers;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;
  final VoidCallback onAddServer;
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
    final scheme = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final filtered = _filtered;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.xxl,
      ),
      // 不透明 surface 底色:面板与背景海报/简介/播放控件不同层,
      // 浅色与深色下服务器名/地址/搜索/添加/退出都清晰可读(R12)。
      child: Material(
        key: ServerSwitcherDialog.panelKey,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: scheme.outlineVariant),
        ),
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
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // 少量服务器一眼可见,不再摆一个空搜索框;多了才提供筛选。
                if (_searchable) ...[
                  TextField(
                    key: ServerSwitcherDialog.searchField,
                    controller: _query,
                    autofocus: widget.servers.length > 8,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: l10n.searchServers,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                // 列表按内容收缩,服务器少时面板不留大片空白。
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
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.xs),
                _ActionTile(
                  key: SessionActions.addServerKey,
                  icon: Icons.add_rounded,
                  label: l10n.addServer,
                  onTap: widget.onAddServer,
                ),
                _ActionTile(
                  key: ServerSwitcherDialog.changePasswordKey,
                  icon: Icons.password_outlined,
                  label: l10n.changePassword,
                  onTap: widget.onChangePassword,
                ),
                _ActionTile(
                  icon: Icons.logout_rounded,
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
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      iconColor: color,
      textColor: color,
      leading: Icon(icon, size: 20),
      minLeadingWidth: 24,
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
              Icons.check_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
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
    final scheme = Theme.of(context).colorScheme;
    final deleteServerButton = IconButton(
      key: ServerSwitcherDialog.deleteKey(server.id),
      tooltip: l10n.deleteServer,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.delete_outline, size: 20),
      onPressed: () => _confirmDelete(context, l10n),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.md),
    );
    final selectedFill = scheme.primary.withValues(alpha: 0.10);
    final active = server.activeLine;
    if (active != null && server.lines.length <= 1) {
      // 单线路服务器:点击条目直接切换;行内提供添加与改址入口。
      // 删除线路在只剩一条时不提供。
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
        child: _RevealActions(
          child: ListTile(
            shape: shape,
            selected: selectedServer,
            selectedTileColor: selectedFill,
            selectedColor: scheme.onSurface,
            contentPadding: const EdgeInsets.only(
              left: AppSpacing.sm,
              right: AppSpacing.xs,
            ),
            leading: const EmbyMark(size: 28),
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
                      IconButton(
                        key: ServerSwitcherDialog.addLineKey(server.id),
                        tooltip: l10n.addLine,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add_link_rounded, size: 20),
                        onPressed: () => onAddLine(server.id),
                      ),
                      IconButton(
                        key: ServerSwitcherDialog.editLineKey(
                          server.id,
                          active.id,
                        ),
                        tooltip: l10n.editLine,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
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
      child: ExpansionTile(
        shape: shape,
        collapsedShape: shape,
        backgroundColor: selectedServer ? selectedFill : null,
        collapsedBackgroundColor: selectedServer ? selectedFill : null,
        tilePadding: const EdgeInsets.only(
          left: AppSpacing.sm,
          right: AppSpacing.xs,
        ),
        leading: const EmbyMark(size: 28),
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
          ListTile(
            key: ServerSwitcherDialog.addLineKey(server.id),
            contentPadding: const EdgeInsets.only(
              left: AppSpacing.xxxl,
              right: AppSpacing.md,
            ),
            leading: const Icon(Icons.add, size: 20),
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
      child: ListTile(
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
                  IconButton(
                    key: ServerSwitcherDialog.editLineKey(server.id, line.id),
                    tooltip: l10n.editLine,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => onEditLine(server.id, line),
                  ),
                  IconButton(
                    key: ServerSwitcherDialog.deleteLineKey(server.id, line.id),
                    tooltip: l10n.deleteLine,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.link_off, size: 20),
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
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.deleteServer),
          content: Text(l10n.deleteServerConfirmMessage(server.name)),
          actions: [
            TextButton(
              key: ServerSwitcherDialog.deleteCancelKey,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              key: ServerSwitcherDialog.deleteConfirmKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onDelete(server.id);
              },
              child: Text(l10n.deleteServerConfirm),
            ),
          ],
        );
      },
    );
  }
}
