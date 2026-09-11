import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';

abstract final class ConnectFormKeys {
  static const address = Key('connect-address');
  static const userAgent = Key('connect-user-agent');
  static const username = Key('connect-username');
  static const password = Key('connect-password');
  static const submit = Key('connect-submit');
  static const addServer = Key('connect-add-server');
  static const addLine = Key('connect-add-line');
  static const deleteLine = Key('connect-delete-line');
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _address = TextEditingController();
  final _userAgent = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _appliedPrefillId;
  String? _selectedServerId;
  String? _selectedLineId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final prefill = AuthScope.of(context).prefill;
    if (prefill != null && prefill.id != _appliedPrefillId) {
      _appliedPrefillId = prefill.id;
      _fillServer(prefill);
      _loadPassword(prefill.id);
    }
  }

  void _fillServer(SavedServer server) {
    _selectedServerId = server.id;
    _selectedLineId = server.activeLine?.id;
    _address.text = server.baseUrl;
    _userAgent.text = server.activeLine?.normalizedUserAgent ?? '';
    _username.text = server.username;
  }

  Future<void> _loadPassword(String serverId) async {
    final password = await AuthScope.of(context).savedPassword(serverId);
    if (!mounted || password == null) {
      return;
    }
    _password.text = password;
  }

  @override
  void dispose() {
    _address.dispose();
    _userAgent.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = AuthScope.of(context);
    await auth.connect(
      address: _address.text,
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: _selectedLineId,
    );
  }

  Future<void> _selectSaved(SavedServer server) async {
    _appliedPrefillId = server.id;
    setState(() => _fillServer(server));
    await AuthScope.of(context).selectSavedServer(server.id);
    if (!mounted) {
      return;
    }
    await _loadPassword(server.id);
  }

  void _selectSavedLine(SavedServer server, ServerLine line) {
    _appliedPrefillId = server.id;
    setState(() {
      _selectedServerId = server.id;
      _selectedLineId = line.id;
      _address.text = line.address;
      _userAgent.text = line.normalizedUserAgent ?? '';
      _username.text = server.username;
    });
    _loadPassword(server.id);
  }

  void _startNewLineFor(SavedServer server) {
    _appliedPrefillId = server.id;
    setState(() {
      _selectedServerId = server.id;
      _selectedLineId = null;
      _address.clear();
      _userAgent.clear();
      _username.text = server.username;
    });
    AuthScope.of(context).clearFailure();
    _loadPassword(server.id);
  }

  void _startNewServer() {
    setState(() {
      _selectedServerId = null;
      _selectedLineId = null;
      _address.clear();
      _userAgent.clear();
      _username.clear();
      _password.clear();
    });
    AuthScope.of(context).clearFailure();
  }

  Future<void> _deleteSelectedLine() async {
    final serverId = _selectedServerId;
    final lineId = _selectedLineId;
    if (serverId == null || lineId == null) {
      return;
    }
    final auth = AuthScope.of(context);
    await auth.deleteLine(serverId, lineId);
    if (!mounted) {
      return;
    }
    SavedServer? next;
    for (final server in auth.savedServers) {
      if (server.id == serverId) {
        next = server;
        break;
      }
    }
    if (next == null) {
      _startNewServer();
      return;
    }
    final remaining = next;
    setState(() => _fillServer(remaining));
    await _loadPassword(remaining.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = AuthScope.of(context);

    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.connectTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          key: ConnectFormKeys.address,
                          controller: _address,
                          enabled: !auth.isBusy,
                          keyboardType: TextInputType.url,
                          autofillHints: const [AutofillHints.url],
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: l10n.serverAddress,
                            hintText: l10n.serverAddressHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: ConnectFormKeys.userAgent,
                          controller: _userAgent,
                          enabled: !auth.isBusy,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: l10n.userAgent,
                            hintText: l10n.userAgentHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: ConnectFormKeys.username,
                          controller: _username,
                          enabled: !auth.isBusy,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: l10n.username,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: ConnectFormKeys.password,
                          controller: _password,
                          enabled: !auth.isBusy,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onSubmitted: auth.isBusy ? null : (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: l10n.password,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: ConnectFormKeys.submit,
                    onPressed: auth.isBusy ? null : _submit,
                    child: Text(auth.isBusy ? l10n.connecting : l10n.connect),
                  ),
                  if (auth.failure != null) ...[
                    const SizedBox(height: 24),
                    AppErrorView(
                      message: embyFailureMessage(l10n, auth.failure!),
                      onRetry: auth.isBusy ? null : _submit,
                    ),
                  ],
                  const SizedBox(height: 32),
                  Text(
                    l10n.savedServers,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: ConnectFormKeys.addServer,
                      onPressed: auth.isBusy ? null : _startNewServer,
                      child: Text(l10n.addServer),
                    ),
                  ),
                  for (final server in auth.savedServers) ...[
                    ListTile(
                      key: Key('saved-server-${server.id}'),
                      selected: server.id == _selectedServerId,
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(server.name),
                      subtitle: Text(server.baseUrl),
                      onTap: auth.isBusy ? null : () => _selectSaved(server),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        l10n.lines,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (final line in server.lines)
                      ListTile(
                        key: Key('saved-line-${line.id}'),
                        selected:
                            server.id == _selectedServerId &&
                            line.id == _selectedLineId,
                        contentPadding: const EdgeInsets.only(
                          left: 40,
                          right: 16,
                        ),
                        leading: const Icon(Icons.alt_route),
                        title: Text(line.address),
                        subtitle: line.normalizedUserAgent == null
                            ? null
                            : Text(line.normalizedUserAgent!),
                        onTap: auth.isBusy
                            ? null
                            : () => _selectSavedLine(server, line),
                      ),
                    Row(
                      children: [
                        TextButton(
                          key: server.id == _selectedServerId
                              ? ConnectFormKeys.addLine
                              : Key('connect-add-line-${server.id}'),
                          onPressed: auth.isBusy
                              ? null
                              : () => _startNewLineFor(server),
                          child: Text(l10n.addLine),
                        ),
                        TextButton(
                          key: server.id == _selectedServerId
                              ? ConnectFormKeys.deleteLine
                              : Key('connect-delete-line-${server.id}'),
                          onPressed:
                              auth.isBusy ||
                                  server.lines.length <= 1 ||
                                  server.id != _selectedServerId ||
                                  _selectedLineId == null
                              ? null
                              : _deleteSelectedLine,
                          child: Text(l10n.deleteLine),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
