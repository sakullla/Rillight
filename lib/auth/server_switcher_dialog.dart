import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/emby_mark.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/auth/library_counts_panel.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';

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
    this.libraryCounts,
    this.libraryCountsLoading = false,
    this.libraryCountsFailure,
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

  /// 当前服务器的库规模;三者全空时不展示该块。
  final LibraryCounts? libraryCounts;
  final bool libraryCountsLoading;
  final EmbyException? libraryCountsFailure;

  static const searchField = Key('server-switcher-search');
  static const deleteConfirmKey = Key('server-delete-confirm');
  static const deleteCancelKey = Key('server-delete-cancel');
  static const changePasswordKey = Key('server-change-password');

  static Key deleteKey(String serverId) => Key('server-delete-$serverId');

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
    final filtered = _filtered;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.xxl,
      ),
      child: LiquidGlass(
        kind: LiquidGlassKind.panel,
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
                if (widget.libraryCounts != null ||
                    widget.libraryCountsLoading ||
                    widget.libraryCountsFailure != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  LibraryCountsPanel(
                    counts: widget.libraryCounts,
                    loading: widget.libraryCountsLoading,
                    failure: widget.libraryCountsFailure,
                  ),
                ],
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
  });

  final SavedServer server;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;
  final void Function(String serverId) onDelete;

  @override
  Widget build(BuildContext context) {
    final selectedServer = server.id == activeServerId;
    final l10n = AppLocalizations.of(context);
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ServerSwitcherDialog.deleteKey(server.id),
          tooltip: l10n.deleteServer,
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () => _confirmDelete(context, l10n),
        ),
        if (selectedServer)
          Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
      ],
    );
    if (server.lines.length <= 1) {
      final line = server.activeLine ?? server.lines.first;
      return ListTile(
        leading: const EmbyMark(size: 28),
        title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          line.hostLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: trailing,
        onTap: () => onSelect(server.id, line.id),
      );
    }
    return ExpansionTile(
      leading: const EmbyMark(size: 28),
      initiallyExpanded: selectedServer,
      title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(l10n.lineCount(server.lines.length)),
      trailing: trailing,
      children: [
        for (final line in server.lines)
          ListTile(
            contentPadding: const EdgeInsets.only(
              left: AppSpacing.xxxl,
              right: AppSpacing.md,
            ),
            title: Text(
              line.hostLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: selectedServer && line.id == activeLineId
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () => onSelect(server.id, line.id),
          ),
      ],
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
