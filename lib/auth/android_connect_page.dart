import 'login_widgets.dart';
import 'provider_login_form.dart';
import '../media_server/capabilities.dart';

import 'package:rillight/media_server/server_address.dart';
import 'package:rillight/app/ui/ui.dart';

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/server_management_widgets.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/app/ui/app_icons.dart';

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

  Future<void> _manageServers() =>
      showPhoneServerManagerSheet(context, AuthScope.of(context));

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
    return CupertinoPageScaffold(
      navigationBar: const PhoneTopBar(
        backgroundColor: AppInk.transparent,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppearanceMenuButton(buttonKey: Key('android-connect-appearance')),
          ],
        ),
      ),
      child: SafeArea(
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
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top,
                  24,
                  24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PhoneBrandHeader(l10n: l10n),
                    const SizedBox(height: 28),
                    ..._savedServers(context, l10n, auth),
                    const SizedBox(height: 24),
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
                                AppTextField(
                                  key: const Key('android-connect-address'),
                                  controller: _address,
                                  autofocus: false,
                                  enabled: !auth.isBusy,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.url],
                                  textInputAction: TextInputAction.next,
                                  label: l10n.serverAddress,
                                  placeholder: l10n.serverAddressHint,
                                  prefix: const Icon(
                                    AppIcons.link,
                                    fill: AppIcons.filled,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                AppTextField(
                                  key: const Key('android-connect-username'),
                                  controller: _username,
                                  enabled: !auth.isBusy,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.username],
                                  textInputAction: TextInputAction.next,
                                  label: l10n.username,
                                  prefix: const Icon(
                                    AppIcons.person,
                                    fill: AppIcons.filled,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                AppTextField(
                                  key: const Key('android-connect-password'),
                                  controller: _password,
                                  enabled: !auth.isBusy,
                                  obscureText: !_passwordVisible,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [AutofillHints.password],
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _submit(),
                                  label: l10n.password,
                                  prefix: const Icon(
                                    AppIcons.lock,
                                    fill: AppIcons.filled,
                                    size: 20,
                                  ),
                                  suffix: AppIconButton(
                                    key: const Key(
                                      'android-connect-password-visibility',
                                    ),
                                    tooltip: _passwordVisible
                                        ? l10n.hidePassword
                                        : l10n.showPassword,
                                    onPressed: () => setState(
                                      () =>
                                          _passwordVisible = !_passwordVisible,
                                    ),
                                    icon: Icon(
                                      AppIcons.visibility,
                                      fill: _passwordVisible
                                          ? AppIcons.filled
                                          : AppIcons.outline,
                                      size: 20,
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
                          const SizedBox(height: 18),
                          AppButton.icon(
                            key: const Key('android-connect-submit'),
                            style: AppButtonStyle(
                              minimumSize: const Size(52, 50),
                              boxShadow: AppShadow.emphasis(
                                AppUiTheme.of(context).colorScheme.brightness,
                              ),
                            ),
                            onPressed: auth.isBusy ? null : _submit,
                            variant: AppButtonVariant.filled,
                            icon: Icon(
                              auth.failure != null
                                  ? AppIcons.refresh
                                  : AppIcons.play,
                              fill: AppIcons.filled,
                              size: 18,
                            ),
                            label: BusyLabel(
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

  /// 已保存的服务器只列最多 [_maxSavedCards] 张竖排紧凑卡,其余经「管理
  /// 服务器」进入;导入备份与管理服务器同属一组次级入口。没有已保存服务器
  /// 时只剩「导入备份」,不画空列表。
  static const _maxSavedCards = 3;

  List<Widget> _savedServers(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    final theme = AppUiTheme.of(context);
    final saved = auth.savedServers;
    final selectedId = _draft?.selectedServerId;
    // 选中的服务器即使排在第三张之后也留在卡片里,避免选中项看不见。
    final shown = saved.take(_maxSavedCards).toList();
    final selected = saved.where((s) => s.id == selectedId).firstOrNull;
    if (selected != null && !shown.contains(selected)) {
      shown[shown.length - 1] = selected;
    }
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (saved.isNotEmpty)
          AppActionButton(
            key: const Key('phone-connect-manage-servers'),
            onPressed: auth.isBusy ? null : _manageServers,
            icon: AppIcons.server,
            label: saved.length > _maxSavedCards
                ? '${l10n.phoneManageServer} · ${saved.length}'
                : l10n.phoneManageServer,
          ),
        AppActionButton(
          key: const Key('android-connect-import'),
          onPressed: auth.isBusy
              ? null
              : () => unawaited(showBackupImportFlow(context, auth: auth)),
          icon: AppIcons.download,
          label: l10n.backupImportEntry,
        ),
      ],
    );
    if (saved.isEmpty) return [actions];
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.savedServers,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(height: 8),
      for (final server in shown) ...[
        _PhoneServerCard(
          key: Key('phone-saved-server-${server.id}'),
          server: server,
          selected: selectedId == server.id,
          onPressed: auth.isBusy ? null : () => setState(() => _select(server)),
        ),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 4),
      actions,
    ];
  }

  Widget _buildMore(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    final canDelete = _extraLines.isNotEmpty || _canDeletePersistedLine(auth);
    return AppDisclosure(
      key: const Key('android-connect-more'),
      initiallyExpanded: _moreExpanded,
      title: Text(l10n.more),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      onExpansionChanged: (expanded) {
        setState(() => _moreExpanded = expanded);
        _save();
      },
      children: [
        if (_moreExpanded) ...[
          AppTextField(
            key: const Key('android-connect-path'),
            controller: _path,
            enabled: !auth.isBusy,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            placeholder: '/emby',
          ),
          const SizedBox(height: 16),
          // 标题与「添加 / 删除线路」放得下时同一行,200% 字号时按钮整组折行。
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                l10n.lines,
                style: AppUiTheme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  AppActionButton(
                    key: const Key('android-connect-add-line'),
                    onPressed: auth.isBusy ? null : _addExtraLine,
                    icon: AppIcons.add,
                    label: l10n.addLine,
                  ),
                  AppActionButton(
                    key: const Key('android-connect-delete-line'),
                    tier: AppActionTier.tertiary,
                    onPressed: auth.isBusy || !canDelete
                        ? null
                        : () => _deleteLine(auth),
                    label: l10n.deleteLine,
                  ),
                ],
              ),
            ],
          ),
          for (var i = 0; i < _extraLines.length; i++) ...[
            const SizedBox(height: 8),
            AppTextField(
              key: Key('android-connect-extra-line-$i'),
              controller: _extraLines[i],
              enabled: !auth.isBusy,
              keyboardType: TextInputType.url,
              label: l10n.extraLineAddress,
              placeholder: l10n.serverAddressHint,
            ),
          ],
          const SizedBox(height: 16),
          AppTextField(
            key: const Key('android-connect-user-agent'),
            controller: _userAgent,
            enabled: !auth.isBusy,
            textInputAction: TextInputAction.next,
            label: l10n.userAgent,
            placeholder: l10n.userAgentHint,
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
    final theme = AppUiTheme.of(context);
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

/// 已保存服务器的竖排紧凑卡:服务标记 + 名称 + 「账号 · 当前线路」,
/// 选中描主色边。高度随字号增长,不固定行高。
class _PhoneServerCard extends StatelessWidget {
  const _PhoneServerCard({
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final line = server.activeLine;
    final lineLabel = line == null ? server.baseUrl : serverLineLabel(line);
    final subtitle = server.username.isEmpty
        ? lineLabel
        : '${server.username} · $lineLabel';
    return Semantics(
      button: true,
      selected: selected,
      child: Container(
        decoration: selected
            ? AppSelectionDecoration.of(scheme, radius: AppRadii.md)
            : BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: AppEdge.of(theme.brightness, strong: true),
                ),
              ),
        clipBehavior: Clip.antiAlias,
        child: AppSurfaceAction(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ServerTypeMark(type: server.serviceType, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
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
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected ? AppIcons.checkCircle : AppIcons.chevronRight,
                    fill: AppIcons.filled,
                    size: 18,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
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
