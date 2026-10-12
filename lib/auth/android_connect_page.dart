import 'login_widgets.dart';
import 'provider_login_form.dart';
import '../media_server/capabilities.dart';
import 'package:rillight/media_server/server_address.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/media_server/errors.dart';

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
  bool _passwordVisible = false;

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
      draft.userAgent = server.normalizedUserAgent ?? '';
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
    _userAgent.text = server.normalizedUserAgent ?? '';
  }

  Future<void> _manageServers() => showPhoneServerManager(
    context,
    auth: AuthScope.of(context),
    onSelect: (id, lineId) async {
      final server = AuthScope.of(
        context,
      ).savedServers.firstWhere((s) => s.id == id);
      setState(() => _select(server.copyWith(activeLineId: lineId)));
    },
    onAddServer: () {
      if (!mounted) return;
      setState(() {
        _draft?.selectedServerId = null;
        _draft?.selectedLineId = null;
        _address.clear();
        _path.clear();
        _username.clear();
        _password.clear();
      });
    },
  );

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
      return normalizeServerAddress(
        joinServerPath(
          normalizeServerAddress(_address.text),
          extraPath,
        ).toString(),
      ).toString();
    } on MediaServerException {
      return _address.text;
    }
  }

  Future<void> _submit() async {
    final auth = AuthScope.of(context);
    if (auth.isBusy) {
      return;
    }
    final selected = _selectedServer(auth);

    FocusScope.of(context).unfocus();
    await auth.connect(
      address: _composedAddress(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId:
          widget.addingAnother || selected?.serviceType != MediaServerType.emby
          ? null
          : _draft?.selectedLineId,
    );
    if (!mounted || !auth.isLoggedIn) {
      return;
    }
    final extras = [
      for (final extra in _extraLines)
        if (extra.text.trim().isNotEmpty) extra.text,
    ];
    if (extras.isNotEmpty) {
      await auth.appendLines(extras);
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
      // 品牌头已经说明了页面用途,顶栏只留外观入口,不再重复一行标题。
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        // 登录前也能切外观;偏好持久化,设置页同源。
        actions: const [
          AppearanceMenuButton(buttonKey: Key('android-connect-appearance')),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: AppViewport.dp(560, MediaQuery.sizeOf(context)),
            ),
            child: ListenableBuilder(
              listenable: auth,
              builder: (context, _) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PhoneBrandHeader(l10n: l10n),
                    const SizedBox(height: 28),
                    if (auth.savedServers.isNotEmpty) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.savedServers,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton.icon(
                            key: const Key('phone-connect-manage-servers'),
                            onPressed: auth.isBusy ? null : _manageServers,
                            icon: const Icon(Icons.settings_outlined, size: 18),
                            label: Text(l10n.phoneManageServer),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        // 两行文字随系统字号增高,200% 时卡片不溢出。
                        height: 24 + MediaQuery.textScalerOf(context).scale(40),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          clipBehavior: Clip.none,
                          itemCount: auth.savedServers.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final server = auth.savedServers[index];
                            return _PhoneServerChip(
                              key: Key('phone-saved-server-${server.id}'),
                              server: server,
                              selected: _draft?.selectedServerId == server.id,
                              onPressed: auth.isBusy
                                  ? null
                                  : () => setState(() => _select(server)),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    ProviderLoginForm(
                      userAgent: () => _userAgent.text,
                      selectedServer: auth.savedServers
                          .where((s) => s.id == _draft?.selectedServerId)
                          .firstOrNull,
                      embyForm: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AutofillGroup(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  key: const Key('android-connect-address'),
                                  controller: _address,
                                  autofocus: false,
                                  enabled: !auth.isBusy,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.url],
                                  textInputAction: TextInputAction.next,
                                  decoration: InputDecoration(
                                    labelText: l10n.serverAddress,
                                    hintText: l10n.serverAddressHint,
                                    prefixIcon: const Icon(
                                      Icons.link_rounded,
                                      size: 20,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  key: const Key('android-connect-username'),
                                  controller: _username,
                                  enabled: !auth.isBusy,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.username],
                                  textInputAction: TextInputAction.next,
                                  decoration: InputDecoration(
                                    labelText: l10n.username,
                                    prefixIcon: const Icon(
                                      Icons.person_outline_rounded,
                                      size: 20,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  key: const Key('android-connect-password'),
                                  controller: _password,
                                  enabled: !auth.isBusy,
                                  obscureText: !_passwordVisible,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [AutofillHints.password],
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _submit(),
                                  decoration: InputDecoration(
                                    labelText: l10n.password,
                                    prefixIcon: const Icon(
                                      Icons.lock_outline_rounded,
                                      size: 20,
                                    ),
                                    suffixIcon: IconButton(
                                      key: const Key(
                                        'android-connect-password-visibility',
                                      ),
                                      tooltip: _passwordVisible
                                          ? l10n.hidePassword
                                          : l10n.showPassword,
                                      onPressed: () => setState(
                                        () => _passwordVisible =
                                            !_passwordVisible,
                                      ),
                                      icon: Icon(
                                        _passwordVisible
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (auth.failure != null) ...[
                            const SizedBox(height: 16),
                            LoginErrorBanner(
                              message: embyFailureMessage(l10n, auth.failure!),
                            ),
                          ],
                          const SizedBox(height: 22),
                          FilledButton(
                            key: const Key('android-connect-submit'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(52, 52),
                            ),
                            onPressed: auth.isBusy ? null : _submit,
                            child: BusyLabel(
                              busy: auth.isBusy,
                              label: auth.failure != null
                                  ? l10n.retry
                                  : l10n.connect,
                              busyLabel: l10n.connecting,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _buildMore(context, l10n, auth),
                        ],
                      ),
                    ),
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

/// 手机登录页品牌头:与桌面同一枚渐变品牌方块,一句话说明用途。
class _PhoneBrandHeader extends StatelessWidget {
  const _PhoneBrandHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LoginBrandMark(size: 52),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.appName,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.loginWelcomeSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

/// 已保存服务器的横滑卡片:服务标记 + 名称 + 地址,选中描主色边。
class _PhoneServerChip extends StatelessWidget {
  const _PhoneServerChip({
    super.key,
    required this.server,
    required this.selected,
    required this.onPressed,
  });

  final SavedServer server;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .1)
            : scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: .6),
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 150, maxWidth: 230),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ServerTypeMark(type: server.serviceType, size: 30),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          server.activeLine?.hostLabel ?? server.baseUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
