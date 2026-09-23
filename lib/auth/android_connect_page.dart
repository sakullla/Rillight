import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_url.dart';

/// Independent touch-first connection form; drafts live only in the auth flow.
class AndroidConnectPage extends StatefulWidget {
  const AndroidConnectPage({super.key, this.addingAnother = false});

  final bool addingAnother;

  @override
  State<AndroidConnectPage> createState() => _AndroidConnectPageState();
}

class _AndroidConnectPageState extends State<AndroidConnectPage> {
  final _address = TextEditingController();
  final _path = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _userAgent = TextEditingController();
  final List<TextEditingController> _extraLines = [];
  ConnectDraft? _draft;
  bool _moreExpanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_draft != null) {
      return;
    }
    final auth = AuthScope.of(context);
    final previous = auth.connectDraft;
    final restoring =
        previous != null && previous.addingAnother == widget.addingAnother;
    final draft = restoring
        ? previous
        : ConnectDraft(addingAnother: widget.addingAnother);
    if (!restoring && !widget.addingAnother && auth.prefill != null) {
      final server = auth.prefill!;
      draft.address = server.baseUrl;
      draft.username = server.username;
      draft.userAgent = server.activeLine?.normalizedUserAgent ?? '';
      draft.selectedServerId = server.id;
      draft.selectedLineId = server.activeLine?.id;
    }
    auth.connectDraft = _draft = draft;
    _address.text = draft.address;
    _path.text = draft.path;
    _username.text = draft.username;
    _userAgent.text = draft.userAgent;
    _moreExpanded = draft.moreExpanded;
    // A recreated page must not restore a password that was never submitted.
    _password.clear();
    draft.password = '';
    for (final text in draft.extraLines) {
      _extraLines.add(TextEditingController(text: text)..addListener(_save));
    }
    for (final field in [_address, _path, _username, _password, _userAgent]) {
      field.addListener(_save);
    }
  }

  void _save() {
    final draft = _draft;
    if (draft == null) {
      return;
    }
    draft
      ..address = _address.text
      ..path = _path.text
      ..username = _username.text
      ..password = _password.text
      ..userAgent = _userAgent.text
      ..moreExpanded = _moreExpanded
      ..extraLines = [for (final extra in _extraLines) extra.text];
  }

  List<TextEditingController> get _fields => [
    _address,
    _path,
    _username,
    _password,
    _userAgent,
    ..._extraLines,
  ];

  @override
  void dispose() {
    final fields = _fields;
    for (final field in fields) {
      field.removeListener(_save);
    }
    _draft?.password = '';
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  void _applyServer(SavedServer server) {
    final draft = _draft!;
    draft
      ..selectedServerId = server.id
      ..selectedLineId = server.activeLine?.id;
    _address.text = server.baseUrl;
    _path.clear();
    _username.text = server.username;
    _password.clear();
    _userAgent.text = server.activeLine?.normalizedUserAgent ?? '';
  }

  void _select(SavedServer server) {
    _applyServer(server);
    AuthScope.of(context).selectSavedServer(server.id);
  }

  String _composedAddress() {
    final extraPath = _path.text.trim();
    if (extraPath.isEmpty) {
      return _address.text;
    }
    try {
      return normalizeEmbyBaseUrl(
        joinEmbyPath(normalizeEmbyBaseUrl(_address.text), extraPath).toString(),
      ).toString();
    } on EmbyException {
      return _address.text;
    }
  }

  Future<void> _submit() async {
    final auth = AuthScope.of(context);
    if (auth.isBusy) {
      return;
    }
    FocusScope.of(context).unfocus();
    await auth.connect(
      address: _composedAddress(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: widget.addingAnother ? null : _draft?.selectedLineId,
    );
    if (!mounted || !auth.isLoggedIn) {
      return;
    }
    final extras = [
      for (final extra in _extraLines)
        if (extra.text.trim().isNotEmpty) extra.text,
    ];
    if (extras.isNotEmpty) {
      await auth.appendLines(extras, userAgent: _userAgent.text);
    }
    if (!mounted || !auth.isLoggedIn) {
      return;
    }
    if (widget.addingAnother) {
      context.go('/');
    }
  }

  void _addExtraLine() {
    setState(() {
      _extraLines.add(TextEditingController()..addListener(_save));
      _moreExpanded = true;
      _save();
    });
  }

  void _removeLastExtraLine() {
    if (_extraLines.isEmpty) {
      return;
    }
    setState(() {
      final removed = _extraLines.removeLast()..removeListener(_save);
      removed.dispose();
      _save();
    });
  }

  SavedServer? _selectedServer(AuthController auth) {
    final id = _draft?.selectedServerId;
    if (id == null) {
      return null;
    }
    for (final server in auth.savedServers) {
      if (server.id == id) {
        return server;
      }
    }
    return null;
  }

  bool _canDeletePersistedLine(AuthController auth) {
    final server = _selectedServer(auth);
    final lineId = _draft?.selectedLineId;
    return server != null && server.lines.length > 1 && lineId != null;
  }

  Future<void> _deleteSelectedLine() async {
    final draft = _draft;
    final serverId = draft?.selectedServerId;
    final lineId = draft?.selectedLineId;
    if (draft == null || serverId == null || lineId == null) {
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
      return;
    }
    setState(() => _applyServer(next!));
  }

  void _deleteLine(AuthController auth) {
    if (_extraLines.isNotEmpty) {
      _removeLastExtraLine();
      return;
    }
    if (_canDeletePersistedLine(auth)) {
      _deleteSelectedLine();
    }
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
              builder: (context, _) => SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.mobileConnectionHint),
                    const SizedBox(height: 24),
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
                      autofocus: false,
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
                    _buildMore(context, l10n, auth),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMore(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    final canDelete = _extraLines.isNotEmpty || _canDeletePersistedLine(auth);
    return ExpansionTile(
      key: const Key('android-connect-more'),
      initiallyExpanded: _moreExpanded,
      title: Text(l10n.more),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      shape: const Border(),
      collapsedShape: const Border(),
      onExpansionChanged: (expanded) {
        setState(() => _moreExpanded = expanded);
        _save();
      },
      children: [
        if (_moreExpanded) ...[
          TextField(
            key: const Key('android-connect-path'),
            controller: _path,
            enabled: !auth.isBusy,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: '/emby'),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.lines,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: const Key('android-connect-add-line'),
                onPressed: auth.isBusy ? null : _addExtraLine,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addLine),
              ),
              TextButton.icon(
                key: const Key('android-connect-delete-line'),
                onPressed: auth.isBusy || !canDelete
                    ? null
                    : () => _deleteLine(auth),
                icon: const Icon(Icons.link_off, size: 18),
                label: Text(l10n.deleteLine),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
          for (var i = 0; i < _extraLines.length; i++) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('android-connect-extra-line-$i'),
              controller: _extraLines[i],
              enabled: !auth.isBusy,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.extraLineAddress,
                hintText: l10n.serverAddressHint,
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('android-connect-user-agent'),
            controller: _userAgent,
            enabled: !auth.isBusy,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.userAgent,
              hintText: l10n.userAgentHint,
            ),
          ),
        ],
      ],
    );
  }
}
