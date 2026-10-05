import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import 'auth_controller.dart';
import 'auth_scope.dart';
import 'source_sessions.dart';
import 'server_list_store.dart';
import 'region_access.dart' show RegionAccessController;

Future<void> showSourceManagement(
  BuildContext context, {
  AccessRegion region = AccessRegion.ordinary,
}) {
  final auth = AuthScope.of(context);
  return showDialog<void>(
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
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => _RegionDialogBoundary(
        access: widget.auth.regionAccess,
        region: widget.region,
        registry: registry,
        sourceId: sourceId,
        child: AlertDialog(
          title: Text(title),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(AppLocalizations.of(context).cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, controller.text),
              child: Text(AppLocalizations.of(context).lineAddressSave),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _login(String id) async {
    final name = TextEditingController(), password = TextEditingController();
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => _RegionDialogBoundary(
        access: widget.auth.regionAccess,
        region: widget.region,
        registry: registry,
        sourceId: id,
        child: AlertDialog(
          title: Text(l.sourceIndependentLogin),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(labelText: l.username),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: InputDecoration(labelText: l.password),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(l.cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l.sourceIndependentLogin),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await _act(() => registry.login(id, name.text, password.text));
    }
    name.dispose();
    password.dispose();
  }

  Future<void> _move(SavedServer server) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(l.sourceMoveWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
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
      return AlertDialog(content: Text(l.aggregationPrivateLocked));
    }
    final servers = registry.project(widget.region);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AlertDialog(
        title: Text(l.sourceManagement),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(_error!, key: const Key('source-management-error')),
              if (widget.region == AccessRegion.ordinary)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(l.aggregationPrivate),
                  onTap: _busy
                      ? null
                      : () async {
                          await showPrivateAccess(context, widget.auth);
                          if (mounted) setState(() {});
                        },
                ),
              for (var index = 0; index < servers.length; index++) ...[
                ListTile(
                  title: Text(servers[index].displayName),
                  subtitle: Text(
                    '${servers[index].checkStatus} · ${servers[index].checkedAt?.toLocal().toString() ?? '—'}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.arrow_upward),
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
                SwitchListTile(
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
                    TextButton(
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
                      child: Text(l.sourceDiscoverLibraries),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _login(servers[index].id),
                      child: Text(l.sourceIndependentLogin),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                              await registry.check(servers[index].id);
                            }),
                      child: Text(l.sourceManualCheck),
                    ),
                    TextButton(
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
                      child: Text(l.phoneRenameServer),
                    ),
                    if (widget.auth.regionAccess.allows(AccessRegion.private))
                      TextButton(
                        onPressed: _busy ? null : () => _move(servers[index]),
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
                  CheckboxListTile(
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
                  ListTile(
                    title: Text(line.nickname ?? line.hostLabel),
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_upward),
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
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
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
                  ),
                const Divider(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('source-management-close'),
            onPressed: () => Navigator.pop(context),
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
  });
  final SourceSessionRegistry registry;
  final String sourceId;
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
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route?.isActive == true) {
          Navigator.of(context).removeRoute(route!);
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
      : AlertDialog(
          content: Text(AppLocalizations.of(context).aggregationPrivateLocked),
        );
}

Future<void> showPrivateAccess(BuildContext context, AuthController auth) =>
    showDialog<void>(
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
      child: AlertDialog(
        title: Text(l.aggregationPrivate),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!access.allows(AccessRegion.private)) ...[
              TextField(
                key: const Key('private-pin'),
                controller: _pin,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.privatePin),
                onSubmitted: (_) => _submit(),
              ),
              if (!access.hasPin)
                TextField(
                  key: const Key('private-pin-confirm'),
                  controller: _confirmation,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.privateConfirmPin),
                ),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, key: const Key('private-pin-error')),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('private-pin-cancel'),
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l.cancelAction),
          ),
          if (access.allows(AccessRegion.private)) ...[
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(access.lock());
              },
              child: Text(l.privateLock),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(
                  showSourceManagement(context, region: AccessRegion.private),
                );
              },
              child: Text(l.sourceManagement),
            ),
          ] else
            FilledButton(
              key: const Key('private-unlock'),
              onPressed: _busy ? null : _submit,
              child: Text(access.hasPin ? l.privateUnlock : l.privateSetPin),
            ),
        ],
      ),
    );
  }
}
