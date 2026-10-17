import 'dart:async';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/errors.dart';
import 'auth_controller.dart';
import '../player/player_window_host.dart';
import 'backup_import/backup_import_flow.dart';
import 'provider_connect_dialog.dart';
import 'server_add_panel.dart';
import 'server_editor.dart';
import 'server_flow_frame.dart';
import 'server_line_selector.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'server_password_form.dart';

Future<void> showServerSelection(
  BuildContext context, {
  required AuthController auth,
  bool phone = false,
  Future<void> Function()? onEntered,
  Future<void> Function()? onLineChanged,
}) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ServerSelectionPage(
    auth: auth,
    phone: phone,
    onEntered: onEntered,
    onLineChanged: onLineChanged,
  ),
);

/// Desktop owns a bounded panel; phone owns the complete safe viewport. Every
/// edit/password/line child replaces this route's body and returns to the same
/// list controller, preserving search, scroll and original entry destination.
class ServerSelectionPage extends StatefulWidget {
  static const searchKey = Key('server-search');
  static const addKey = Key('server-add');
  static const importKey = Key('server-add-import');
  const ServerSelectionPage({
    super.key,
    required this.auth,
    this.phone = false,
    this.onEntered,
    this.onLineChanged,
  });
  final AuthController auth;
  final bool phone;
  final Future<void> Function()? onEntered, onLineChanged;
  @override
  State<ServerSelectionPage> createState() => _ServerSelectionPageState();
}

class _ServerSelectionPageState extends State<ServerSelectionPage> {
  final search = TextEditingController();
  final scroll = ScrollController();
  final Map<String, String> errors = {};
  final Set<String> pending = {};
  final Map<String, GlobalKey> itemKeys = {};
  final Map<String, FocusNode> itemFocus = {};
  final editorKey = GlobalKey<ServerEditorState>();
  final addKey = GlobalKey<ServerAddPanelState>();
  int entryRevision = 0;
  String step = 'list';
  SavedServer? target;
  String destination = 'enter';
  Completer<String?>? password;
  String? unlockError;
  bool unlockBusy = false, ready = false;
  @override
  void initState() {
    super.initState();
    unawaited(register());
  }

  Future<void> register() async {
    for (final server in widget.auth.savedServers) {
      await widget.auth.serverAccess.register(server);
    }
    if (mounted) setState(() => ready = true);
  }

  @override
  void dispose() {
    widget.auth.serverEntry.cancel();
    if (password?.isCompleted == false) password!.complete(null);
    for (final node in itemFocus.values) {
      node.dispose();
    }
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void back() {
    if (step == 'edit') {
      editorKey.currentState?.back();
      return;
    }
    if (step == 'add') {
      addKey.currentState?.back();
      return;
    }
    returnToList();
  }

  void returnToList() {
    entryRevision++;
    widget.auth.serverEntry.cancel();
    if (password?.isCompleted == false) password!.complete(null);
    if (step == 'list') {
      Navigator.of(context).pop();
      return;
    }
    final id = target?.id;
    setState(() {
      step = 'list';
      unlockBusy = false;
      unlockError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final entry = itemKeys[id]?.currentContext;
      if (entry != null) {
        Scrollable.ensureVisible(
          entry,
          duration: const Duration(milliseconds: 120),
        );
        itemFocus[id]?.requestFocus();
      }
    });
  }

  void open(SavedServer server, String next) {
    target = server;
    if (!widget.auth.serverAccess.allows(server.id)) {
      unawaited(enter(server, next: next));
      return;
    }
    setState(() => step = next);
  }

  Future<void> enter(
    SavedServer server, {
    String next = 'enter',
    String? suppliedPassword,
  }) async {
    final l = AppLocalizations.of(context);
    final revision = ++entryRevision;
    var passwordRejected = false;
    widget.auth.serverEntry.cancel();
    if (password?.isCompleted == false) password!.complete(null);
    target = server;
    destination = next;
    setState(() {
      pending.add(server.id);
      errors.remove(server.id);
      unlockError = null;
    });
    try {
      final succeeded = await widget.auth.serverEntry.enter<String>(
        server: server,
        destination: next,
        onPasswordRejected: () => passwordRejected = true,
        requestPassword: () {
          if (suppliedPassword != null) {
            setState(() {
              step = 'unlock';
              unlockBusy = true;
            });
            return Future.value(suppliedPassword);
          }
          password = Completer<String?>();
          setState(() {
            step = 'unlock';
            unlockBusy = false;
          });
          return password!.future;
        },
        connect: (guard) async {
          guard();
          if (next == 'enter' || !widget.auth.serverAccess.allows(server.id)) {
            await widget.auth.switchTo(server.id, guard: guard);
            guard();
            return widget.auth.session?.server.id == server.id &&
                widget.auth.failure == null;
          }
          // Inspect/edit a protected server after a real connection preflight;
          // do not alter the selected browsing server or close any player.
          await widget.auth.sources.ensureSession(server.id);
          guard();
          return true;
        },
        navigate: (value) async {
          if (!mounted) return;
          if (value == 'enter') {
            await widget.onEntered?.call();
            if (mounted) Navigator.of(context).pop();
          } else {
            setState(() {
              step = value;
              unlockBusy = false;
            });
          }
        },
      );
      if (!succeeded && mounted && revision == entryRevision) {
        if (step == 'unlock' && passwordRejected) {
          setState(() {
            unlockBusy = false;
            unlockError = l.serversPasswordWrong;
          });
        } else if (widget.auth.failure?.kind ==
            MediaServerFailureKind.sessionExpired) {
          setState(() => step = 'login');
        } else if (step == 'unlock') {
          setState(() {
            unlockBusy = false;
            unlockError = widget.auth.failure == null
                ? l.serversConnectionFailed
                : serverOperationFailure(l, widget.auth.failure!);
          });
        } else {
          setState(
            () => errors[server.id] = widget.auth.failure == null
                ? l.serversConnectionFailed
                : serverOperationFailure(l, widget.auth.failure!),
          );
        }
      }
    } catch (failure) {
      if (mounted && revision == entryRevision) {
        setState(() {
          final message = serverOperationFailure(l, failure);
          if (step == 'unlock') {
            unlockError = message;
            unlockBusy = false;
          } else {
            errors[server.id] = message;
          }
        });
      }
    } finally {
      if (mounted) setState(() => pending.remove(server.id));
    }
  }

  void submitPassword(String value) {
    if (password?.isCompleted == false) {
      setState(() => unlockBusy = true);
      password!.complete(value);
    } else {
      // A failed check starts a new intent; no stale candidate can navigate.
      unawaited(enter(target!, next: destination, suppliedPassword: value));
    }
  }

  Future<void> action(SavedServer server, String action) async {
    if (action == 'edit') {
      open(server, 'edit');
      return;
    }
    if (action == 'remove') {
      setState(() {
        target = server;
        step = 'remove';
      });
      return;
    }
    final ids = widget.auth.savedServers.map((s) => s.id).toList();
    final index = ids.indexOf(server.id),
        next = ids.indexOf(server.id) + (action == 'up' ? -1 : 1);
    if (index < 0 || next < 0 || next >= ids.length) return;
    ids.removeAt(index);
    ids.insert(next, server.id);
    setState(() => pending.add(server.id));
    try {
      await widget.auth.reorderServers(ids);
    } catch (failure) {
      if (mounted) {
        errors[server.id] = serverOperationFailure(
          AppLocalizations.of(context),
          failure,
        );
      }
    } finally {
      if (mounted) setState(() => pending.remove(server.id));
    }
  }

  Future<void> remove() async {
    final server = target!;
    setState(() => pending.add(server.id));
    try {
      if (widget.auth.session?.server.id == server.id) {
        await PlayerWindowScope.maybeOf(context)?.close();
      }
      await widget.auth.deleteServer(server.id);
      widget.auth.serverAccess.unregister(server.id);
      if (mounted) back();
    } catch (failure) {
      if (mounted) {
        errors[server.id] = serverOperationFailure(
          AppLocalizations.of(context),
          failure,
        );
      }
    } finally {
      if (mounted) setState(() => pending.remove(server.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.auth, widget.auth.serverAccess]),
    builder: (context, _) {
      final l = AppLocalizations.of(context), theme = AppUiTheme.of(context);
      Widget content;
      if (step == 'edit') {
        content = ServerEditor(
          key: editorKey,
          auth: widget.auth,
          server: target!,
          onBack: returnToList,
          onSaved: returnToList,
          onSignedOut: () => Navigator.of(context).pop(),
        );
      } else if (step == 'lines') {
        content = ServerLineSelector(
          auth: widget.auth,
          serverId: target!.id,
          onBack: back,
          onChanged: widget.onLineChanged,
        );
      } else if (step == 'add') {
        content = ServerAddPanel(
          key: addKey,
          auth: widget.auth,
          onBack: returnToList,
          onConnected: () async {
            await register();
            if (mounted) {
              await widget.onEntered?.call();
              if (context.mounted) Navigator.pop(context);
            }
          },
          onImport: () {
            // Replace this flow before opening the existing file-import route.
            final outer = Navigator.of(context).context;
            Navigator.of(context).pop();
            unawaited(showBackupImportFlow(outer, auth: widget.auth));
          },
        );
      } else if (step == 'login') {
        content = ServerFlowFrame(
          title: l.serversAccount,
          onBack: back,
          child: ProviderConnectDialog(
            auth: widget.auth,
            existing: target,
            inline: true,
            onConnected: () => enter(widget.auth.sources.server(target!.id)),
          ),
        );
      } else if (step == 'unlock') {
        content = ServerFlowFrame(
          title: target!.displayName,
          onBack: back,
          child: ServerUnlockForm(
            onSubmit: submitPassword,
            retryAt: widget.auth.serverAccess.retryAt(target!.id),
            unavailable: widget.auth.serverAccess.isUnavailable(target!.id),
            error: unlockError,
            busy: unlockBusy,
          ),
        );
      } else if (step == 'remove') {
        content = ServerFlowFrame(
          title: l.serversRemove,
          onBack: back,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(target!.displayName, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Text(l.serversRemoveHint),
              if (widget.auth.session?.server.id == target!.id)
                ServerFeedback(l.serversCurrentImpact, error: false),
              if (errors[target!.id] != null)
                ServerFeedback(errors[target!.id]!),
              const SizedBox(height: 24),
              AppButton(
                key: const Key('server-remove-confirm'),
                onPressed: pending.contains(target!.id) ? null : remove,
                foregroundColor: theme.colorScheme.error,
                variant: AppButtonVariant.tinted,
                child: Text(l.serversRemove),
              ),
              const SizedBox(height: 12),
              AppButton(
                key: const Key('server-remove-cancel'),
                onPressed: back,
                child: Text(l.serversCancel),
              ),
            ],
          ),
        );
      } else {
        final query = search.text.trim().toLowerCase();
        final all = widget.auth.savedServers;
        final filtered = all
            .where(
              (s) =>
                  s.displayName.toLowerCase().contains(query) ||
                  (!widget.auth.serverAccess.isProtected(s.id) ||
                          widget.auth.serverAccess.allows(s.id)) &&
                      s.lines.any(
                        (line) =>
                            serverSafeAddress(line.address)
                                .toLowerCase()
                                .contains(query),
                      ),
            )
            .toList();
        content = ServerFlowFrame(
          title: l.serversTitle,
          onBack: back,
          backLabel: l.serversDismiss,
          scroll: false,
          action: AppButton.icon(
            key: const Key('server-add'),
            onPressed: () => setState(() => step = 'add'),
            icon: const Icon(AppIcons.add, size: 18),
            label: Text(l.addServer),
            variant: AppButtonVariant.filled,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: AppTextField(
                  key: const Key('server-search'),
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  placeholder: l.serversSearch,
                  textInputAction: TextInputAction.search,
                  prefix: const Icon(AppIcons.search),
                  suffix: query.isEmpty
                      ? null
                      : AppIconButton(
                          tooltip: l.serversClearSearch,
                          onPressed: () => setState(() => search.clear()),
                          icon: const Icon(AppIcons.close),
                        ),
                ),
              ),
              Expanded(
                child: !ready
                    ? const Center(child: AppLoadingBar())
                    : filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                query.isEmpty
                                    ? AppIcons.library
                                    : AppIcons.search,
                                size: 44,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                query.isEmpty
                                    ? l.serversEmptyTitle
                                    : l.serversNoResults,
                              ),
                              const SizedBox(height: 8),
                              if (query.isEmpty)
                                Text(
                                  l.serversEmptyHint,
                                  textAlign: TextAlign.center,
                                ),
                              if (query.isNotEmpty)
                                AppButton(
                                  onPressed: () =>
                                      setState(() => search.clear()),
                                  child: Text(l.serversClearSearch),
                                ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        itemCount: filtered.length,
                        itemBuilder: (_, index) {
                          final server = filtered[index];
                          final position = all.indexOf(server);
                          return KeyedSubtree(
                            key: itemKeys.putIfAbsent(
                              server.id,
                              () => GlobalKey(),
                            ),
                            child: ServerSelectionTile(
                              server: server,
                              focusNode: itemFocus.putIfAbsent(
                                server.id,
                                () => FocusNode(),
                              ),
                              current:
                                  widget.auth.session?.server.id == server.id,
                              locked: !widget.auth.serverAccess.allows(
                                server.id,
                              ),
                              busy: pending.contains(server.id),
                              error: errors[server.id],
                              canMoveUp: position > 0,
                              canMoveDown: position < all.length - 1,
                              onEnter: () => enter(server),
                              onLines: () => open(server, 'lines'),
                              onAction: (value) => action(server, value),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      }
      final viewport = MediaQuery.sizeOf(context);
      return PopScope(
        canPop: step == 'list',
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) back();
        },
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.phone ? 0 : 24,
              widget.phone ? 0 : 24,
              widget.phone ? 0 : 24,
              (widget.phone ? 0 : 24) + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Center(
              child: SizedBox(
                width: widget.phone ? viewport.width : 600,
                height: widget.phone ? double.infinity : 760,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(widget.phone ? 0 : 20),
                    border: widget.phone
                        ? null
                        : Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.phone ? 0 : 20),
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
