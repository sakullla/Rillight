import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/login_widgets.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';

Future<void> showPhoneServerManager(
  BuildContext context, {
  required AuthController auth,
  required Future<void> Function(String serverId, String lineId) onSelect,
  required VoidCallback onAddServer,
  Future<void> Function()? onCurrentLineChanged,
}) => showAppModalSheet<void>(
  context: context,
  builder: (_) => PhoneServerManager(
    auth: auth,
    onSelect: onSelect,
    onAddServer: onAddServer,
    onCurrentLineChanged: onCurrentLineChanged,
  ),
);

Future<void> showPhoneServerManagerSheet(
  BuildContext context,
  AuthController auth,
) => showPhoneServerManager(
  context,
  auth: auth,
  onSelect: (serverId, lineId) async {
    await auth.switchTo(serverId, lineId: lineId);
    if (!context.mounted ||
        !auth.isLoggedIn ||
        auth.lineSwitchFailure != null) {
      return;
    }
    await CatalogScope.maybeOf(context)?.reload();
  },
  onCurrentLineChanged: () async {
    if (context.mounted) await CatalogScope.maybeOf(context)?.reload();
  },
  onAddServer: () {
    if (context.mounted) context.push('${AppRoutes.connect}?add=1');
  },
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
  static const importKey = Key('phone-server-import');

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
    final name = await showAppDialog<String>(
      context: context,
      builder: (dialog) => AppDialog(
        title: Text(l.phoneRenameServer),
        content: AppTextField(
          key: const Key('phone-server-name'),
          initialValue: value,
          onChanged: (text) => value = text,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          label: l.phoneServerName,
          placeholder: server.name,
          helperText: l.phoneServerNameHint,
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          AppButton(
            onPressed: () => Navigator.pop(dialog),
            variant: AppButtonVariant.plain,
            child: Text(l.cancelAction),
          ),
          AppButton(
            onPressed: () => Navigator.pop(dialog, value),
            variant: AppButtonVariant.filled,
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
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AppDialog(
        title: Text(l.deleteServer),
        content: Text(
          '${l.deleteServerConfirmMessage(server.displayName)}'
          '${current ? '\n\n${l.phoneDeleteCurrentServerHint}' : ''}',
        ),
        actions: [
          AppButton(
            key: const Key('phone-mine-server-delete-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            variant: AppButtonVariant.plain,
            child: Text(l.cancelAction),
          ),
          AppButton(
            key: const Key('phone-mine-server-delete-confirm'),
            style: AppButtonStyle(
              backgroundColor: AppUiTheme.of(dialog).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            variant: AppButtonVariant.filled,
            child: Text(l.deleteServerConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final noticeHost = AppNoticeHost.of(context);
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
      noticeHost.show(
        l.phoneServerDeleted(server.displayName),
        actionLabel: l.undoAction,
        onAction: () => unawaited(auth.restoreSavedServer(server, stored)),
      );
    });
  }

  Widget _line(SavedServer server, ServerLine line) {
    final l = AppLocalizations.of(context), auth = widget.auth;
    final selected =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    final disabled = _busy || auth.isBusy;
    return AppListTile(
      key: Key('phone-mine-line-${line.id}'),
      selected: selected,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected
            ? CupertinoIcons.largecircle_fill_circle
            : CupertinoIcons.circle,
        color: selected ? AppUiTheme.of(context).colorScheme.primary : null,
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
          AppIconButton(
            key: Key('phone-mine-line-edit-${server.id}-${line.id}'),
            tooltip: l.editLine,
            icon: const Icon(CupertinoIcons.pencil),
            onPressed: disabled
                ? null
                : () => unawaited(_editLine(server, line)),
          ),
          AppIconButton(
            key: Key('phone-mine-line-delete-${server.id}-${line.id}'),
            tooltip: l.deleteLine,
            icon: const Icon(CupertinoIcons.link),
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
        scheme = AppUiTheme.of(context).colorScheme;
    final current = widget.auth.session?.server.id == server.id;
    final expanded = _expanded == server.id || _search.text.trim().isNotEmpty;
    final disabled = _busy || widget.auth.isBusy;
    return Container(
      decoration: BoxDecoration(
        color: AppUiTheme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: current ? scheme.primary : scheme.outlineVariant,
          width: current ? 1.5 : 1,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ServerTypeMark(type: server.serviceType, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: AppSurfaceAction(
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
                            style: AppUiTheme.of(context).textTheme.titleMedium,
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
                AppIconButton(
                  tooltip: l.phoneRenameServer,
                  icon: const Icon(CupertinoIcons.pencil),
                  onPressed: disabled ? null : () => unawaited(_rename(server)),
                ),
                AppIconButton(
                  key: Key('phone-mine-server-delete-${server.id}'),
                  tooltip: l.deleteServer,
                  icon: Icon(CupertinoIcons.trash, color: scheme.error),
                  onPressed: disabled ? null : () => unawaited(_delete(server)),
                ),
              ],
            ),
            if (expanded) ...[
              const AppDivider(),
              for (final line in server.lines) _line(server, line),
              AppButton.icon(
                key: Key('phone-mine-line-add-${server.id}'),
                onPressed: disabled ? null : () => unawaited(_editLine(server)),
                icon: const Icon(CupertinoIcons.link),
                label: Text(l.addLine),
                variant: AppButtonVariant.plain,
              ),
            ] else
              AppListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  server.activeLine?.hostLabel ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(CupertinoIcons.chevron_down),
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
                          style: AppUiTheme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      AppIconButton(
                        tooltip: l.cancelAction,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(CupertinoIcons.xmark),
                      ),
                    ],
                  ),
                  AppTextField(
                    key: PhoneServerManager.searchKey,
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    textInputAction: TextInputAction.search,
                    placeholder: l.searchServers,
                    prefix: const Icon(CupertinoIcons.search),
                    suffix: query.isEmpty
                        ? null
                        : AppIconButton(
                            icon: const Icon(CupertinoIcons.xmark),
                            onPressed: () => setState(() => _search.clear()),
                          ),
                  ),
                  if (_busy || widget.auth.isBusy) const AppLoadingBar(),
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _failure!,
                        style: TextStyle(
                          color: AppUiTheme.of(context).colorScheme.error,
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
                        AppButton(
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
                          variant: AppButtonVariant.plain,
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
                  // 备份导入:结果面板盖在底表上方,导入后列表随 auth 刷新。
                  SizedBox(
                    width: double.infinity,
                    child: AppButton.icon(
                      key: PhoneServerManager.importKey,
                      onPressed: _busy || widget.auth.isBusy
                          ? null
                          : () => unawaited(
                              showBackupImportFlow(context, auth: widget.auth),
                            ),
                      icon: const Icon(
                        CupertinoIcons.square_arrow_down,
                        size: 18,
                      ),
                      label: Text(l.backupImportEntry),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: AppButton.icon(
                      key: PhoneServerManager.addKey,
                      onPressed: _busy || widget.auth.isBusy
                          ? null
                          : () {
                              Navigator.pop(context);
                              widget.onAddServer();
                            },
                      icon: const Icon(CupertinoIcons.plus),
                      label: Text(l.mobileAddServer),
                      variant: AppButtonVariant.filled,
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
