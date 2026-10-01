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
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.switchServer,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
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
                Expanded(
                  child: filtered.isEmpty
                      ? Center(child: Text(l10n.noSavedServers))
                      : ListView.builder(
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
                const Divider(height: 1),
                ListTile(
                  key: SessionActions.addServerKey,
                  leading: const Icon(Icons.add),
                  title: Text(l10n.addServer),
                  onTap: widget.onAddServer,
                ),
                ListTile(
                  key: ServerSwitcherDialog.changePasswordKey,
                  leading: const Icon(Icons.password_outlined),
                  title: Text(l10n.changePassword),
                  onTap: widget.onChangePassword,
                ),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: Text(l10n.logout),
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
      icon: const Icon(Icons.delete_outline, size: 20),
      onPressed: () => _confirmDelete(context, l10n),
    );
    final active = server.activeLine;
    if (active != null && server.lines.length <= 1) {
      // 单线路服务器:点击条目直接切换;行内提供添加与改址入口。
      // 删除线路在只剩一条时不提供。
      return ListTile(
        leading: const EmbyMark(size: 28),
        title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          active.hostLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: ServerSwitcherDialog.addLineKey(server.id),
              tooltip: l10n.addLine,
              icon: const Icon(Icons.add, size: 20),
              onPressed: () => onAddLine(server.id),
            ),
            IconButton(
              key: ServerSwitcherDialog.editLineKey(server.id, active.id),
              tooltip: l10n.editLine,
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => onEditLine(server.id, active),
            ),
            deleteServerButton,
            if (selectedServer) Icon(Icons.check, color: scheme.primary),
          ],
        ),
        onTap: () => onSelect(server.id, active.id),
      );
    }
    return ExpansionTile(
      leading: const EmbyMark(size: 28),
      initiallyExpanded: selectedServer,
      title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          deleteServerButton,
          if (selectedServer)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
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
    );
  }

  /// 一条线路:点击切换;行内可改地址、删线路(只剩一条时删除不可用)。
  Widget _lineTile(
    BuildContext context,
    ServerLine line, {
    required bool selectedServer,
  }) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: ServerSwitcherDialog.lineOptionKey(server.id, line.id),
      contentPadding: const EdgeInsets.only(
        left: AppSpacing.xxxl,
        right: AppSpacing.md,
      ),
      title: Text(line.hostLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ServerSwitcherDialog.editLineKey(server.id, line.id),
            tooltip: l10n.editLine,
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: () => onEditLine(server.id, line),
          ),
          IconButton(
            key: ServerSwitcherDialog.deleteLineKey(server.id, line.id),
            tooltip: l10n.deleteLine,
            icon: const Icon(Icons.link_off, size: 20),
            onPressed: server.lines.length > 1
                ? () => onDeleteLine(server.id, line)
                : null,
          ),
          if (selectedServer && line.id == activeLineId)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
        ],
      ),
      onTap: () => onSelect(server.id, line.id),
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
