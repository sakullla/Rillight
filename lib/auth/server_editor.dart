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
        onCancel: back,
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
      final current = widget.auth.session?.server.id == widget.server.id;
      body = ServerFocusView(
        mark: ServerMarkWithGlyph(
          server: widget.server,
          glyph: AppIcons.logout,
          tone: ServerTone.warning,
        ),
        title: l.serversSignOutTitle,
        message: current
            ? '${l.serversSignOutHint}\n${l.serversCurrentImpact}'
            : l.serversSignOutHint,
        children: [
          if (error != null) ...[
            ServerFeedback(error!),
            const SizedBox(height: 12),
          ],
          ServerDecisionButtons(
            confirmKey: const Key('server-logout-confirm'),
            confirmLabel: l.serversSignOut,
            onConfirm: busy ? null : signOut,
            cancelLabel: l.serversCancel,
            onCancel: back,
            destructive: true,
            busy: busy,
          ),
        ],
      );
    } else if (step == 'impact') {
      body = ServerFocusView(
        mark: ServerMarkWithGlyph(
          server: widget.server,
          glyph: AppIcons.link,
          tone: ServerTone.warning,
        ),
        title: l.serversImpactTitle,
        message: l.serversConnectionImpact,
        children: [
          ServerDecisionButtons(
            confirmKey: const Key('server-impact-confirm'),
            confirmLabel: l.serversSave,
            onConfirm: busy ? null : () => save(confirmed: true),
            cancelLabel: l.serversCancel,
            onCancel: back,
            busy: busy,
          ),
        ],
      );
    } else {
      final theme = AppUiTheme.of(context);
      final colors = theme.colorScheme;
      action = AppButton(
        key: const Key('server-editor-save'),
        onPressed: busy ? null : save,
        variant: AppButtonVariant.filled,
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        style: AppButtonStyle(boxShadow: AppShadow.emphasis(colors.brightness)),
        child: busy
            ? CupertinoActivityIndicator(radius: 8, color: colors.onPrimary)
            : Text(l.serversSave),
      );
      final current = widget.auth.session?.server.id == widget.server.id;
      final username =
          widget.auth.savedServers
              .where((s) => s.id == widget.server.id)
              .firstOrNull
              ?.username ??
          widget.server.username;
      final canChangeRemotePassword =
          current &&
          widget
              .auth
              .client
              .capabilities[ServiceCapability.changePassword]
              .isAvailable;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) ...[
            const AppLoadingBar(minHeight: 2),
            const SizedBox(height: 8),
          ],
          if (error != null) ...[
            ServerFeedback(error!),
            const SizedBox(height: 14),
          ],
          ServerHeroHeader(
            server: widget.server,
            title: name.text,
            iconOverride: icon == 'default' ? '' : icon,
            subtitle: username.isEmpty
                ? widget.server.serviceType.label
                : '${widget.server.serviceType.label} · $username',
            tags: [
              if (current)
                ServerStatusPill(
                  label: l.serversCurrent,
                  tone: ServerTone.current,
                  icon: AppIcons.checkCircle,
                ),
              ServerStatusPill(
                label: needsLogin ? l.serversNoAccount : l.serversLoggedIn,
                tone: needsLogin ? ServerTone.warning : ServerTone.success,
              ),
              if (protected)
                ServerStatusPill(
                  label: l.serversPasswordOn,
                  tone: ServerTone.neutral,
                  icon: AppIcons.lock,
                ),
            ],
          ),
          ServerSectionCard(
            title: l.serversBasic,
            description: l.serversBasicSummary,
            children: [
              AppTextField(
                key: const Key('server-editor-name'),
                controller: name,
                label: l.serversName,
                maxLength: 80,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              Text(
                l.serversIcon,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, box) {
                  // Four options always share one row; each shrinks a little
                  // on a 360dp phone instead of wrapping.
                  final width = ((box.maxWidth - 30) / 4).clamp(56.0, 80.0);
                  return Wrap(
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
                          server: widget.server,
                          name: name.text,
                          iconId: option.$1 == 'default' ? null : option.$1,
                          label: _iconLabel(l, option.$2),
                          selected: icon == option.$1,
                          width: width,
                          onTap: busy
                              ? null
                              : () => setState(() => icon = option.$1),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          ServerGroup(
            title: l.serversAccountSection,
            dividerIndent: 60,
            children: [
              ServerRow(
                leading: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .13),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    username.isEmpty
                        ? '?'
                        : username.substring(0, 1).toUpperCase(),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // State lives once, in the header tags; this row is identity.
                title: Text(username.isEmpty ? '—' : username),
                subtitle: Text(
                  l.serversChangeAccountHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ServerRow(
                key: const Key('server-editor-account'),
                onTap: busy ? null : () => setState(() => step = 'account'),
                leading: const ServerRowIcon(AppIcons.swap),
                title: Text(
                  needsLogin ? l.serversLoginAction : l.serversReauthorize,
                ),
                accent: needsLogin,
                chevron: true,
              ),
              if (widget.server.serviceType == MediaServerType.plex &&
                  !needsLogin)
                ServerRow(
                  key: const Key('server-editor-home-account'),
                  onTap: busy
                      ? null
                      : () => setState(() => step = 'homeAccount'),
                  leading: const ServerRowIcon(AppIcons.group),
                  title: Text(l.providerHomeManage),
                  chevron: true,
                ),
              if (canChangeRemotePassword)
                ServerRow(
                  key: const Key('server-editor-remote-password'),
                  onTap: busy
                      ? null
                      : () => setState(() => step = 'remotePassword'),
                  leading: const ServerRowIcon(AppIcons.badge),
                  title: Text(l.serversRemotePassword),
                  chevron: true,
                ),
              if (!needsLogin)
                ServerRow(
                  key: const Key('server-editor-logout'),
                  onTap: busy ? null : () => setState(() => step = 'logout'),
                  leading: const ServerRowIcon(
                    AppIcons.logout,
                    tone: ServerTone.error,
                  ),
                  title: Text(l.serversSignOut),
                  destructive: true,
                ),
            ],
          ),
          ServerGroup(
            title: l.serversLines,
            description: l.serversLinesSummary,
            trailing: Text(
              l.serversLineCount(lines.length),
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            dividerIndent: 60,
            children: [
              for (var i = 0; i < lines.length; i++)
                ServerRow(
                  key: Key('server-editor-line-${lines[i].id}'),
                  onTap: busy
                      ? null
                      : () => setState(() {
                          editing = lines[i];
                          step = 'line';
                        }),
                  padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                  leading: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: ServerLineLabelText(
                          full: serverLineLabel(lines[i]),
                          compact: serverLineLabel(lines[i], withPort: false),
                        ),
                      ),
                      if (lines[i].id == widget.server.activeLine?.id) ...[
                        const SizedBox(width: 8),
                        ServerStatusPill(
                          label: l.serversLineActual,
                          tone: ServerTone.current,
                        ),
                      ],
                    ],
                  ),
                  subtitle: _LineSubtitle(
                    address: serverSafeAddress(lines[i].address),
                    // 「当前」已由标题旁的标签标出,这里只补自动选择与延迟。
                    marks: serverLineEditorMarks(
                      l,
                      widget.server,
                      lines[i],
                      current: false,
                    ),
                  ),
                  trailing: AppMenuButton<String>(
                    key: Key('server-editor-line-more-${lines[i].id}'),
                    tooltip: l.serversMore,
                    items: [
                      if (i > 0)
                        AppMenuEntry(value: 'up', child: Text(l.serversUp)),
                      if (i < lines.length - 1)
                        AppMenuEntry(value: 'down', child: Text(l.serversDown)),
                      if (lines.length > 1)
                        AppMenuEntry(
                          value: 'remove',
                          child: Text(
                            l.serversLineRemove,
                            style: TextStyle(color: colors.error),
                          ),
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
                      padding: const EdgeInsets.all(10),
                      child: Icon(
                        AppIcons.more,
                        size: 19,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ServerRow(
                key: const Key('server-editor-add-line'),
                onTap: busy
                    ? null
                    : () => setState(() {
                        editing = null;
                        step = 'line';
                      }),
                leading: const ServerRowIcon(AppIcons.add, size: 30),
                title: Text(l.serversLineAdd),
                accent: true,
              ),
            ],
          ),
          ServerGroup(
            title: l.serversProtection,
            description: l.serversProtectionSummary,
            dividerIndent: 60,
            children: [
              ServerRow(
                key: const Key('server-editor-password'),
                onTap: busy ? null : () => setState(() => step = 'password'),
                leading: ServerRowIcon(
                  protected ? AppIcons.lock : AppIcons.lockOpen,
                  tone: protected ? ServerTone.current : ServerTone.neutral,
                ),
                title: Text(l.serversPassword),
                subtitle: Text(
                  password != null
                      ? l.serversPasswordPending
                      : l.serversPasswordHint,
                ),
                trailing: Text(
                  protected ? l.serversPasswordOn : l.serversPasswordOff,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: protected ? colors.primary : colors.onSurfaceVariant,
                    fontWeight: protected ? FontWeight.w600 : null,
                  ),
                ),
                chevron: true,
              ),
            ],
          ),
          ServerGroup(
            margin: EdgeInsets.zero,
            children: [
              ServerRow(
                key: const Key('server-editor-advanced'),
                onTap: () => setState(() => advanced = !advanced),
                leading: const ServerRowIcon(
                  AppIcons.tune,
                  tone: ServerTone.neutral,
                ),
                title: Text(l.serversAdvanced),
                subtitle: Text(l.serversAdvancedSummary),
                trailing: AnimatedRotation(
                  turns: advanced ? .5 : 0,
                  duration: AppMotion.fast,
                  child: Icon(
                    AppIcons.chevronDown,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (advanced)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: AppTextField(
                    key: const Key('server-editor-user-agent'),
                    controller: userAgent,
                    label: l.userAgent,
                    placeholder: l.userAgentHint,
                  ),
                ),
            ],
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

/// Icon option previewed as the real avatar, so the choice is what the list
/// will show.
class _ServerIconChoice extends StatelessWidget {
  const _ServerIconChoice({
    required this.server,
    required this.name,
    required this.iconId,
    required this.label,
    required this.selected,
    required this.onTap,
    this.width = 74,
  });

  final double width;
  final SavedServer server;
  final String name;
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
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: Semantics(
        selected: selected,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: width,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          decoration: selected
              ? AppSelectionDecoration.of(colors, radius: AppRadii.lg)
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: .7),
                    width: .8,
                  ),
                ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ServerAvatar(
                server: server,
                nameOverride: name.trim().isEmpty ? null : name,
                iconOverride: iconId ?? '',
                size: 40,
                showProvider: false,
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 编辑器线路行的副标题:地址与自动选择、延迟等状态标记。
///
/// 地址和标记一行放得下时同行显示;放不下(窄屏手机、大字号)时地址独占
/// 一行(过长省略尾部),标记另起一行并可继续折行,两者都不会被挤没。
class _LineSubtitle extends StatelessWidget {
  const _LineSubtitle({required this.address, required this.marks});
  final String address;
  final List<String> marks;
  @override
  Widget build(BuildContext context) {
    final addressText = Text(
      address,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (marks.isEmpty) return addressText;
    final status = marks.join(' · ');
    final inline = '$address · $status';
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: inline, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout(maxWidth: constraints.maxWidth);
        final fits = !painter.didExceedMaxLines;
        painter.dispose();
        if (fits) {
          return Row(
            children: [
              Flexible(child: addressText),
              Text(' · $status', maxLines: 1),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [addressText, Text(status)],
        );
      },
    );
  }
}
