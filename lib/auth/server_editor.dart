import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'change_password_dialog.dart';
import '../player/player_window_host.dart';
import '../media_server/capabilities.dart';
import 'provider_connect_dialog.dart';
import 'server_flow_frame.dart';
import 'server_line_fields.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'server_password_form.dart';

class ServerEditor extends StatefulWidget {
  const ServerEditor({
    super.key,
    required this.auth,
    required this.server,
    required this.onBack,
    required this.onSaved,
    this.onSignedOut,
  });
  final AuthController auth;
  final SavedServer server;
  final VoidCallback onBack, onSaved;
  final VoidCallback? onSignedOut;
  @override
  State<ServerEditor> createState() => ServerEditorState();
}

class ServerEditorState extends State<ServerEditor> {
  final name = TextEditingController(), userAgent = TextEditingController();
  late List<ServerLine> lines;
  late String icon;
  String step = 'main';
  ServerLine? editing;
  ServerPasswordDraft? password;
  bool busy = false, advanced = false;
  String? error;
  @override
  void initState() {
    super.initState();
    name.text = widget.server.displayName;
    userAgent.text = widget.server.userAgent ?? '';
    lines = List.of(widget.server.lines);
    icon = widget.server.iconId ?? 'default';
  }

  @override
  void dispose() {
    name.dispose();
    userAgent.dispose();
    super.dispose();
  }

  void back() {
    if (busy) return;
    if (step == 'main') {
      widget.onBack();
    } else {
      setState(() {
        step = 'main';
        error = null;
      });
    }
  }

  bool get connectionChanges {
    final active = widget.server.activeLine;
    return widget.auth.session?.server.id == widget.server.id &&
        (userAgent.text.trim() != (widget.server.userAgent ?? '').trim() ||
            lines.where((l) => l.id == active?.id).firstOrNull?.address !=
                active?.address);
  }

  Future<void> save({bool confirmed = false}) async {
    if (name.text.trim().isEmpty) {
      setState(() => error = AppLocalizations.of(context).serversInvalidDraft);
      return;
    }
    if (connectionChanges && !confirmed) {
      setState(() => step = 'impact');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      Future<void> persist([String? reference]) =>
          widget.auth.saveConfiguration(
            widget.server.id,
            nickname: name.text,
            iconId: icon,
            userAgent: userAgent.text,
            lines: lines,
            protectionRef: reference,
          );
      final change = password;
      if (change == null) {
        await persist();
      } else if (change.enabled) {
        await widget.auth.serverAccess.setPassword(
          widget.server.id,
          change.password,
          change.confirmation,
          oldPassword: change.oldPassword,
          persistReference: persist,
        );
      } else {
        await widget.auth.serverAccess.disablePassword(
          widget.server.id,
          change.oldPassword,
          persistReference: persist,
        );
      }
      if (mounted) widget.onSaved();
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = password != null
              ? AppLocalizations.of(context).serversPasswordSaveFailed
              : serverOperationFailure(AppLocalizations.of(context), failure);
          step = 'main';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Account mutation is shared by desktop, phone and TV presentations.
  Future<void> signOut() async {
    final l = AppLocalizations.of(context);
    setState(() => busy = true);
    try {
      if (widget.auth.session?.server.id == widget.server.id) {
        await PlayerWindowScope.maybeOf(context)?.close();
        await widget.auth.logout();
      } else {
        await widget.auth.sources.logoutSource(widget.server.id);
      }
      await widget.auth.refreshServers();
      if (mounted) (widget.onSignedOut ?? widget.onSaved)();
    } catch (failure) {
      if (mounted) setState(() => error = serverOperationFailure(l, failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void move(int index, int delta) {
    setState(() {
      final value = lines.removeAt(index);
      lines.insert(index + delta, value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final protected = widget.auth.serverAccess.isProtected(widget.server.id);
    final needsLogin =
        widget.auth.hasSavedAuthorization(widget.server.id) == false;
    Widget body;
    var title = l.serversEdit;
    Widget? action;
    if (step == 'line') {
      title = editing == null ? l.serversLineAdd : l.serversLineEdit;
      body = ServerLineFields(
        key: ValueKey(editing?.id ?? 'new'),
        line: editing,
        otherLines: lines,
        onDone: (value) => setState(() {
          final index = lines.indexWhere((line) => line.id == value.id);
          if (index < 0) {
            lines.add(value);
          } else {
            lines[index] = value;
          }
          step = 'main';
        }),
      );
    } else if (step == 'password') {
      title = protected ? l.serversPasswordChange : l.serversPasswordSet;
      body = ServerPasswordFields(
        protected: protected,
        initial: password,
        onDone: (value) => setState(() {
          password = value;
          step = 'main';
        }),
      );
    } else if (step == 'account') {
      title = l.serversAccount;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversChangeAccountHint),
          const SizedBox(height: 20),
          ProviderConnectDialog(
            auth: widget.auth,
            existing: widget.auth.sources.server(widget.server.id),
            inline: true,
            onConnected: () => setState(() => step = 'main'),
          ),
        ],
      );
    } else if (step == 'remotePassword') {
      title = l.serversRemotePassword;
      body = ChangePasswordDialog(
        auth: widget.auth,
        inline: true,
        onDone: () => setState(() => step = 'main'),
      );
    } else if (step == 'logout') {
      title = l.serversSignOut;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversSignOutHint),
          const SizedBox(height: 16),
          if (widget.auth.session?.server.id == widget.server.id)
            Text(l.serversCurrentImpact),
          if (error != null) ServerFeedback(error!),
          const SizedBox(height: 24),
          AppButton(
            key: const Key('server-logout-confirm'),
            variant: AppButtonVariant.filled,
            onPressed: busy ? null : signOut,
            child: Text(l.serversSignOut),
          ),
        ],
      );
    } else if (step == 'impact') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ServerFeedback(l.serversConnectionImpact, error: false),
          const SizedBox(height: 20),
          AppButton(
            key: const Key('server-impact-confirm'),
            onPressed: busy ? null : () => save(confirmed: true),
            variant: AppButtonVariant.filled,
            child: Text(l.serversSave),
          ),
        ],
      );
    } else {
      action = AppButton(
        key: const Key('server-editor-save'),
        onPressed: busy ? null : save,
        variant: AppButtonVariant.filled,
        child: Text(l.serversSave),
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const AppLoadingBar(),
          if (error != null) ServerFeedback(error!),
          ServerFormSection(
            title: l.serversBasic,
            children: [
              AppTextField(
                key: const Key('server-editor-name'),
                controller: name,
                label: l.serversName,
                maxLength: 80,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ServerIdentityIcon(widget.server.copyWith(iconId: icon)),
                  const SizedBox(width: 12),
                  Text(l.serversIcon),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppDropdown<String>(
                      key: const Key('server-editor-icon'),
                      value: icon,
                      label: l.serversIcon,
                      items: [
                        AppMenuEntry(
                          value: 'default',
                          child: Text(l.serversIconDefault),
                        ),
                        AppMenuEntry(
                          value: 'home',
                          child: Text(l.serversIconHome),
                        ),
                        AppMenuEntry(
                          value: 'cinema',
                          child: Text(l.serversIconCinema),
                        ),
                        AppMenuEntry(
                          value: 'cloud',
                          child: Text(l.serversIconCloud),
                        ),
                      ],
                      onChanged: busy ? null : (v) => setState(() => icon = v),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ServerFormSection(
            title: l.serversAccount,
            children: [
              Text(
                needsLogin
                    ? l.serversNoAccount
                    : widget.auth.savedServers
                              .where((s) => s.id == widget.server.id)
                              .firstOrNull
                              ?.username ??
                          widget.server.username,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton(
                    key: const Key('server-editor-account'),
                    onPressed: busy
                        ? null
                        : () => setState(() => step = 'account'),
                    child: Text(l.serversReauthorize),
                  ),
                  if (widget.auth.session?.server.id == widget.server.id &&
                      widget
                          .auth
                          .client
                          .capabilities[ServiceCapability.changePassword]
                          .isAvailable)
                    AppButton(
                      key: const Key('server-editor-remote-password'),
                      onPressed: busy
                          ? null
                          : () => setState(() => step = 'remotePassword'),
                      child: Text(l.serversRemotePassword),
                    ),
                  if (!needsLogin)
                    AppButton(
                      key: const Key('server-editor-logout'),
                      onPressed: busy
                          ? null
                          : () => setState(() => step = 'logout'),
                      child: Text(l.serversSignOut),
                    ),
                ],
              ),
            ],
          ),
          ServerFormSection(
            title: l.serversLines,
            children: [
              Text(
                l.serversLinesHint,
                style: AppUiTheme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < lines.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: AppListTile(
                        key: Key('server-editor-line-${lines[i].id}'),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        title: Text(
                          serverLineLabel(lines[i]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          serverSafeAddress(lines[i].address),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: busy
                            ? null
                            : () => setState(() {
                                editing = lines[i];
                                step = 'line';
                              }),
                        trailing: const Icon(AppIcons.edit, size: 20),
                      ),
                    ),
                    AppMenuButton<String>(
                      key: Key('server-editor-line-more-${lines[i].id}'),
                      tooltip: l.serversMore,
                      items: [
                        if (i > 0)
                          AppMenuEntry(value: 'up', child: Text(l.serversUp)),
                        if (i < lines.length - 1)
                          AppMenuEntry(
                            value: 'down',
                            child: Text(l.serversDown),
                          ),
                        if (lines.length > 1)
                          AppMenuEntry(
                            value: 'remove',
                            child: Text(l.serversLineRemove),
                          ),
                      ],
                      onSelected: busy || lines.length == 1
                          ? null
                          : (value) {
                              if (value == 'remove') {
                                setState(() => lines.removeAt(i));
                              } else {
                                move(i, value == 'up' ? -1 : 1);
                              }
                            },
                      child: const Text('•••'),
                    ),
                  ],
                ),
              AppButton.icon(
                key: const Key('server-editor-add-line'),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        editing = null;
                        step = 'line';
                      }),
                icon: const Icon(AppIcons.add),
                label: Text(l.serversLineAdd),
              ),
            ],
          ),
          ServerFormSection(
            title: l.serversPassword,
            children: [
              Text(l.serversPasswordHint),
              const SizedBox(height: 8),
              AppListTile(
                key: const Key('server-editor-password'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.lock),
                title: Text(
                  password != null
                      ? l.serversPasswordPending
                      : protected
                      ? l.serversPasswordOn
                      : l.serversPasswordOff,
                ),
                trailing: const Icon(AppIcons.chevronRight),
                onTap: busy ? null : () => setState(() => step = 'password'),
              ),
            ],
          ),
          AppListTile(
            key: const Key('server-editor-advanced'),
            contentPadding: EdgeInsets.zero,
            title: Text(l.serversAdvanced),
            trailing: Icon(
              advanced ? AppIcons.chevronUp : AppIcons.chevronDown,
            ),
            onTap: () => setState(() => advanced = !advanced),
          ),
          if (advanced)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppTextField(
                key: const Key('server-editor-user-agent'),
                controller: userAgent,
                label: l.userAgent,
                placeholder: l.userAgentHint,
              ),
            ),
        ],
      );
    }
    return ServerFlowFrame(
      title: title,
      onBack: back,
      action: action,
      child: body,
    );
  }
}
