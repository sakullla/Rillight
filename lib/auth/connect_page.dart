import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/emby_mark.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_url.dart';

abstract final class ConnectFormKeys {
  static const address = Key('connect-address');
  static const path = Key('connect-path');
  static const more = Key('connect-more');
  static const userAgent = Key('connect-user-agent');
  static const username = Key('connect-username');
  static const password = Key('connect-password');
  static const submit = Key('connect-submit');
  static const addServer = Key('connect-add-server');
  static const addLine = Key('connect-add-line');
  static const deleteLine = Key('connect-delete-line');
  static const serverSearch = Key('connect-server-search');
  static Key extraLine(int index) => Key('connect-extra-line-$index');
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _address = TextEditingController();
  final _path = TextEditingController();
  final _userAgent = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _appliedPrefillId;
  String? _selectedServerId;
  String? _selectedLineId;
  bool _moreExpanded = false;
  String _serverQuery = '';
  final List<TextEditingController> _extraLines = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (GoRouterState.of(context).uri.queryParameters['add'] == '1') {
      return;
    }
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
    _path.clear();
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
    _path.dispose();
    _userAgent.dispose();
    _username.dispose();
    _password.dispose();
    for (final extra in _extraLines) {
      extra.dispose();
    }
    super.dispose();
  }

  bool get _addingAnother =>
      GoRouterState.of(context).uri.queryParameters['add'] == '1';

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
    final adding = _addingAnother;
    await auth.connect(
      address: _composedAddress(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: adding ? null : _selectedLineId,
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
    if (adding) {
      context.go(AppRoutes.home);
    }
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

  void _addExtraLine() {
    setState(() {
      _extraLines.add(TextEditingController());
      _moreExpanded = true;
    });
  }

  void _removeLastExtraLine() {
    if (_extraLines.isEmpty) {
      return;
    }
    setState(() {
      _extraLines.removeLast().dispose();
    });
  }

  void _startNewServer() {
    setState(() {
      _selectedServerId = null;
      _selectedLineId = null;
      _address.clear();
      _path.clear();
      _userAgent.clear();
      _username.clear();
      _password.clear();
      for (final extra in _extraLines) {
        extra.dispose();
      }
      _extraLines.clear();
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

  /// 内容宽度随断点舒展:compact 全宽(减页边距),medium 收敛,
  /// large 再放宽,宽屏下整体由外层 [Center] 垂直居中。
  static double _contentWidth(double maxWidth) {
    if (maxWidth < AppBreakpoints.compact) {
      return maxWidth - AppSpacing.xl * 2;
    }
    if (maxWidth <= AppBreakpoints.large) {
      return 520;
    }
    return 580;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = AuthScope.of(context);

    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl,
                vertical: AppSpacing.xl,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - AppSpacing.xl * 2,
                ),
                child: Center(
                  child: SizedBox(
                    width: _contentWidth(constraints.maxWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _BrandHeader(l10n: l10n),
                        const SizedBox(height: AppSpacing.xl),
                        _buildFormCard(context, l10n, auth),
                        const SizedBox(height: AppSpacing.xxl),
                        _buildSavedServers(context, l10n, auth),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFormCard(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    return LiquidGlass(
      kind: LiquidGlassKind.panel,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (auth.failure != null) ...[
              AppErrorView(
                message: embyFailureMessage(l10n, auth.failure!),
                onRetry: auth.isBusy ? null : _submit,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
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
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    key: ConnectFormKeys.username,
                    controller: _username,
                    enabled: !auth.isBusy,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: l10n.username),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    key: ConnectFormKeys.password,
                    controller: _password,
                    enabled: !auth.isBusy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: auth.isBusy ? null : (_) => _submit(),
                    decoration: InputDecoration(labelText: l10n.password),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              key: ConnectFormKeys.submit,
              onPressed: auth.isBusy ? null : _submit,
              child: auth.isBusy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(l10n.connecting),
                      ],
                    )
                  : Text(l10n.connect),
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildMoreSection(context, l10n, auth),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreSection(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    final selectedServer = _selectedServer(auth);
    return ExpansionTile(
      key: ConnectFormKeys.more,
      title: Text(l10n.more),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      shape: const Border(),
      collapsedShape: const Border(),
      onExpansionChanged: (expanded) {
        setState(() => _moreExpanded = expanded);
      },
      children: [
        if (_moreExpanded) ...[
          TextField(
            key: ConnectFormKeys.path,
            controller: _path,
            enabled: !auth.isBusy,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: '/emby'),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.lines,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Row(
            children: [
              TextButton.icon(
                key: ConnectFormKeys.addLine,
                onPressed: auth.isBusy ? null : _addExtraLine,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addLine),
              ),
              const SizedBox(width: AppSpacing.xs),
              TextButton.icon(
                key: ConnectFormKeys.deleteLine,
                onPressed: auth.isBusy
                    ? null
                    : _extraLines.isNotEmpty
                    ? _removeLastExtraLine
                    : (selectedServer == null ||
                          selectedServer.lines.length <= 1 ||
                          _selectedLineId == null)
                    ? null
                    : _deleteSelectedLine,
                icon: const Icon(Icons.link_off, size: 18),
                label: Text(l10n.deleteLine),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
          for (var i = 0; i < _extraLines.length; i++) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: ConnectFormKeys.extraLine(i),
              controller: _extraLines[i],
              enabled: !auth.isBusy,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.extraLineAddress,
                hintText: l10n.serverAddressHint,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: ConnectFormKeys.userAgent,
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

  SavedServer? _selectedServer(AuthController auth) {
    final id = _selectedServerId;
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

  Widget _buildSavedServers(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.savedServers,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              key: ConnectFormKeys.addServer,
              onPressed: auth.isBusy ? null : _startNewServer,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.addServer),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (auth.savedServers.isEmpty)
          AppEmptyView(message: l10n.noSavedServers, icon: Icons.dns_outlined)
        else ...[
          if (auth.savedServers.length > 6)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: TextField(
                key: ConnectFormKeys.serverSearch,
                onChanged: (value) => setState(() => _serverQuery = value),
                decoration: InputDecoration(
                  hintText: l10n.searchServers,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
          SizedBox(
            height: auth.savedServers.length > 4 ? 320 : null,
            child: ListView.separated(
              shrinkWrap: auth.savedServers.length <= 4,
              physics: auth.savedServers.length <= 4
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: _filteredServers(auth).length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                return _buildServerCard(
                  context,
                  l10n,
                  auth,
                  _filteredServers(auth)[index],
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  List<SavedServer> _filteredServers(AuthController auth) {
    final needle = _serverQuery.trim().toLowerCase();
    if (needle.isEmpty) {
      return auth.savedServers;
    }
    return [
      for (final server in auth.savedServers)
        if (server.name.toLowerCase().contains(needle) ||
            server.baseUrl.toLowerCase().contains(needle))
          server,
    ];
  }

  Widget _buildServerCard(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
    SavedServer server,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = server.id == _selectedServerId;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: selected
            ? BorderSide(color: colorScheme.primary, width: 1.5)
            : BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('saved-server-${server.id}'),
            onTap: auth.isBusy ? null : () => _selectSaved(server),
            borderRadius: BorderRadius.circular(AppRadii.lg),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const EmbyMark(size: 28),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(server.name, style: theme.textTheme.titleMedium),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          server.baseUrl,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle,
                      color: colorScheme.primary,
                      size: 20,
                    ),
                ],
              ),
            ),
          ),
          if (server.lines.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                children: [
                  for (final line in server.lines)
                    _buildLineTile(context, auth, server, line, selected),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLineTile(
    BuildContext context,
    AuthController auth,
    SavedServer server,
    ServerLine line,
    bool serverSelected,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = serverSelected && line.id == _selectedLineId;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          key: Key('saved-line-${line.id}'),
          onTap: auth.isBusy ? null : () => _selectSavedLine(server, line),
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.alt_route,
                  size: 18,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    line.hostLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (selected)
                  Icon(Icons.check, color: colorScheme.primary, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectSavedLine(SavedServer server, ServerLine line) {
    _appliedPrefillId = server.id;
    setState(() {
      _selectedServerId = server.id;
      _selectedLineId = line.id;
      _address.text = line.address;
      _path.clear();
      _userAgent.text = line.normalizedUserAgent ?? '';
      _username.text = server.username;
    });
    _loadPassword(server.id);
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Icon(
            Icons.play_circle_fill,
            color: colorScheme.onPrimaryContainer,
            size: 26,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.appName, style: theme.textTheme.headlineSmall),
            Text(
              l10n.connectTitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
