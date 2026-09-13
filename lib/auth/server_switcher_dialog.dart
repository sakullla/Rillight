import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/emby_mark.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
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
  });

  final List<SavedServer> servers;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;
  final VoidCallback onAddServer;
  final VoidCallback onLogout;

  static const searchField = Key('server-switcher-search');

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
  });

  final SavedServer server;
  final String? activeServerId;
  final String? activeLineId;
  final void Function(String serverId, String lineId) onSelect;

  @override
  Widget build(BuildContext context) {
    final selectedServer = server.id == activeServerId;
    final l10n = AppLocalizations.of(context);
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
        trailing: selectedServer
            ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
            : null,
        onTap: () => onSelect(server.id, line.id),
      );
    }
    return ExpansionTile(
      leading: const EmbyMark(size: 28),
      initiallyExpanded: selectedServer,
      title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(l10n.lineCount(server.lines.length)),
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
}
