import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';

/// Small Android connection surface for the platform bootstrap. Phone and TV
/// navigation build on this shared authentication contract in subsequent tasks.
class AndroidConnectPage extends StatefulWidget {
  const AndroidConnectPage({super.key});

  @override
  State<AndroidConnectPage> createState() => _AndroidConnectPageState();
}

class _AndroidConnectPageState extends State<AndroidConnectPage> {
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
    final draft = auth.connectDraft ?? ConnectDraft(addingAnother: false);
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.connectTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListenableBuilder(
              listenable: auth,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (auth.savedServers.isNotEmpty)
                    ExpansionTile(
                      title: Text(l10n.savedServers),
                      children: [
                        for (final server in auth.savedServers)
                          ListTile(
                            title: Text(server.name),
                            subtitle: Text(server.username),
                            onTap: auth.isBusy ? null : () => _select(server),
                          ),
                      ],
                    ),
                  TextField(
                    key: const Key('android-connect-address'),
                    controller: _address,
                    autofocus: true,
                    enabled: !auth.isBusy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.serverAddress,
                      hintText: l10n.serverAddressHint,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('android-connect-username'),
                    controller: _username,
                    enabled: !auth.isBusy,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: l10n.username),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('android-connect-password'),
                    controller: _password,
                    enabled: !auth.isBusy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(labelText: l10n.password),
                  ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: Text(l10n.userAgent),
                    children: [
                      TextField(
                        controller: _userAgent,
                        enabled: !auth.isBusy,
                        decoration: InputDecoration(
                          labelText: l10n.userAgent,
                          hintText: l10n.userAgentHint,
                        ),
                      ),
                    ],
                  ),
                  if (auth.failure != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      embyFailureMessage(l10n, auth.failure!),
                      semanticsLabel: embyFailureMessage(l10n, auth.failure!),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('android-connect-submit'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: auth.isBusy ? null : _submit,
                    child: Text(
                      auth.isBusy
                          ? l10n.connecting
                          : auth.failure != null
                          ? l10n.retry
                          : l10n.connect,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Temporary authenticated landing until phone/TV catalog routes are assembled.
class AndroidSessionPage extends StatelessWidget {
  const AndroidSessionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appName)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(auth.session?.server.name ?? ''),
            Text(auth.session?.username ?? ''),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: auth.isBusy ? null : auth.logout,
              child: Text(l10n.logout),
            ),
          ],
        ),
      ),
    );
  }
}
