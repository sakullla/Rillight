import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/app/tv_widgets.dart';

/// Remote connection flow; credentials remain owned by the auth draft.
class TvConnectPage extends StatefulWidget {
  const TvConnectPage({super.key, this.addingAnother = false});
  final bool addingAnother;

  @override
  State<TvConnectPage> createState() => _TvConnectPageState();
}

class _TvConnectPageState extends State<TvConnectPage> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _userAgent = TextEditingController();
  ConnectDraft? _draft;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_draft != null) return;
    final auth = AuthScope.of(context);
    final draft =
        auth.connectDraft ?? ConnectDraft(addingAnother: widget.addingAnother);
    if (auth.connectDraft == null && auth.prefill != null) {
      final server = auth.prefill!;
      draft.address = server.baseUrl;
      draft.username = server.username;
      draft.userAgent = server.activeLine?.normalizedUserAgent ?? '';
      draft.selectedServerId = server.id;
      draft.selectedLineId = server.activeLine?.id;
    }
    auth.connectDraft = _draft = draft;
    _address.text = draft.address;
    _username.text = draft.username;
    _password.text = draft.password;
    _userAgent.text = draft.userAgent;
    for (final field in [_address, _username, _password, _userAgent]) {
      field.addListener(_save);
    }
  }

  void _save() {
    _draft!
      ..address = _address.text
      ..username = _username.text
      ..password = _password.text
      ..userAgent = _userAgent.text;
  }

  void _select(SavedServer server) {
    _draft!
      ..selectedServerId = server.id
      ..selectedLineId = server.activeLine?.id;
    _address.text = server.baseUrl;
    _username.text = server.username;
    _password.clear();
    _userAgent.text = server.activeLine?.normalizedUserAgent ?? '';
    AuthScope.of(context).selectSavedServer(server.id);
  }

  Future<void> _submit() async {
    final auth = AuthScope.of(context);
    if (auth.isBusy) return;
    FocusScope.of(context).unfocus();
    await auth.connect(
      address: _address.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: _draft?.selectedLineId,
    );
    if (mounted && auth.isLoggedIn && widget.addingAnother) context.go('/');
  }

  @override
  void dispose() {
    for (final field in [_address, _username, _password, _userAgent]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    return TvFrame(
      title: l10n.connectTitle,
      back: widget.addingAnother,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListenableBuilder(
            listenable: auth,
            builder: (context, _) => ListView(
              children: [
                TvInput(
                  key: const Key('tv-connect-address'),
                  label: l10n.serverAddress,
                  controller: _address,
                  autofocus: true,
                ),
                TvInput(
                  key: const Key('tv-connect-username'),
                  label: l10n.username,
                  controller: _username,
                ),
                TvInput(
                  key: const Key('tv-connect-password'),
                  label: l10n.password,
                  controller: _password,
                  secret: true,
                ),
                TvInput(label: l10n.userAgent, controller: _userAgent),
                if (auth.failure != null)
                  Text(embyFailureMessage(l10n, auth.failure!)),
                TvAction(
                  key: const Key('tv-connect-submit'),
                  onPressed: auth.isBusy ? null : _submit,
                  child: Text(
                    auth.isBusy
                        ? l10n.connecting
                        : auth.failure != null
                        ? l10n.retry
                        : l10n.connect,
                  ),
                ),
                if (auth.savedServers.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(l10n.savedServers),
                  for (final server in auth.savedServers)
                    TvAction(
                      key: ValueKey(server.id),
                      onPressed: auth.isBusy ? null : () => _select(server),
                      child: Text('${server.name} · ${server.username}'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
