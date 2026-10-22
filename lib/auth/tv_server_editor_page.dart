import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/capabilities.dart';
import 'server_editor.dart';
import 'server_management_widgets.dart';
import 'provider_connect_dialog.dart';
import 'change_password_dialog.dart';
import 'tv_line_selection_page.dart';
import 'tv_server_access_page.dart';
import 'tv_server_flow_frame.dart';

/// Shares draft/commit methods with the desktop editor, not its interaction tree.
class TvServerEditorPage extends ServerEditor {
  const TvServerEditorPage({
    super.key,
    required super.auth,
    required super.server,
    required super.onBack,
    required super.onSaved,
    super.onSignedOut,
  });
  @override
  State<ServerEditor> createState() => _TvServerEditorState();
}

class _TvServerEditorState extends ServerEditorState {
  String? lineActions;
  String? returnFocus;
  final nodes = <String, FocusNode>{};
  FocusNode node(String id) =>
      nodes.putIfAbsent(id, () => FocusNode(debugLabel: id));
  @override
  void dispose() {
    for (final n in nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void show(String value, String origin) {
    returnFocus = origin;
    setState(() => step = value);
  }

  @override
  void back() {
    super.back();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || step != 'main') return;
        final removedLine =
            returnFocus?.startsWith('server-editor-line-') == true &&
            !lines.any(
              (l) =>
                  returnFocus == 'server-editor-line-${l.id}' ||
                  returnFocus == 'server-editor-line-more-${l.id}',
            );
        final n = nodes[removedLine ? 'server-editor-add-line' : returnFocus];
        n?.requestFocus();
        if (n?.context case final context?) {
          Scrollable.ensureVisible(context, alignment: .5);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  Widget action(
    String key,
    String label,
    VoidCallback callback, {
    bool primary = false,
  }) => TvAction(
    key: Key(key),
    focusNode: node(key),
    emphasized: primary,
    pill: primary,
    onPressed: busy ? null : callback,
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final protected = widget.auth.serverAccess.isProtected(widget.server.id);
    final needsLogin =
        widget.auth.hasSavedAuthorization(widget.server.id) == false;
    var title = l.serversEdit;
    Widget body;
    Widget? headerAction;
    if (step == 'line') {
      title = editing == null ? l.serversLineAdd : l.serversLineEdit;
      body = TvServerLineFields(
        key: ValueKey(editing?.id ?? 'new'),
        line: editing,
        otherLines: lines,
        onDone: (value) {
          setState(() {
            final index = lines.indexWhere((line) => line.id == value.id);
            if (index < 0) {
              lines.add(value);
            } else {
              lines[index] = value;
            }
          });
          back();
        },
      );
    } else if (step == 'password') {
      title = protected ? l.serversPasswordChange : l.serversPasswordSet;
      body = TvServerPasswordFields(
        protected: protected,
        initial: password,
        onDone: (value) {
          setState(() => password = value);
          back();
        },
      );
    } else if (step == 'account' || step == 'homeAccount') {
      title = step == 'homeAccount' ? l.providerHomeManage : l.serversAccount;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversChangeAccountHint),
          const SizedBox(height: 16),
          ProviderConnectDialog(
            auth: widget.auth,
            existing: widget.auth.sources.server(widget.server.id),
            home: step == 'homeAccount',
            inline: true,
            onConnected: back,
          ),
        ],
      );
    } else if (step == 'remotePassword') {
      title = l.serversRemotePassword;
      body = ChangePasswordDialog(
        auth: widget.auth,
        inline: true,
        onDone: back,
      );
    } else if (step == 'logout') {
      title = l.serversSignOut;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversSignOutHint),
          if (widget.auth.session?.server.id == widget.server.id)
            Text(l.serversCurrentImpact),
          if (error != null) ServerFeedback(error!),
          const SizedBox(height: 24),
          action('server-logout-confirm', l.serversSignOut, signOut),
        ],
      );
    } else if (step == 'impact') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversConnectionImpact),
          const SizedBox(height: 24),
          action(
            'server-impact-confirm',
            l.serversSave,
            () => save(confirmed: true),
            primary: true,
          ),
        ],
      );
    } else if (step == 'lineActions') {
      title = l.serversLines;
      final index = lines.indexWhere((v) => v.id == lineActions);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(serverLineLabel(lines[index])),
          const SizedBox(height: 20),
          if (index > 0)
            action('server-line-up', l.serversUp, () {
              move(index, -1);
              back();
            }),
          const SizedBox(height: 12),
          if (index < lines.length - 1)
            action('server-line-down', l.serversDown, () {
              move(index, 1);
              back();
            }),
          const SizedBox(height: 12),
          if (lines.length > 1)
            action('server-line-remove', l.serversLineRemove, () {
              setState(() => lines.removeAt(index));
              back();
            }),
        ],
      );
    } else if (step == 'icon') {
      title = l.serversIcon;
      final labels = {
        'default': l.serversIconDefault,
        'home': l.serversIconHome,
        'cinema': l.serversIconCinema,
        'cloud': l.serversIconCloud,
      };
      body = Column(
        children: [
          for (final entry in labels.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TvChoiceTile(
                actionKey: Key('server-icon-${entry.key}'),
                label: entry.value,
                selected: icon == entry.key,
                autofocus: icon == entry.key,
                onPressed: () {
                  setState(() => icon = entry.key);
                  back();
                },
              ),
            ),
        ],
      );
    } else {
      headerAction = action(
        'server-editor-save',
        l.serversSave,
        save,
        primary: true,
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const AppLoadingBar(),
          if (error != null) ServerFeedback(error!),
          TvSectionTitle(l.serversBasic),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TvInput(
                  key: const Key('server-editor-name'),
                  label: l.serversName,
                  controller: name,
                  autofocus: true,
                ),
              ),
              const SizedBox(width: 20),
              TvAction(
                key: const Key('server-editor-icon'),
                focusNode: node('server-editor-icon'),
                leading: ServerIdentityIcon(
                  widget.server.copyWith(iconId: icon),
                ),
                onPressed: () => show('icon', 'server-editor-icon'),
                child: Text(l.serversIcon),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TvSectionTitle(l.serversAccount),
          Text(
            needsLogin
                ? l.serversNoAccount
                : widget.auth.sources.server(widget.server.id).username,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              action(
                'server-editor-account',
                l.serversReauthorize,
                () => show('account', 'server-editor-account'),
              ),
              if (widget.server.serviceType == MediaServerType.plex) ...[
                if (!needsLogin)
                  action(
                    'server-editor-home-account',
                    l.providerHomeManage,
                    () => show('homeAccount', 'server-editor-home-account'),
                  ),
                action(
                  'server-editor-provider-account',
                  l.providerAccountManage,
                  () => showProviderAccountSettings(context),
                ),
              ],
              if (widget.auth.session?.server.id == widget.server.id &&
                  widget
                      .auth
                      .client
                      .capabilities[ServiceCapability.changePassword]
                      .isAvailable)
                action(
                  'server-editor-remote-password',
                  l.serversRemotePassword,
                  () => show('remotePassword', 'server-editor-remote-password'),
                ),
              if (!needsLogin)
                action(
                  'server-editor-logout',
                  l.serversSignOut,
                  () => show('logout', 'server-editor-logout'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          TvSectionTitle(l.serversLines),
          const SizedBox(height: 12),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TvAction(
                      key: Key('server-editor-line-${line.id}'),
                      focusNode: node('server-editor-line-${line.id}'),
                      variant: TvActionVariant.tile,
                      onPressed: busy
                          ? null
                          : () {
                              editing = line;
                              show('line', 'server-editor-line-${line.id}');
                            },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            serverLineLabel(line),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            serverSafeAddress(line.address),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  TvAction(
                    key: Key('server-editor-line-more-${line.id}'),
                    focusNode: node('server-editor-line-more-${line.id}'),
                    onPressed: lines.length <= 1 || busy
                        ? null
                        : () {
                            lineActions = line.id;
                            show(
                              'lineActions',
                              'server-editor-line-more-${line.id}',
                            );
                          },
                    child: Text(l.serversMore),
                  ),
                ],
              ),
            ),
          action('server-editor-add-line', l.serversLineAdd, () {
            editing = null;
            show('line', 'server-editor-add-line');
          }),
          const SizedBox(height: 24),
          TvSectionTitle(l.serversPassword),
          const SizedBox(height: 12),
          TvAction(
            key: const Key('server-editor-password'),
            focusNode: node('server-editor-password'),
            variant: TvActionVariant.tile,
            leading: const Icon(AppIcons.lock),
            onPressed: busy
                ? null
                : () => show('password', 'server-editor-password'),
            child: Text(
              password != null
                  ? l.serversPasswordPending
                  : protected
                  ? l.serversPasswordOn
                  : l.serversPasswordOff,
            ),
          ),
          const SizedBox(height: 24),
          action(
            'server-editor-advanced',
            l.serversAdvanced,
            () => setState(() => advanced = !advanced),
          ),
          if (advanced) ...[
            const SizedBox(height: 12),
            TvInput(
              key: const Key('server-editor-user-agent'),
              label: l.userAgent,
              controller: userAgent,
            ),
          ],
        ],
      );
    }
    return TvServerFlowFrame(
      key: step == 'password' ? const ValueKey('password-step') : null,
      title: title,
      onBack: back,
      action: headerAction,
      child: body,
    );
  }
}
