import 'provider_connect_dialog.dart';
import '../media_server/capabilities.dart';
import '../app/presentation_environment.dart';
import '../app/tv_widgets.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import 'auth_controller.dart';
import 'auth_scope.dart';
import 'backup_import/backup_import_flow.dart';
import 'source_sessions.dart';
import 'server_list_store.dart';
import 'region_access.dart' show RegionAccessController;

Future<void> showSourceManagement(
  BuildContext context, {
  AccessRegion region = AccessRegion.ordinary,
}) {
  final auth = AuthScope.of(context);
  return showAppDialog<void>(
    context: context,
    builder: (_) => SourceManagement(auth: auth, region: region),
  );
}

/// One registry for touch, keyboard and remote management. Ordinary projection
/// never receives private identities, even while the private region is unlocked.
class SourceManagement extends StatefulWidget {
  const SourceManagement({
    super.key,
    required this.auth,
    this.region = AccessRegion.ordinary,
  });
  final AuthController auth;
  final AccessRegion region;
  @override
  State<SourceManagement> createState() => _SourceManagementState();
}

class _SourceManagementState extends State<SourceManagement> {
  bool _busy = false;
  String? _error;
  final Map<String, Map<String, String>> _libraries = {};
  SourceSessionRegistry get registry => widget.auth.sources;
  @override
  void initState() {
    super.initState();
    widget.auth.regionAccess.addListener(_accessChanged);
    registry.addSourceRevocation(_sourceChanged);
  }

  void _sourceChanged(String id) {
    _libraries.remove(id);
    if (mounted) setState(() {});
  }

  void _accessChanged() {
    if (!mounted) return;
    if (!widget.auth.regionAccess.allows(widget.region)) {
      _libraries.clear();
      setState(() {});
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route?.isActive == true) {
          Navigator.of(context).removeRoute(route!);
        }
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.auth.regionAccess.removeListener(_accessChanged);
    registry.removeSourceRevocation(_sourceChanged);
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) _error = AppLocalizations.of(context).sourceOperationFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _text(String title, String initial, String sourceId) async {
    final controller = TextEditingController(text: initial);
    final result = await showAppDialog<String>(
      context: context,
      builder: (dialog) => _RegionDialogBoundary(
        access: widget.auth.regionAccess,
        region: widget.region,
        registry: registry,
        sourceId: sourceId,
        onRevoked: controller.clear,
        child: AppDialog(
          title: Text(title),
          content: PresentationScope.maybeOf(context)?.isTv == true
              ? TvInput(label: title, controller: controller, autofocus: true)
              : AppTextField(
                  key: const Key('source-text-value'),
                  controller: controller,
                  autofocus: true,
                ),
          actions: [
            AppButton(
              onPressed: () => Navigator.pop(dialog),
              variant: AppButtonVariant.plain,
              child: Text(AppLocalizations.of(context).cancelAction),
            ),
            AppButton(
              onPressed: () => Navigator.pop(dialog, controller.text),
              variant: AppButtonVariant.filled,
              child: Text(AppLocalizations.of(context).lineAddressSave),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _login(String id, {bool home = false}) async {
    final server = registry
        .project(widget.region)
        .firstWhere((s) => s.id == id);
    await showProviderConnect(
      context,
      widget.auth,
      existing: server,
      region: widget.region,
      home: home,
    );
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(
    SavedServer server,
    String title,
    String message,
  ) async {
    final l = AppLocalizations.of(context);
    return await showAppDialog<bool>(
          context: context,
          builder: (dialog) => _RegionDialogBoundary(
            access: widget.auth.regionAccess,
            region: widget.region,
            registry: registry,
            sourceId: server.id,
            child: AppDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                AppButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  variant: AppButtonVariant.plain,
                  child: Text(l.cancelAction),
                ),
                AppButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  variant: AppButtonVariant.filled,
                  child: Text(title),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _logout(SavedServer server, {bool remove = false}) async {
    final l = AppLocalizations.of(context);
    if (!await _confirm(
      server,
      remove ? l.deleteServer : l.logout,
      remove
          ? l.deleteServerConfirmMessage(server.displayName)
          : '${l.logout} · ${server.displayName}',
    )) {
      return;
    }
    if (!mounted) return;
    await _act(() async {
      await registry.logoutSource(server.id, remove: remove);
      await widget.auth.refreshServers();
    });
  }

  Future<void> _editAddress(SavedServer server, [ServerLine? line]) async {
    final l = AppLocalizations.of(context);
    final value = await _text(
      line == null ? l.addLine : l.editLine,
      line?.address ?? '',
      server.id,
    );
    if (value == null || !mounted) return;
    final wasActive =
        widget.region == AccessRegion.ordinary &&
        widget.auth.session?.server.id == server.id &&
        widget.auth.session?.server.activeLineId == line?.id;
    await _act(() async {
      await registry.setLineAddress(server.id, value, lineId: line?.id);
      await widget.auth.refreshServers();
      if (wasActive) await widget.auth.switchTo(server.id, lineId: line!.id);
    });
  }

  Future<void> _removeLine(SavedServer server, ServerLine line) async {
    final l = AppLocalizations.of(context);
    if (!await _confirm(
      server,
      l.deleteLine,
      line.nickname ?? line.hostLabel,
    )) {
      return;
    }
    if (!mounted) return;
    final wasActive =
        widget.region == AccessRegion.ordinary &&
        widget.auth.session?.server.id == server.id &&
        widget.auth.session?.server.activeLineId == line.id;
    await _act(() async {
      await registry.removeLine(server.id, line.id);
      await widget.auth.refreshServers();
      if (wasActive) await widget.auth.switchTo(server.id);
    });
  }

  Future<void> _move(SavedServer server) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AppDialog(
        content: Text(l.sourceMoveWarning),
        actions: [
          AppButton(
            onPressed: () => Navigator.pop(dialog),
            variant: AppButtonVariant.plain,
            child: Text(l.cancelAction),
          ),
          AppButton(
            onPressed: () => Navigator.pop(dialog, true),
            variant: AppButtonVariant.filled,
            child: Text(l.lineAddressSave),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _act(
        () => registry.move(
          server.id,
          server.region == AccessRegion.ordinary
              ? AccessRegion.private
              : AccessRegion.ordinary,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (!widget.auth.regionAccess.allows(widget.region)) {
      return AppDialog(content: Text(l.aggregationPrivateLocked));
    }
    final servers = registry.project(widget.region);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AppDialog(
        title: Text(l.sourceManagement),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            children: [
              AppButton.icon(
                key: const Key('source-add-provider'),
                icon: const Icon(CupertinoIcons.plus),
                label: Text(l.providerConnectEntry),
                onPressed: _busy
                    ? null
                    : () async {
                        await showProviderConnect(
                          context,
                          widget.auth,
                          region: widget.region,
                        );
                        if (mounted) setState(() {});
                      },
                variant: AppButtonVariant.outlined,
              ),
              if (_busy) const AppLoadingBar(),
              if (_error != null)
                Text(_error!, key: const Key('source-management-error')),
              if (widget.region == AccessRegion.ordinary)
                AppListTile(
                  leading: const Icon(CupertinoIcons.lock),
                  title: Text(l.aggregationPrivate),
                  onTap: _busy
                      ? null
                      : () async {
                          await showPrivateAccess(context, widget.auth);
                          if (mounted) setState(() {});
                        },
                ),
              for (var index = 0; index < servers.length; index++) ...[
                AppListTile(
                  title: Text(servers[index].displayName),
                  subtitle: Text(
                    '${servers[index].serviceType.name} · ${servers[index].username} · ${servers[index].checkStatus} · ${servers[index].checkedAt?.toLocal().toString() ?? '—'}',
                  ),
                  trailing: AppIconButton(
                    icon: const Icon(CupertinoIcons.arrow_up),
                    onPressed: _busy || index == 0
                        ? null
                        : () => _act(() {
                            final ids = servers.map((s) => s.id).toList();
                            final id = ids.removeAt(index);
                            ids.insert(index - 1, id);
                            return registry.reorder(widget.region, ids);
                          }),
                  ),
                ),
                AppSwitchTile(
                  key: Key('source-participates-${servers[index].id}'),
                  title: Text(l.sourceParticipates),
                  value: servers[index].participates,
                  onChanged: _busy
                      ? null
                      : (value) => _act(
                          () => registry.configureScope(
                            servers[index].id,
                            participates: value,
                            libraryIds: servers[index].libraryIds.toSet(),
                          ),
                        ),
                ),
                if (!servers[index].scopeKnown) Text(l.sourceScopeUnknown),
                Wrap(
                  spacing: 8,
                  children: [
                    AppButton(
                      key: Key('source-add-line-${servers[index].id}'),
                      onPressed: _busy
                          ? null
                          : () => _editAddress(servers[index]),
                      variant: AppButtonVariant.plain,
                      child: Text(l.addLine),
                    ),
                    AppButton(
                      key: Key('source-logout-${servers[index].id}'),
                      onPressed: _busy ? null : () => _logout(servers[index]),
                      variant: AppButtonVariant.plain,
                      child: Text(l.logout),
                    ),
                    AppButton(
                      key: Key('source-delete-${servers[index].id}'),
                      onPressed: _busy
                          ? null
                          : () => _logout(servers[index], remove: true),
                      variant: AppButtonVariant.plain,
                      child: Text(l.deleteServer),
                    ),
                    AppButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                              final values = await registry.discoverLibraries(
                                servers[index].id,
                              );
                              if (mounted) {
                                _libraries[servers[index].id] = values;
                              }
                            }),
                      variant: AppButtonVariant.plain,
                      child: Text(l.sourceDiscoverLibraries),
                    ),
                    if (servers[index].serviceType == MediaServerType.plex)
                      AppButton(
                        onPressed: _busy
                            ? null
                            : () => _login(servers[index].id, home: true),
                        variant: AppButtonVariant.plain,
                        child: Text(l.providerHomeManage),
                      ),
                    AppButton(
                      onPressed: _busy ? null : () => _login(servers[index].id),
                      variant: AppButtonVariant.plain,
                      child: Text(l.sourceIndependentLogin),
                    ),
                    AppButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                              await registry.check(servers[index].id);
                            }),
                      variant: AppButtonVariant.plain,
                      child: Text(l.sourceManualCheck),
                    ),
                    AppButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final value = await _text(
                                l.phoneRenameServer,
                                servers[index].nickname ?? '',
                                servers[index].id,
                              );
                              if (value != null && mounted) {
                                await _act(
                                  () =>
                                      registry.rename(servers[index].id, value),
                                );
                              }
                            },
                      variant: AppButtonVariant.plain,
                      child: Text(l.phoneRenameServer),
                    ),
                    if (widget.auth.regionAccess.allows(AccessRegion.private))
                      AppButton(
                        onPressed: _busy ? null : () => _move(servers[index]),
                        variant: AppButtonVariant.plain,
                        child: Text(
                          widget.region == AccessRegion.ordinary
                              ? l.sourceMovePrivate
                              : l.sourceMoveOrdinary,
                        ),
                      ),
                  ],
                ),
                for (final entry
                    in (_libraries[servers[index].id] ??
                            {
                              for (final id in servers[index].libraryIds)
                                id: id,
                            })
                        .entries)
                  AppSwitchTile(
                    title: Text(entry.value),
                    value: servers[index].libraryIds.contains(entry.key),
                    onChanged: _busy
                        ? null
                        : (value) => _act(() {
                            final ids = servers[index].libraryIds.toSet();
                            value == true
                                ? ids.add(entry.key)
                                : ids.remove(entry.key);
                            return registry.configureScope(
                              servers[index].id,
                              participates: servers[index].participates,
                              libraryIds: ids,
                            );
                          }),
                  ),
                for (final line in servers[index].lines)
                  AppListTile(
                    title: Text(line.nickname ?? line.hostLabel),
                    subtitle: Text(
                      '${line.checkStatus} · ${line.checkedAt?.toLocal().toString() ?? '—'}',
                    ),
                    leading: AppIconButton(
                      icon: const Icon(CupertinoIcons.arrow_up),
                      onPressed: _busy || servers[index].lines.first == line
                          ? null
                          : () => _act(() {
                              final ids = servers[index].lines
                                  .map((l) => l.id)
                                  .toList();
                              final position = ids.indexOf(line.id);
                              ids.removeAt(position);
                              ids.insert(position - 1, line.id);
                              return registry.reorderLines(
                                servers[index].id,
                                ids,
                              );
                            }),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIconButton(
                          key: Key(
                            'source-line-check-${servers[index].id}-${line.id}',
                          ),
                          icon: const Icon(CupertinoIcons.wifi),
                          tooltip: l.sourceManualCheck,
                          onPressed: _busy
                              ? null
                              : () => _act(() async {
                                  await registry.check(
                                    servers[index].id,
                                    lineId: line.id,
                                  );
                                }),
                        ),
                        AppIconButton(
                          icon: const Icon(CupertinoIcons.pencil),
                          tooltip: l.sourceRenameLine,
                          onPressed: _busy
                              ? null
                              : () async {
                                  final value = await _text(
                                    l.sourceRenameLine,
                                    line.nickname ?? '',
                                    servers[index].id,
                                  );
                                  if (value != null && mounted) {
                                    await _act(
                                      () => registry.renameLine(
                                        servers[index].id,
                                        line.id,
                                        value,
                                      ),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                for (final line in servers[index].lines)
                  Wrap(
                    spacing: 8,
                    children: [
                      AppButton.icon(
                        key: Key(
                          'source-edit-line-${servers[index].id}-${line.id}',
                        ),
                        icon: const Icon(CupertinoIcons.pencil),
                        onPressed: _busy
                            ? null
                            : () => _editAddress(servers[index], line),
                        label: Text(
                          '${l.editLine} · ${line.nickname ?? line.hostLabel}',
                        ),
                        variant: AppButtonVariant.plain,
                      ),
                      AppButton.icon(
                        key: Key(
                          'source-delete-line-${servers[index].id}-${line.id}',
                        ),
                        icon: const Icon(CupertinoIcons.trash),
                        onPressed: _busy || servers[index].lines.length < 2
                            ? null
                            : () => _removeLine(servers[index], line),
                        label: Text(l.deleteLine),
                        variant: AppButtonVariant.plain,
                      ),
                    ],
                  ),
                const AppDivider(),
              ],
            ],
          ),
        ),
        actions: [
          AppButton(
            key: const Key('source-management-import'),
            onPressed: _busy
                ? null
                : () => unawaited(
                    showBackupImportFlow(
                      context,
                      auth: widget.auth,
                      region: widget.region,
                    ),
                  ),
            child: Text(l.backupImportEntry),
          ),
          AppButton(
            key: const Key('source-management-close'),
            onPressed: () => Navigator.pop(context),
            variant: AppButtonVariant.plain,
            child: Text(l.cancelAction),
          ),
        ],
      ),
    );
  }
}

class _RegionDialogBoundary extends StatefulWidget {
  const _RegionDialogBoundary({
    required this.access,
    required this.region,
    required this.child,
    required this.registry,
    required this.sourceId,
    this.onRevoked,
  });
  final SourceSessionRegistry registry;
  final String sourceId;
  final VoidCallback? onRevoked;
  final RegionAccessController access;
  final AccessRegion region;
  final Widget child;
  @override
  State<_RegionDialogBoundary> createState() => _RegionDialogBoundaryState();
}

class _RegionDialogBoundaryState extends State<_RegionDialogBoundary> {
  bool _revoked = false;
  void _sourceChanged(String id) {
    if (id != widget.sourceId) return;
    _revoked = true;
    _changed();
  }

  @override
  void initState() {
    super.initState();
    widget.access.addListener(_changed);
    widget.registry.addSourceRevocation(_sourceChanged);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_revoked || !widget.access.allows(widget.region)) {
      widget.onRevoked?.call();
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route?.isActive == true) {
          final navigator = Navigator.of(context);
          navigator.popUntil((candidate) => identical(candidate, route));
          navigator.pop();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.access.removeListener(_changed);
    widget.registry.removeSourceRevocation(_sourceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      !_revoked && widget.access.allows(widget.region)
      ? widget.child
      : AppDialog(
          content: Text(AppLocalizations.of(context).aggregationPrivateLocked),
        );
}

Future<void> showPrivateAccess(BuildContext context, AuthController auth) =>
    showAppDialog<void>(
      context: context,
      builder: (_) => PrivateAccessDialog(auth: auth),
    );

class PrivateAccessDialog extends StatefulWidget {
  const PrivateAccessDialog({super.key, required this.auth});
  final AuthController auth;
  @override
  State<PrivateAccessDialog> createState() => _PrivateAccessDialogState();
}

class _PrivateAccessDialogState extends State<PrivateAccessDialog> {
  final _pin = TextEditingController(), _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    if (_busy) unawaited(widget.auth.regionAccess.lock());
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = widget.auth;
    try {
      if (!auth.regionAccess.hasPin) {
        await auth.setPrivatePin(_pin.text, _confirmation.text);
      }
      if (!mounted) return;
      if (!await auth.regionAccess.unlock(_pin.text)) {
        throw StateError('PIN rejected');
      }
      if (mounted) {
        _busy = false;
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        _error = auth.regionAccess.retryAt != null
            ? '${AppLocalizations.of(context).privateRateLimited}\n${auth.regionAccess.retryAt!.toLocal()}'
            : AppLocalizations.of(context).privatePinFailure;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), access = widget.auth.regionAccess;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AppDialog(
        title: Text(l.aggregationPrivate),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!access.allows(AccessRegion.private)) ...[
              AppTextField(
                key: const Key('private-pin'),
                controller: _pin,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _submit(),
                label: l.privatePin,
              ),
              if (!access.hasPin)
                AppTextField(
                  key: const Key('private-pin-confirm'),
                  controller: _confirmation,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  label: l.privateConfirmPin,
                ),
            ],
            if (_busy) const AppLoadingBar(),
            if (_error != null)
              Text(_error!, key: const Key('private-pin-error')),
          ],
        ),
        actions: [
          AppButton(
            key: const Key('private-pin-cancel'),
            onPressed: _busy ? null : () => Navigator.pop(context),
            variant: AppButtonVariant.plain,
            child: Text(l.cancelAction),
          ),
          if (access.allows(AccessRegion.private)) ...[
            AppButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(access.lock());
              },
              variant: AppButtonVariant.plain,
              child: Text(l.privateLock),
            ),
            AppButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(
                  showSourceManagement(context, region: AccessRegion.private),
                );
              },
              variant: AppButtonVariant.filled,
              child: Text(l.sourceManagement),
            ),
          ] else
            AppButton(
              key: const Key('private-unlock'),
              onPressed: _busy ? null : _submit,
              variant: AppButtonVariant.filled,
              child: Text(access.hasPin ? l.privateUnlock : l.privateSetPin),
            ),
        ],
      ),
    );
  }
}
