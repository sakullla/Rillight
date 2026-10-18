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
import 'login_widgets.dart';
import 'server_password_form.dart';
import 'server_ui.dart';

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
    } else if (step == 'account' || step == 'homeAccount') {
      title = l.serversAccount;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversChangeAccountHint),
          const SizedBox(height: 20),
          ProviderConnectDialog(
            auth: widget.auth,
            home: step == 'homeAccount',
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
      final current = widget.auth.session?.server.id == widget.server.id;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const AppLoadingBar(),
          if (error != null) ServerFeedback(error!),
          ServerIdentityCard(
            server: widget.server.copyWith(nickname: name.text, iconId: icon),
            subtitle:
                '${widget.server.serviceType.label} · ${(needsLogin ? l.serversNoAccount : widget.server.username)}',
            trailing: current
                ? ServerStatusPill(
                    label: l.serversCurrent,
                    tone: ServerTone.current,
                    icon: AppIcons.checkCircle,
                  )
                : null,
          ),
          const SizedBox(height: 14),
          ServerSectionCard(
            title: l.serversBasic,
            icon: AppIcons.edit,
            description: l.serversBasicSummary,
            children: [
              AppTextField(
                key: const Key('server-editor-name'),
                controller: name,
                label: l.serversName,
                maxLength: 80,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 10),
              Text(
                l.serversIcon,
                style: AppUiTheme.of(context).textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 9),
              Wrap(
                key: const Key('server-editor-icon'),
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final option in const [
                    ('default', 'serversIconDefault'),
                    ('home', 'serversIconHome'),
                    ('cinema', 'serversIconCinema'),
                    ('cloud', 'serversIconCloud'),
                  ])
                    _ServerIconChoice(
                      type: widget.server.serviceType,
                      iconId: option.$1 == 'default' ? null : option.$1,
                      label: _iconLabel(l, option.$2),
                      selected: icon == option.$1,
                      onTap: busy
                          ? null
                          : () => setState(() => icon = option.$1),
                    ),
                ],
              ),
            ],
          ),
          ServerSectionCard(
            title: l.serversAccountStatus,
            icon: AppIcons.person,
            trailing: needsLogin
                ? null
                : ServerStatusPill(
                    label: l.serversLoggedIn,
                    tone: ServerTone.success,
                  ),
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppUiTheme.of(context).colorScheme.primary
                          .withValues(alpha: .12),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      needsLogin
                          ? '?'
                          : widget.server.username.isEmpty
                          ? '?'
                          : widget.server.username
                                .substring(0, 1)
                                .toUpperCase(),
                      style: AppUiTheme.of(context).textTheme.titleMedium
                          ?.copyWith(
                            color: AppUiTheme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          needsLogin
                              ? l.serversNoAccount
                              : widget.auth.savedServers
                                        .where((s) => s.id == widget.server.id)
                                        .firstOrNull
                                        ?.username ??
                                    widget.server.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppUiTheme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          needsLogin
                              ? l.serversReauthorize
                              : l.serversChangeAccountHint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppUiTheme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppUiTheme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton(
                    key: const Key('server-editor-account'),
                    onPressed: busy
                        ? null
                        : () => setState(() => step = 'account'),
                    variant: AppButtonVariant.tinted,
                    child: Text(
                      needsLogin ? l.serversLoginAction : l.serversReauthorize,
                    ),
                  ),
                  if (widget.server.serviceType == MediaServerType.plex &&
                      !needsLogin)
                    AppButton(
                      key: const Key('server-editor-home-account'),
                      onPressed: busy
                          ? null
                          : () => setState(() => step = 'homeAccount'),
                      child: Text(l.providerHomeManage),
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
          ServerSectionCard(
            title: l.serversLines,
            icon: AppIcons.link,
            description: l.serversLinesSummary,
            trailing: ServerStatusPill(
              label: l.serversLineCount(lines.length),
              tone: ServerTone.neutral,
            ),
            children: [
              for (var i = 0; i < lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppSurfaceAction(
                          key: Key('server-editor-line-${lines[i].id}'),
                          onTap: busy
                              ? null
                              : () => setState(() {
                                  editing = lines[i];
                                  step = 'line';
                                }),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                            decoration: BoxDecoration(
                              color: AppUiTheme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: .38),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppUiTheme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: .12),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Text(
                                    '${i + 1}',
                                    style: AppUiTheme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: AppUiTheme.of(context)
                                              .colorScheme
                                              .primary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              serverLineLabel(lines[i]),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppUiTheme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                          if (lines[i].id ==
                                              widget.server.activeLine?.id) ...[
                                            const SizedBox(width: 7),
                                            ServerStatusPill(
                                              label: l.serversLineActual,
                                              tone: ServerTone.current,
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        serverSafeAddress(lines[i].address),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppUiTheme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: AppUiTheme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  AppIcons.edit,
                                  size: 17,
                                  color: AppUiTheme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
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
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Icon(
                            AppIcons.more,
                            size: 19,
                            color: AppUiTheme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              AppButton.icon(
                key: const Key('server-editor-add-line'),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        editing = null;
                        step = 'line';
                      }),
                variant: AppButtonVariant.outlined,
                icon: const Icon(AppIcons.add, size: 18),
                label: Text(l.serversLineAdd),
              ),
            ],
          ),
          ServerSectionCard(
            title: l.serversProtection,
            icon: AppIcons.shield,
            description: l.serversProtectionSummary,
            children: [
              AppListTile(
                key: const Key('server-editor-password'),
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color:
                        (protected
                                ? AppUiTheme.of(context).colorScheme.primary
                                : AppUiTheme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)
                            .withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    protected ? AppIcons.lock : AppIcons.lockOpen,
                    size: 19,
                    color: protected
                        ? AppUiTheme.of(context).colorScheme.primary
                        : AppUiTheme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                title: Text(
                  password != null
                      ? l.serversPasswordPending
                      : protected
                      ? l.serversPasswordOn
                      : l.serversPasswordOff,
                ),
                subtitle: Text(l.serversPasswordHint),
                trailing: const Icon(AppIcons.chevronRight),
                onTap: busy ? null : () => setState(() => step = 'password'),
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color:
                  AppUiTheme.of(context).colorScheme.brightness ==
                      Brightness.dark
                  ? AppUiTheme.of(context).colorScheme.surfaceContainer
                  : AppUiTheme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(ServerUi.cardRadius),
              border: Border.all(
                color: AppUiTheme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                AppListTile(
                  key: const Key('server-editor-advanced'),
                  leading: const Icon(AppIcons.tune, size: 20),
                  title: Text(l.serversAdvanced),
                  subtitle: Text(l.serversAdvancedSummary),
                  trailing: Icon(
                    advanced ? AppIcons.chevronUp : AppIcons.chevronDown,
                  ),
                  onTap: () => setState(() => advanced = !advanced),
                ),
                if (advanced)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: AppTextField(
                      key: const Key('server-editor-user-agent'),
                      controller: userAgent,
                      label: l.userAgent,
                      placeholder: l.userAgentHint,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return ServerFlowFrame(
      title: title,
      subtitle: step == 'main' ? l.serversEditorSubtitle : null,
      onBack: back,
      action: action,
      child: body,
    );
  }
}

String _iconLabel(AppLocalizations l, String key) => switch (key) {
  'serversIconHome' => l.serversIconHome,
  'serversIconCinema' => l.serversIconCinema,
  'serversIconCloud' => l.serversIconCloud,
  _ => l.serversIconDefault,
};

class _ServerIconChoice extends StatelessWidget {
  const _ServerIconChoice({
    required this.type,
    required this.iconId,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final MediaServerType type;
  final String? iconId;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    return AppSurfaceAction(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        width: 68,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected
              ? colors.primary.withValues(alpha: .10)
              : colors.surfaceContainerHighest.withValues(alpha: .28),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: .58)
                : colors.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ServerIdentityBadge(type: type, iconId: iconId, size: 38),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected ? colors.primary : colors.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
