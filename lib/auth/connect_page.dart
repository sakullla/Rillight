import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';

abstract final class ConnectFormKeys {
  static const address = Key('connect-address');
  static const username = Key('connect-username');
  static const password = Key('connect-password');
  static const submit = Key('connect-submit');
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _appliedPrefillId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final prefill = AuthScope.of(context).prefill;
    if (prefill != null && prefill.id != _appliedPrefillId) {
      _appliedPrefillId = prefill.id;
      _applyPrefill(prefill);
    }
  }

  Future<void> _applyPrefill(SavedServer server) async {
    _address.text = server.baseUrl;
    _username.text = server.username;
    final password = await AuthScope.of(context).savedPassword(server.id);
    if (!mounted) {
      return;
    }
    if (password != null) {
      _password.text = password;
    }
  }

  @override
  void dispose() {
    _address.dispose();
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
    );
  }

  Future<void> _selectSaved(SavedServer server) async {
    await AuthScope.of(context).selectSavedServer(server.id);
    if (!mounted) {
      return;
    }
    _appliedPrefillId = server.id;
    await _applyPrefill(server);
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
            child: ListView(
              padding: const EdgeInsets.all(24),
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
                if (auth.savedServers.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Text(
                    l10n.savedServers,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final server in auth.savedServers)
                    ListTile(
                      key: Key('saved-server-${server.id}'),
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(server.name),
                      subtitle: Text(server.baseUrl),
                      onTap: auth.isBusy ? null : () => _selectSaved(server),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
