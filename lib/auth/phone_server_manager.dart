import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';

Future<void> showPhoneServerManager(
  BuildContext context, {
  required AuthController auth,
  required Future<void> Function(String serverId, String lineId) onSelect,
  required VoidCallback onAddServer,
  Future<void> Function()? onCurrentLineChanged,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => PhoneServerManager(
    auth: auth,
    onSelect: onSelect,
    onAddServer: onAddServer,
    onCurrentLineChanged: onCurrentLineChanged,
  ),
);

/// Touch management: server identity and connection addresses are separate.
class PhoneServerManager extends StatefulWidget {
  const PhoneServerManager({
    super.key,
    required this.auth,
    required this.onSelect,
    required this.onAddServer,
    this.onCurrentLineChanged,
  });

  final AuthController auth;
  final Future<void> Function(String, String) onSelect;
  final VoidCallback onAddServer;
  final Future<void> Function()? onCurrentLineChanged;
  static const searchKey = Key('phone-server-search');
  static const addKey = Key('phone-server-add');

  @override
  State<PhoneServerManager> createState() => _PhoneServerManagerState();
}

class _PhoneServerManagerState extends State<PhoneServerManager> {
  final _search = TextEditingController();
  String? _expanded;
  bool _busy = false;
  String? _failure;
  String? _notice;
  Future<void> Function()? _undo;

  @override
  void initState() {
    super.initState();
    _expanded =
        widget.auth.session?.server.id ??
        widget.auth.prefill?.id ??
        widget.auth.savedServers.firstOrNull?.id;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy || widget.auth.isBusy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) _failure = AppLocalizations.of(context).phoneOperationFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(SavedServer server, ServerLine line) => _act(() async {
    await widget.onSelect(server.id, line.id);
    if (!mounted) return;
    final failure = widget.auth.lineSwitchFailure ?? widget.auth.failure;
    if (failure != null) {
      _failure = AppLocalizations.of(context).phoneOperationFailed;
      return;
    }
    Navigator.of(context).pop();
  });

  Future<void> _editLine(SavedServer server, [ServerLine? line]) async {
    final address = await showLineAddressDialog(
      context,
      initialAddress: line?.address,
    );
    if (address == null || !mounted) return;
    await _act(() async {
      if (line == null) {
        await widget.auth.addLine(server.id, address);
      } else {
        final active =
            widget.auth.session?.server.id == server.id &&
            widget.auth.session?.server.activeLineId == line.id;
        await widget.auth.updateLineAddress(server.id, line.id, address);
        if (active) await widget.onCurrentLineChanged?.call();
      }
    });
  }

  Future<void> _rename(SavedServer server) async {
    final l = AppLocalizations.of(context);
    var value = server.nickname ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.phoneRenameServer),
        content: TextFormField(
          key: const Key('phone-server-name'),
          initialValue: value,
          onChanged: (text) => value = text,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l.phoneServerName,
            hintText: server.name,
            helperText: l.phoneServerNameHint,
          ),
          onFieldSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, value),
            child: Text(l.lineAddressSave),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      await _act(() => widget.auth.renameServer(server.id, name));
    }
  }

  Future<void> _delete(SavedServer server) async {
    final l = AppLocalizations.of(context), auth = widget.auth;
    final current = auth.session?.server.id == server.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.deleteServer),
        content: Text(
          '${l.deleteServerConfirmMessage(server.displayName)}'
          '${current ? '\n\n${l.phoneDeleteCurrentServerHint}' : ''}',
        ),
        actions: [
          TextButton(
            key: const Key('phone-mine-server-delete-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.cancelAction),
          ),
          FilledButton(
            key: const Key('phone-mine-server-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.deleteServerConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await _act(() async {
      final stored = await auth.credentials.read(server.id);
      // Close before auth redirects; never pop the new login route afterwards.
      if (current && mounted) Navigator.of(context).pop();
      await auth.deleteServer(server.id);
      if (!current && mounted) {
        setState(() {
          _notice = l.phoneServerDeleted(server.displayName);
          _undo = () => auth.restoreSavedServer(server, stored);
        });
        return;
      }
      if (!messenger.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.phoneServerDeleted(server.displayName)),
          action: SnackBarAction(
            label: l.undoAction,
            onPressed: () {
              unawaited(auth.restoreSavedServer(server, stored));
            },
          ),
        ),
      );
    });
  }

  Widget _line(SavedServer server, ServerLine line) {
    final l = AppLocalizations.of(context), auth = widget.auth;
    final selected =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    final disabled = _busy || auth.isBusy;
    return ListTile(
      key: Key('phone-mine-line-${line.id}'),
      selected: selected,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(line.hostLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        line.address,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: disabled ? null : () => unawaited(_select(server, line)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('phone-mine-line-edit-${server.id}-${line.id}'),
            tooltip: l.editLine,
            icon: const Icon(Icons.edit_outlined),
            onPressed: disabled
                ? null
                : () => unawaited(_editLine(server, line)),
          ),
          IconButton(
            key: Key('phone-mine-line-delete-${server.id}-${line.id}'),
            tooltip: l.deleteLine,
            icon: const Icon(Icons.link_off),
            onPressed: disabled || server.lines.length <= 1
                ? null
                : () => unawaited(
                    _act(() async {
                      await auth.deleteLine(server.id, line.id);
                      if (selected) await widget.onCurrentLineChanged?.call();
                    }),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _server(SavedServer server) {
    final l = AppLocalizations.of(context),
        scheme = Theme.of(context).colorScheme;
    final current = widget.auth.session?.server.id == server.id;
    final expanded = _expanded == server.id || _search.text.trim().isNotEmpty;
    final disabled = _busy || widget.auth.isBusy;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: const Icon(Icons.dns_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () =>
                        setState(() => _expanded = expanded ? null : server.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            server.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (current)
                            Text(
                              l.phoneCurrentServer,
                              style: TextStyle(color: scheme.primary),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l.phoneRenameServer,
                  icon: const Icon(Icons.drive_file_rename_outline),
                  onPressed: disabled ? null : () => unawaited(_rename(server)),
                ),
                IconButton(
                  key: Key('phone-mine-server-delete-${server.id}'),
                  tooltip: l.deleteServer,
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: disabled ? null : () => unawaited(_delete(server)),
                ),
              ],
            ),
            if (expanded) ...[
              const Divider(),
              for (final line in server.lines) _line(server, line),
              TextButton.icon(
                key: Key('phone-mine-line-add-${server.id}'),
                onPressed: disabled ? null : () => unawaited(_editLine(server)),
                icon: const Icon(Icons.add_link),
                label: Text(l.addLine),
              ),
            ] else
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  server.activeLine?.hostLabel ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.expand_more),
                onTap: () => setState(() => _expanded = server.id),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 150),
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: FractionallySizedBox(
      heightFactor: .9,
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: widget.auth,
          builder: (context, _) {
            final l = AppLocalizations.of(context),
                query = _search.text.trim().toLowerCase();
            final servers = widget.auth.savedServers
                .where(
                  (s) =>
                      '${s.displayName} ${s.name} ${s.username} ${s.lines.map((l) => l.address).join(' ')}'
                          .toLowerCase()
                          .contains(query),
                )
                .toList();
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.phoneServerManagement,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: l.cancelAction,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  TextField(
                    key: PhoneServerManager.searchKey,
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: l.searchServers,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() => _search.clear()),
                            ),
                    ),
                  ),
                  if (_busy || widget.auth.isBusy)
                    const LinearProgressIndicator(),
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _failure!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_notice != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _notice!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _act(() async {
                                    await _undo?.call();
                                    if (mounted) {
                                      setState(() {
                                        _notice = null;
                                        _undo = null;
                                      });
                                    }
                                  }),
                                ),
                          child: Text(l.undoAction),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: servers.isEmpty
                        ? Center(
                            child: Text(
                              query.isEmpty
                                  ? l.phoneEmptyServers
                                  : l.phoneNoMatchingServers,
                            ),
                          )
                        : ListView.builder(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            itemCount: servers.length,
                            itemBuilder: (_, i) => _server(servers[i]),
                          ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: PhoneServerManager.addKey,
                      onPressed: _busy || widget.auth.isBusy
                          ? null
                          : () {
                              Navigator.pop(context);
                              widget.onAddServer();
                            },
                      icon: const Icon(Icons.add),
                      label: Text(l.mobileAddServer),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
