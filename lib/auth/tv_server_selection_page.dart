import 'server_entry_coordinator.dart';

import 'dart:async';

import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'server_selection_page.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'provider_connect_dialog.dart';
import 'backup_import/backup_import_flow.dart';
import 'tv_server_editor_page.dart';
import 'tv_server_add_panel.dart';
import 'tv_line_selection_page.dart';
import 'tv_server_access_page.dart';
import 'tv_server_flow_frame.dart';

Future<void> showTvServerSelection(
  BuildContext context, {
  required AuthController auth,
  String? initialServerId,
  Future<void> Function()? onEntered,
  Future<void> Function()? onLineChanged,
  Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry,
}) => Navigator.of(context).push<void>(
  CupertinoPageRoute(
    builder: (_) => TvServerSelectionPage(
      auth: auth,
      initialServerId: initialServerId,
      onEntered: onEntered,
      onLineChanged: onLineChanged,
      validateEntry: validateEntry,
    ),
  ),
);

/// Remote-specific wide rows and page steps, sharing the same entry intent,
/// access and configuration operations as the other presentations.
class TvServerSelectionPage extends ServerSelectionPage {
  const TvServerSelectionPage({
    super.key,
    required super.auth,
    super.initialServerId,
    super.routePage,
    super.onEntered,
    super.onLineChanged,
    super.validateEntry,
  });
  @override
  State<ServerSelectionPage> createState() => _TvServerSelectionState();
}

class _TvServerSelectionState extends ServerSelectionPageState {
  final actionNodes = <String, FocusNode>{};
  String? origin;
  FocusNode node(String key) =>
      actionNodes.putIfAbsent(key, () => FocusNode(debugLabel: key));
  @override
  void dispose() {
    for (final n in actionNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  void returnToList() {
    super.returnToList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || step != 'list') return;
        final survives =
            origin == 'server-add' ||
            widget.auth.savedServers.any((s) => s.id == target?.id);
        final focus = survives
            ? actionNodes[origin]
            : itemFocus[widget.auth.savedServers.firstOrNull?.id];
        focus?.requestFocus();
        if (focus?.context case final context?) {
          Scrollable.ensureVisible(context, alignment: .5);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void management(SavedServer server, String next, String from) {
    origin = from;
    open(server, next);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.auth, widget.auth.serverAccess]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      Widget content;
      if (step == 'edit') {
        content = TvServerEditorPage(
          key: editorKey,
          auth: widget.auth,
          server: target!,
          onBack: returnToList,
          onSaved: returnToList,
          onSignedOut: closeSelection,
        );
      } else if (step == 'lines') {
        content = TvLineSelectionPage(
          auth: widget.auth,
          serverId: target!.id,
          onBack: back,
          onChanged: widget.onLineChanged,
        );
      } else if (step == 'confirm-entry') {
        content = TvServerFlowFrame(
          title: target!.displayName,
          onBack: back,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.serversEntryPlaybackImpact),
              const SizedBox(height: 24),
              TvAction(
                key: const Key('server-entry-continue'),
                autofocus: true,
                onPressed: () => enter(target!, playbackConfirmed: true),
                child: Text(l.serversContinue),
              ),
              const SizedBox(height: 16),
              TvAction(onPressed: back, child: Text(l.serversCancel)),
            ],
          ),
        );
      } else if (step == 'unlock') {
        content = TvServerFlowFrame(
          title: target!.displayName,
          onBack: back,
          child: TvServerUnlockForm(
            onSubmit: submitPassword,
            retryAt: widget.auth.serverAccess.retryAt(target!.id),
            unavailable: widget.auth.serverAccess.isUnavailable(target!.id),
            error: unlockError,
            busy: unlockBusy,
          ),
        );
      } else if (step == 'add') {
        content = TvServerAddPanel(
          key: addKey,
          auth: widget.auth,
          onBack: returnToList,
          onConnected: () async {
            await register();
            if (mounted) await finishEntry();
          },
          onImport: () {
            final outer = Navigator.of(context).context;
            closeSelection();
            unawaited(showBackupImportFlow(outer, auth: widget.auth));
          },
        );
      } else if (step == 'login') {
        content = TvServerFlowFrame(
          title: l.serversAccount,
          onBack: returnToList,
          child: ProviderConnectDialog(
            auth: widget.auth,
            existing: target,
            inline: true,
            onConnected: () async {
              await register();
              if (mounted) await enter(widget.auth.sources.server(target!.id));
            },
          ),
        );
      } else if (step == 'more') {
        final all = widget.auth.savedServers;
        final index = all.indexWhere((s) => s.id == target!.id);
        content = TvServerFlowFrame(
          title: target!.displayName,
          onBack: back,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TvNavTile(
                actionKey: const Key('server-more-edit'),
                autofocus: true,
                icon: AppIcons.edit,
                title: l.serversEdit,
                onPressed: () => management(target!, 'edit', origin!),
              ),
              const SizedBox(height: 12),
              if (index > 0)
                TvNavTile(
                  actionKey: const Key('server-more-up'),
                  icon: AppIcons.chevronUp,
                  title: l.serversUp,
                  onPressed: pending.contains(target!.id)
                      ? null
                      : () async {
                          await action(target!, 'up');
                          if (mounted) returnToList();
                        },
                ),
              const SizedBox(height: 12),
              if (index < all.length - 1)
                TvNavTile(
                  actionKey: const Key('server-more-down'),
                  icon: AppIcons.chevronDown,
                  title: l.serversDown,
                  onPressed: pending.contains(target!.id)
                      ? null
                      : () async {
                          await action(target!, 'down');
                          if (mounted) returnToList();
                        },
                ),
              const SizedBox(height: 12),
              TvNavTile(
                actionKey: const Key('server-more-remove'),
                icon: AppIcons.delete,
                title: l.serversRemove,
                destructive: true,
                onPressed: () => showFlow('remove', server: target),
              ),
            ],
          ),
        );
      } else if (step == 'remove') {
        content = TvServerFlowFrame(
          title: l.serversRemove,
          onBack: back,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(target!.displayName),
              const SizedBox(height: 20),
              Text(l.serversRemoveHint),
              if (widget.auth.session?.server.id == target!.id)
                ServerFeedback(l.serversCurrentImpact, error: false),
              if (errors[target!.id] != null)
                ServerFeedback(errors[target!.id]!),
              const SizedBox(height: 24),
              Row(
                children: [
                  TvAction(
                    key: const Key('server-remove-cancel'),
                    autofocus: true,
                    onPressed: back,
                    child: Text(l.serversCancel),
                  ),
                  const SizedBox(width: 20),
                  TvAction(
                    key: const Key('server-remove-confirm'),
                    onPressed: pending.contains(target!.id) ? null : remove,
                    child: Text(l.serversRemove),
                  ),
                ],
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
                  widget.auth.serverAccess.allows(s.id) &&
                      s.lines.any(
                        (line) =>
                            serverSafeAddress(line.address)
                                .toLowerCase()
                                .contains(query),
                      ),
            )
            .toList();
        content = TvServerFlowFrame(
          title: l.serversTitle,
          onBack: back,
          scroll: false,
          action: TvAction(
            key: const Key('server-add'),
            emphasized: true,
            onPressed: () {
              origin = 'server-add';
              showFlow('add');
            },
            focusNode: node('server-add'),
            leading: const Icon(AppIcons.add),
            child: Text(l.addServer),
          ),
          child: ListView(
            controller: scroll,
            padding: TvFrame.contentPadding(context),
            children: [
              Row(
                children: [
                  Expanded(
                    child: TvInput(
                      key: const Key('server-search'),
                      label: l.serversSearch,
                      controller: search,
                      pill: true,
                      leading: const Icon(AppIcons.search),
                      onSubmitted: () => setState(() {}),
                    ),
                  ),
                  if (query.isNotEmpty) ...[
                    const SizedBox(width: 20),
                    TvAction(
                      key: const Key('server-search-clear'),
                      onPressed: () => setState(search.clear),
                      child: Text(l.serversClearSearch),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              if (!ready) const AppLoadingBar(),
              if (ready && filtered.isEmpty) ...[
                Text(query.isEmpty ? l.serversEmptyTitle : l.serversNoResults),
                if (query.isEmpty) Text(l.serversEmptyHint),
              ],
              for (final server in filtered)
                Padding(
                  key: itemKeys.putIfAbsent(server.id, () => GlobalKey()),
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TvAction(
                              key: Key('server-enter-${server.id}'),
                              autofocus: server == filtered.first,
                              focusNode: itemFocus.putIfAbsent(
                                server.id,
                                () => FocusNode(),
                              ),
                              variant: TvActionVariant.tile,
                              leading: ServerIdentityIcon(server),
                              onPressed: pending.contains(server.id)
                                  ? null
                                  : () {
                                      origin = null;
                                      enter(server);
                                    },
                              child: Builder(
                                builder: (context) {
                                  final locked = !widget.auth.serverAccess
                                      .allows(server.id);
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        server.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        locked
                                            ? l.serversLocked
                                            : widget.auth.hasSavedAuthorization(
                                                    server.id,
                                                  ) ==
                                                  false
                                            ? l.serversNoAccount
                                            : '${server.username} · ${serverSafeAddress(server.baseUrl)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: TvAction.secondaryColor(
                                            context,
                                          ),
                                        ),
                                      ),
                                      if (widget.auth.session?.server.id ==
                                          server.id)
                                        Text(l.tvSettingsCurrent),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          SizedBox(
                            width: 204 * TvDesign.scaleOf(context),
                            child: TvAction(
                              key: Key('server-lines-${server.id}'),
                              focusNode: node('server-lines-${server.id}'),
                              onPressed: () => management(
                                server,
                                'lines',
                                'server-lines-${server.id}',
                              ),
                              child: Text(
                                !widget.auth.serverAccess.allows(server.id)
                                    ? l.serversLines
                                    : '${server.lineSelection.isAutomatic ? l.serversAutomatic : l.serversLines} · ${server.activeLine == null ? '—' : serverLineLabel(server.activeLine!)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          TvAction(
                            key: Key('server-more-${server.id}'),
                            focusNode: node('server-more-${server.id}'),
                            onPressed: () {
                              origin = 'server-more-${server.id}';
                              showFlow('more', server: server);
                            },
                            child: Text(l.serversMore),
                          ),
                        ],
                      ),
                      if (errors[server.id] != null)
                        ServerFeedback(errors[server.id]!),
                    ],
                  ),
                ),
            ],
          ),
        );
      }
      return PopScope(
        canPop: step == 'list',
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            back();
          }
        },
        child: content,
      );
    },
  );
}
