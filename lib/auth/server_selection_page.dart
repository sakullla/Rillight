import 'server_entry_coordinator.dart';

import 'dart:async';

import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../player/player_bindings.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/capabilities.dart';
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
import 'server_ui.dart';

Future<void> showServerSelection(
  BuildContext context, {
  required AuthController auth,
  bool phone = false,
  String? initialServerId,
  Future<void> Function()? onEntered,
  Future<void> Function()? onLineChanged,
  Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry,
}) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ServerSelectionPage(
    auth: auth,
    phone: phone,
    initialServerId: initialServerId,
    onEntered: onEntered,
    onLineChanged: onLineChanged,
    validateEntry: validateEntry,
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
    this.routePage = false,
    this.initialServerId,
    this.onEntered,
    this.onLineChanged,
    this.validateEntry,
  });
  final Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry;
  final AuthController auth;
  final bool phone;
  final bool routePage;
  final String? initialServerId;
  final Future<void> Function()? onEntered, onLineChanged;
  @override
  State<ServerSelectionPage> createState() => ServerSelectionPageState();
}

class ServerSelectionPageState extends State<ServerSelectionPage> {
  final search = TextEditingController();
  final scroll = ScrollController();
  final Map<String, String> errors = {};
  final Set<String> pending = {};
  final Map<String, GlobalKey> itemKeys = {};
  final Map<String, FocusNode> itemFocus = {};
  final editorKey = GlobalKey<ServerEditorState>();
  final addKey = GlobalKey<ServerAddPanelState>();
  int entryRevision = 0;
  String? pendingEntry;
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
      await widget.auth.refreshAuthorization(server.id);
    }
    if (mounted) setState(() => ready = true);
    final initial = widget.auth.savedServers
        .where((server) => server.id == widget.initialServerId)
        .firstOrNull;
    if (mounted && initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(enter(initial));
      });
    }
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
    cancelEntry();
    if (step == 'list') {
      closeSelection();
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

  void cancelEntry() {
    entryRevision++;
    widget.auth.serverEntry.cancel();
    if (password?.isCompleted == false) password!.complete(null);
    if (pendingEntry != null) pending.remove(pendingEntry);
    pendingEntry = null;
  }

  void showFlow(String next, {SavedServer? server}) {
    cancelEntry();
    setState(() {
      target = server;
      step = next;
      unlockBusy = false;
      unlockError = null;
    });
  }

  Future<void> finishEntry() async {
    final onEntered = widget.onEntered;
    closeSelection();
    await onEntered?.call();
  }

  void closeSelection() {
    if (widget.routePage) {
      GoRouter.of(context).go(AppRoutes.home);
    } else {
      Navigator.of(context).pop();
    }
  }

  void open(SavedServer server, String next) {
    if (!widget.auth.serverAccess.allows(server.id)) {
      unawaited(enter(server, next: next));
      return;
    }
    showFlow(next, server: server);
  }

  Future<void> enter(
    SavedServer server, {
    String next = 'enter',
    String? suppliedPassword,
    bool playbackConfirmed = false,
  }) async {
    final l = AppLocalizations.of(context);
    final current = widget.auth.session?.server.id;
    final bindings = PlayerScope.of(context);
    if (next == 'enter' &&
        suppliedPassword == null &&
        !playbackConfirmed &&
        current != null &&
        current != server.id &&
        widget.auth.serverAccess.isProtected(current) &&
        (bindings.runtime?.hasPlaybackFor(current) == true ||
            (bindings.windowHost?.playbackOccupied == true &&
                (bindings.windowHost?.current?.source == null ||
                    bindings
                            .windowHost
                            ?.current
                            ?.source
                            ?.account
                            .configuredServerId ==
                        current)))) {
      cancelEntry();
      setState(() {
        target = server;
        step = 'confirm-entry';
      });
      return;
    }
    cancelEntry();
    final revision = entryRevision;
    var passwordRejected = false;
    target = server;
    pendingEntry = server.id;
    destination = next;
    setState(() {
      pending.add(server.id);
      errors.remove(server.id);
      unlockError = null;
    });
    try {
      Future<String?> requestPassword() {
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
      }

      Future<bool> connect(void Function() guard) async {
        guard();
        final prepared = await widget.auth.prepareServerEntry(
          server.id,
          guard: guard,
        );
        guard();
        return prepared;
      }

      Future<void> navigate(String value) async {
        if (!mounted) return;
        if (value == 'enter') {
          await finishEntry();
        } else {
          setState(() {
            step = value;
            unlockBusy = false;
          });
        }
      }

      final succeeded = next == 'enter'
          ? await widget.auth.serverEntry.enter<String>(
              server: server,
              destination: next,
              requestPassword: requestPassword,
              connect: connect,
              validate: widget.validateEntry == null
                  ? null
                  : (ticket) => widget.validateEntry!(server.id, ticket),
              navigate: navigate,
              onPasswordRejected: () => passwordRejected = true,
            )
          : await widget.auth.serverEntry.authorizeManagement<String>(
              server: server,
              destination: next,
              requestPassword: requestPassword,
              navigate: navigate,
              onPasswordRejected: () => passwordRejected = true,
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
      if (mounted && revision == entryRevision) {
        setState(() {
          pending.remove(server.id);
          pendingEntry = null;
        });
      }
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
      showFlow('remove', server: server);
      return;
    }
    cancelEntry();
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
      final colors = theme.colorScheme;
      Widget content;
      if (step == 'edit') {
        content = ServerEditor(
          key: editorKey,
          auth: widget.auth,
          server: target!,
          onBack: returnToList,
          onSaved: returnToList,
          onSignedOut: closeSelection,
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
              await finishEntry();
            }
          },
          onImport: () {
            // Replace this flow before opening the existing file-import route.
            final outer = Navigator.of(context).context;
            closeSelection();
            unawaited(showBackupImportFlow(outer, auth: widget.auth));
          },
        );
      } else if (step == 'login') {
        content = ServerFlowFrame(
          title: l.serversAccount,
          subtitle: target!.displayName,
          onBack: back,
          child: ProviderConnectDialog(
            auth: widget.auth,
            existing: target,
            inline: true,
            onConnected: () => enter(widget.auth.sources.server(target!.id)),
          ),
        );
      } else if (step == 'confirm-entry') {
        content = ServerFlowFrame(
          title: target!.displayName,
          onBack: back,
          child: ServerFocusView(
            mark: ServerMarkWithGlyph(
              server: target!,
              glyph: AppIcons.swap,
              tone: ServerTone.warning,
            ),
            title: l.serversEnterOtherTitle,
            message: l.serversEntryPlaybackImpact,
            children: [
              ServerDecisionButtons(
                confirmKey: const Key('server-entry-continue'),
                confirmLabel: l.serversContinue,
                onConfirm: () => enter(target!, playbackConfirmed: true),
                cancelLabel: l.serversCancel,
                onCancel: back,
              ),
            ],
          ),
        );
      } else if (step == 'unlock') {
        content = ServerFlowFrame(
          title: target!.displayName,
          subtitle: l.serversPassword,
          onBack: back,
          child: ServerUnlockForm(
            mark: ServerMarkWithGlyph(server: target!, glyph: AppIcons.lock),
            onSubmit: submitPassword,
            retryAt: widget.auth.serverAccess.retryAt(target!.id),
            unavailable: widget.auth.serverAccess.isUnavailable(target!.id),
            error: unlockError,
            busy: unlockBusy,
          ),
        );
      } else if (step == 'remove') {
        final current = widget.auth.session?.server.id == target!.id;
        content = ServerFlowFrame(
          title: l.serversRemove,
          onBack: back,
          child: ServerFocusView(
            mark: ServerMarkWithGlyph(
              server: target!,
              glyph: AppIcons.delete,
              tone: ServerTone.error,
            ),
            title: l.serversRemoveTitle,
            message: '${target!.displayName}\n${l.serversRemoveHint}',
            children: [
              if (current)
                ServerFeedbackCard(l.serversCurrentImpact, error: false),
              if (errors[target!.id] != null)
                ServerFeedbackCard(errors[target!.id]!),
              const SizedBox(height: 18),
              ServerDecisionButtons(
                confirmKey: const Key('server-remove-confirm'),
                cancelKey: const Key('server-remove-cancel'),
                confirmLabel: l.serversRemove,
                onConfirm: pending.contains(target!.id) ? null : remove,
                cancelLabel: l.serversCancel,
                onCancel: back,
                destructive: true,
                busy: pending.contains(target!.id),
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
        final shrink = !widget.phone;
        final pad = widget.phone ? 16.0 : 22.0;
        final Widget results = !ready
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CupertinoActivityIndicator()),
              )
            : filtered.isEmpty
            ? _ServerEmptyState(
                query: query,
                onAdd: () => showFlow('add'),
                onClear: () => setState(() => search.clear()),
              )
            : CupertinoScrollbar(
                controller: scroll,
                child: ListView.builder(
                  controller: scroll,
                  shrinkWrap: shrink,
                  padding: EdgeInsets.fromLTRB(pad, 2, pad, pad),
                  itemCount: filtered.length,
                  itemBuilder: (_, index) {
                    final server = filtered[index];
                    final position = all.indexOf(server);
                    return KeyedSubtree(
                      key: itemKeys.putIfAbsent(server.id, () => GlobalKey()),
                      child: ServerSelectionTile(
                        server: server,
                        needsLogin:
                            widget.auth.hasSavedAuthorization(server.id) ==
                            false,
                        focusNode: itemFocus.putIfAbsent(
                          server.id,
                          () => FocusNode(),
                        ),
                        current: widget.auth.session?.server.id == server.id,
                        locked: !widget.auth.serverAccess.allows(server.id),
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
              );
        content = ServerFlowFrame(
          title: l.serversTitle,
          subtitle: all.isEmpty
              ? l.serversSubtitle
              : l.serversHubSubtitle(all.length),
          onBack: back,
          backLabel: l.serversDismiss,
          dismissible: true,
          scroll: false,
          // 添加服务器是这个视图唯一的主操作。
          action: AppActionButton(
            key: const Key('server-add'),
            tier: AppActionTier.primary,
            onPressed: () => showFlow('add'),
            icon: AppIcons.add,
            label: widget.phone ? l.serversAddShort : l.addServer,
            semanticLabel: l.addServer,
          ),
          child: Column(
            mainAxisSize: shrink ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (all.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, 4, pad, 12),
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
              if (ready && query.isNotEmpty && filtered.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(pad + 4, 0, pad + 4, 8),
                  child: Text(
                    '${l.serversSearchResults} · ${l.serversCount(filtered.length)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (shrink)
                Flexible(child: results)
              else
                Expanded(child: results),
            ],
          ),
        );
      }
      final viewport = MediaQuery.sizeOf(context);
      final panel = ServerPanelScope(
        shrinkWrap: !widget.phone,
        compact: widget.phone,
        child: content,
      );
      return PopScope(
        canPop: step == 'list',
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) back();
        },
        child: widget.phone
            ? SafeArea(
                child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: SizedBox(width: viewport.width, child: panel),
                  ),
                ),
              )
            : Stack(
                children: [
                  Positioned.fill(
                    child: ServerScrim(
                      onTap: step == 'list' ? closeSelection : null,
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        24,
                        24,
                        24 + MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: ServerUi.panelWidth,
                            maxHeight: (viewport.height - 48).clamp(
                              320.0,
                              ServerUi.panelHeight,
                            ),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color.alphaBlend(
                                colors.primary.withValues(alpha: .025),
                                colors.surfaceContainerLow,
                              ),
                              borderRadius: BorderRadius.circular(
                                ServerUi.panelRadius,
                              ),
                              border: Border.all(
                                color: colors.outlineVariant.withValues(
                                  alpha: .78,
                                ),
                                width: .85,
                              ),
                              boxShadow: AppShadow.overlay(colors.brightness),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                ServerUi.panelRadius,
                              ),
                              child: AnimatedSize(
                                duration: AppMotion.durationOf(
                                  context,
                                  AppMotion.normal,
                                ),
                                curve: AppMotion.standard,
                                alignment: Alignment.topCenter,
                                child: panel,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );
    },
  );
}

class _ServerEmptyState extends StatelessWidget {
  const _ServerEmptyState({
    required this.query,
    required this.onAdd,
    required this.onClear,
  });

  final String query;
  final VoidCallback onAdd, onClear;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final empty = query.isEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (empty)
              // Three provider marks fanned out: what can be added, at a glance.
              SizedBox(
                width: 132,
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    for (final (index, type) in const [
                      (0, MediaServerType.jellyfin),
                      (2, MediaServerType.plex),
                      (1, MediaServerType.emby),
                    ])
                      Positioned(
                        left: index * 38.0,
                        top: index == 1 ? 0 : 10,
                        child: Transform.rotate(
                          angle: (index - 1) * .14,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: ServerUi.groupColor(colors),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: AppShadow.cardHover(colors.brightness),
                            ),
                            child: ServerIdentityBadge(type: type, size: 54),
                          ),
                        ),
                      ),
                  ],
                ),
              )
            else
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.onSurface.withValues(alpha: .06),
                ),
                child: Icon(
                  AppIcons.search,
                  size: 28,
                  color: colors.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              empty ? l.serversEmptyTitle : l.serversNoResults,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              empty ? l.serversEmptyHint : l.serversNoResultsHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            // 顶栏已有主操作「添加服务器」,空态按钮降为次级,一屏只有一个 primary。
            if (empty)
              AppActionButton(
                key: const Key('server-empty-add'),
                onPressed: onAdd,
                icon: AppIcons.add,
                label: l.addServer,
              )
            else
              AppActionButton(
                key: const Key('server-empty-clear'),
                onPressed: onClear,
                icon: AppIcons.close,
                label: l.serversClearSearch,
              ),
          ],
        ),
      ),
    );
  }
}
