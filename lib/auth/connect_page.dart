import 'dart:math' as math;

import 'login_widgets.dart';
import 'provider_login_form.dart';
import '../media_server/capabilities.dart';

import 'package:rillight/media_server/server_address.dart';
import 'package:rillight/app/ui/ui.dart';

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_management_widgets.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/app/ui/app_icons.dart';

abstract final class ConnectFormKeys {
  static const address = Key('connect-address');
  static const path = Key('connect-path');
  static const more = Key('connect-more');
  static const userAgent = Key('connect-user-agent');
  static const username = Key('connect-username');
  static const password = Key('connect-password');
  static const submit = Key('connect-submit');
  static const passwordVisibility = Key('connect-password-visibility');
  static const addServer = Key('connect-add-server');
  static const importBackup = Key('connect-import-backup');
  static const addLine = Key('connect-add-line');
  static const deleteLine = Key('connect-delete-line');
  static const serverSearch = Key('connect-server-search');
  static const connectAppearanceKey = Key('connect-appearance');
  static Key extraLine(int index) => Key('connect-extra-line-$index');

  /// 已保存服务器卡上的「N 条线路」展开钮;只在多线路时出现。
  static Key savedServerLines(String serverId) =>
      Key('saved-server-lines-$serverId');
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
  bool _passwordVisible = false;
  String _serverQuery = '';

  /// 展开了线路列表的已保存服务器。线路默认折叠,卡片只显示当前线路。
  final Set<String> _expandedServers = {};
  final List<TextEditingController> _extraLines = [];
  ConnectDraft? _draft;
  int _passwordRevision = 0;
  int _passwordRequest = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_draft != null) {
      return;
    }
    final auth = AuthScope.of(context);
    final previous = auth.connectDraft;
    final restoring =
        previous != null && previous.addingAnother == _addingAnother;
    final draft = restoring
        ? previous
        : ConnectDraft(addingAnother: _addingAnother);
    auth.connectDraft = _draft = draft;
    _address.text = draft.address;
    _path.text = draft.path;
    _userAgent.text = draft.userAgent;
    _username.text = draft.username;
    _password.text = draft.password;
    _selectedServerId = draft.selectedServerId;
    _selectedLineId = draft.selectedLineId;
    _appliedPrefillId = draft.appliedPrefillId;
    _moreExpanded = draft.moreExpanded;
    for (final text in draft.extraLines) {
      _extraLines.add(
        TextEditingController(text: text)..addListener(_saveDraft),
      );
    }
    for (final controller in [
      _address,
      _path,
      _userAgent,
      _username,
      _password,
    ]) {
      controller.addListener(_saveDraft);
    }
    _password.addListener(() => _passwordRevision++);
    if (restoring || _addingAnother) return;
    final prefill = auth.prefill;
    if (prefill != null && prefill.id != _appliedPrefillId) {
      _appliedPrefillId = prefill.id;
      _fillServer(prefill);
      _loadPassword(prefill.id);
    }
  }

  void _saveDraft() {
    final draft = _draft;
    if (draft == null) return;
    draft.address = _address.text;
    draft.path = _path.text;
    draft.userAgent = _userAgent.text;
    draft.username = _username.text;
    draft.password = _password.text;
    draft.selectedServerId = _selectedServerId;
    draft.selectedLineId = _selectedLineId;
    draft.appliedPrefillId = _appliedPrefillId;
    draft.moreExpanded = _moreExpanded;
    draft.extraLines = [for (final extra in _extraLines) extra.text];
  }

  void _fillServer(SavedServer server) {
    _selectedServerId = server.id;
    _selectedLineId = server.activeLine?.id;
    _address.text = server.baseUrl;
    _path.clear();
    _userAgent.text = server.normalizedUserAgent ?? '';
    _username.text = server.username;
    _password.clear();
    _saveDraft();
  }

  Future<void> _loadPassword(String serverId) async {
    final auth = AuthScope.of(context);
    final request = ++_passwordRequest;
    final revision = _passwordRevision;
    final password = await auth.savedPassword(serverId);
    if (!mounted ||
        password == null ||
        request != _passwordRequest ||
        revision != _passwordRevision ||
        _selectedServerId != serverId ||
        !identical(auth.connectDraft, _draft)) {
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
    if (auth.isBusy) return;
    final selected = _selectedServer(auth);

    // A credential read started before submit must not change this attempt.
    _passwordRequest++;
    final adding = _addingAnother;
    await auth.connect(
      address: _composedAddress(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: adding || selected?.serviceType != MediaServerType.emby
          ? null
          : _selectedLineId,
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
      _extraLines.add(TextEditingController()..addListener(_saveDraft));
      _moreExpanded = true;
      _saveDraft();
    });
  }

  void _removeLastExtraLine() {
    if (_extraLines.isEmpty) {
      return;
    }
    setState(() {
      _extraLines.removeLast().dispose();
      _saveDraft();
    });
  }

  void _startNewServer() {
    _passwordRequest++;
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
      _saveDraft();
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

  /// 宽窗口(≥ 980)左右分栏:左侧品牌与已保存的服务器,右侧登录表单;
  /// 窄窗口单列。表单列顶部对齐,切换服务类型时高度变化只向下延伸,
  /// 不会把整页重新居中而上下跳动。
  static const double _wideBreakpoint = 980;

  Widget _wrapForm(Widget form) {
    return LiquidGlass(
      kind: LiquidGlassKind.panel,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Container(decoration: BoxDecoration(), child: form),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = AuthScope.of(context);
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final trailing = hasChrome
        ? windowChromeTrailingInset() + kWindowChromeActionGap
        : AppSpacing.sm;

    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideBreakpoint;
            final form = ProviderLoginForm(
              userAgent: () => _userAgent.text,
              selectedServer: _selectedServer(auth),
              embyForm: _buildFormCard(context, l10n, auth),
              wrapForm: _wrapForm,
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: wide
                      ? _buildWide(context, l10n, auth, constraints, form)
                      : _buildNarrow(context, l10n, auth, constraints, form),
                ),
                if (hasChrome)
                  Positioned(
                    top: 0,
                    left: windowChromeLeadingInset(),
                    right: trailing + 48,
                    height: kWindowChromeHeight,
                    child: const WindowDragArea(child: SizedBox.expand()),
                  ),
                Positioned(
                  top: AppSpacing.xxs,
                  right: trailing,
                  child: const AppearanceMenuButton(
                    buttonKey: ConnectFormKeys.connectAppearanceKey,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildNarrow(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
    BoxConstraints constraints,
    Widget form,
  ) {
    final width = math.min(560.0, constraints.maxWidth - AppSpacing.xl * 2);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.huge,
        AppSpacing.xl,
        AppSpacing.xl,
      ),
      child: Center(
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BrandHeader(l10n: l10n),
              const SizedBox(height: AppSpacing.xl),
              form,
              const SizedBox(height: AppSpacing.xxl),
              _buildSavedServers(context, l10n, auth),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWide(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
    BoxConstraints constraints,
    Widget form,
  ) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final formWidth = AppViewport.fit(
      440,
      constraints.maxWidth * 6 / 11 - AppSpacing.xxl * 2,
      size,
    );
    // 表单列顶部按视口而不是内容定位:内容高度变化不会移动表单起点。
    final top = math.max(
      AppSpacing.huge + AppSpacing.md,
      (constraints.maxHeight - 640) / 2.6 + AppSpacing.huge,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: _HeroPanel(
            l10n: l10n,
            savedServers: _buildSavedServers(context, l10n, auth, fill: true),
          ),
        ),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.xxl,
              top,
              AppSpacing.xxl,
              AppSpacing.xxl,
            ),
            child: Center(
              child: SizedBox(
                width: formWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.connectTitle,
                      style: AppUiTheme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    form,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormCard(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (auth.failure != null) ...[
          AppErrorView(
            message: embyFailureMessage(l10n, auth.failure!),
            compact: true,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        AutofillGroup(
          child: Column(
            children: [
              AppTextField(
                key: ConnectFormKeys.address,
                controller: _address,
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
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                key: ConnectFormKeys.username,
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
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                key: ConnectFormKeys.password,
                controller: _password,
                enabled: !auth.isBusy,
                obscureText: !_passwordVisible,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: auth.isBusy ? null : (_) => _submit(),
                label: l10n.password,
                prefix: const Icon(
                  AppIcons.lock,
                  fill: AppIcons.filled,
                  size: 20,
                ),
                suffix: AppIconButton(
                  key: ConnectFormKeys.passwordVisibility,
                  tooltip: _passwordVisible
                      ? l10n.hidePassword
                      : l10n.showPassword,
                  onPressed: () {
                    setState(() => _passwordVisible = !_passwordVisible);
                  },
                  icon: Icon(
                    AppIcons.visibility,
                    fill: _passwordVisible ? AppIcons.filled : AppIcons.outline,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppButton.icon(
          key: ConnectFormKeys.submit,
          style: AppButtonStyle(
            minimumSize: const Size(48, 48),
            boxShadow: AppShadow.emphasis(
              AppUiTheme.of(context).colorScheme.brightness,
            ),
          ),
          onPressed: auth.isBusy ? null : _submit,
          variant: AppButtonVariant.filled,
          icon: Icon(
            auth.failure == null ? AppIcons.play : AppIcons.refresh,
            fill: AppIcons.filled,
            size: 18,
          ),
          label: BusyLabel(
            busy: auth.isBusy,
            label: auth.failure == null ? l10n.connect : l10n.retry,
            busyLabel: l10n.connecting,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildMoreSection(context, l10n, auth),
      ],
    );
  }

  Widget _buildMoreSection(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
  ) {
    final selectedServer = _selectedServer(auth);
    return AppDisclosure(
      key: ConnectFormKeys.more,
      initiallyExpanded: _moreExpanded,
      title: Text(l10n.more),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      onExpansionChanged: (expanded) {
        setState(() => _moreExpanded = expanded);
        _saveDraft();
      },
      children: [
        if (_moreExpanded) ...[
          AppTextField(
            key: ConnectFormKeys.path,
            controller: _path,
            enabled: !auth.isBusy,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            placeholder: '/emby',
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.lines,
                  style: AppUiTheme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppActionButton(
                key: ConnectFormKeys.addLine,
                onPressed: auth.isBusy ? null : _addExtraLine,
                icon: AppIcons.add,
                label: l10n.addLine,
              ),
              const SizedBox(width: AppSpacing.xxs),
              AppActionButton(
                key: ConnectFormKeys.deleteLine,
                tier: AppActionTier.tertiary,
                onPressed: auth.isBusy
                    ? null
                    : _extraLines.isNotEmpty
                    ? _removeLastExtraLine
                    : (selectedServer == null ||
                          selectedServer.lines.length <= 1 ||
                          _selectedLineId == null)
                    ? null
                    : _deleteSelectedLine,
                label: l10n.deleteLine,
              ),
            ],
          ),
          for (var i = 0; i < _extraLines.length; i++) ...[
            const SizedBox(height: AppSpacing.sm),
            AppTextField(
              key: ConnectFormKeys.extraLine(i),
              controller: _extraLines[i],
              enabled: !auth.isBusy,
              keyboardType: TextInputType.url,
              label: l10n.extraLineAddress,
              placeholder: l10n.serverAddressHint,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            key: ConnectFormKeys.userAgent,
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

  /// 已保存的服务器:标题与次级入口(导入备份、添加服务器)同属一组,
  /// 下面是紧凑卡片列表。没有已保存服务器时只保留「导入备份」,不画空列表。
  Widget _buildSavedServers(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth, {
    bool fill = false,
  }) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final servers = _filteredServers(auth);
    final empty = auth.savedServers.isEmpty;
    final actions = Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        AppActionButton(
          key: ConnectFormKeys.importBackup,
          onPressed: auth.isBusy
              ? null
              : () => unawaited(showBackupImportFlow(context, auth: auth)),
          icon: AppIcons.download,
          label: l10n.backupImportEntry,
        ),
        if (!empty)
          AppActionButton(
            key: ConnectFormKeys.addServer,
            onPressed: auth.isBusy ? null : _startNewServer,
            icon: AppIcons.add,
            label: l10n.addServer,
          ),
      ],
    );
    if (empty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [actions],
      );
    }
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            l10n.savedServers,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            '${auth.savedServers.length}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
    // 放得下时标题与入口同一行,窄栏下入口整组折到标题下方。
    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [title, actions],
    );
    final search = auth.savedServers.length > 6
        ? Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppTextField(
              key: ConnectFormKeys.serverSearch,
              onChanged: (value) => setState(() => _serverQuery = value),
              placeholder: l10n.searchServers,
              prefix: const Icon(
                AppIcons.search,
                fill: AppIcons.filled,
                size: 20,
              ),
            ),
          )
        : null;
    Widget card(int index) =>
        _buildServerCard(context, l10n, auth, servers[index]);
    Widget separator(BuildContext context, int index) =>
        const SizedBox(height: AppSpacing.xs);
    if (fill) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.xxs,
              bottom: AppSpacing.sm,
            ),
            child: Text(
              l10n.loginSavedServersHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          ?search,
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              itemCount: servers.length,
              separatorBuilder: separator,
              itemBuilder: (context, index) => card(index),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: AppSpacing.sm),
        ?search,
        SizedBox(
          height: auth.savedServers.length > 4 ? 320 : null,
          child: ListView.separated(
            shrinkWrap: auth.savedServers.length <= 4,
            physics: auth.savedServers.length <= 4
                ? const NeverScrollableScrollPhysics()
                : null,
            itemCount: servers.length,
            separatorBuilder: separator,
            itemBuilder: (context, index) => card(index),
          ),
        ),
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

  /// 紧凑服务器卡:类型标记、名称、「账号 · 当前线路」。多线路时卡尾是
  /// 「N 条线路」展开钮,展开后才列出各条线路;点线路把地址填进表单。
  Widget _buildServerCard(
    BuildContext context,
    AppLocalizations l10n,
    AuthController auth,
    SavedServer server,
  ) {
    final theme = AppUiTheme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = server.id == _selectedServerId;
    final multiLine = server.lines.length > 1;
    final expanded = multiLine && _expandedServers.contains(server.id);
    ServerLine? line = server.activeLine;
    if (selected) {
      for (final candidate in server.lines) {
        if (candidate.id == _selectedLineId) {
          line = candidate;
          break;
        }
      }
    }
    final lineLabel = line == null ? server.baseUrl : serverLineLabel(line);
    final subtitle = server.username.isEmpty
        ? lineLabel
        : '${server.username} · $lineLabel';

    return AnimatedContainer(
      duration: AppMotion.durationOf(context, AppMotion.fast),
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainer.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(
          color: selected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: .7),
          width: selected ? AppSelectionDecoration.borderWidth : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppSurfaceAction(
                  key: Key('saved-server-${server.id}'),
                  onTap: auth.isBusy ? null : () => _selectSaved(server),
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        ServerTypeMark(type: server.serviceType, size: 32),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                server.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: selected
                                      ? colorScheme.onPrimaryContainer
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Icon(
                            AppIcons.checkCircle,
                            fill: AppIcons.filled,
                            color: colorScheme.onPrimaryContainer,
                            size: 20,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (multiLine)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: Semantics(
                    expanded: expanded,
                    child: AppActionButton(
                      key: ConnectFormKeys.savedServerLines(server.id),
                      icon: AppIcons.route,
                      trailingIcon: expanded
                          ? AppIcons.chevronUp
                          : AppIcons.chevronDown,
                      label: l10n.lineCount(server.lines.length),
                      onPressed: () => setState(() {
                        if (!_expandedServers.remove(server.id)) {
                          _expandedServers.add(server.id);
                        }
                      }),
                    ),
                  ),
                ),
            ],
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.onSurface.withValues(alpha: .04),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    children: [
                      for (final line in server.lines)
                        _buildLineTile(context, auth, server, line, selected),
                    ],
                  ),
                ),
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
    final theme = AppUiTheme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = serverSelected && line.id == _selectedLineId;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colorScheme.primaryContainer : AppInk.transparent,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: selected ? colorScheme.primary : AppInk.transparent,
            width: selected ? AppSelectionDecoration.borderWidth : 1,
          ),
        ),
        child: AppSurfaceAction(
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
                  AppIcons.route,
                  fill: AppIcons.filled,
                  size: 18,
                  color: selected
                      ? colorScheme.onPrimaryContainer
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
                  Icon(
                    AppIcons.check,
                    fill: AppIcons.filled,
                    color: colorScheme.onPrimaryContainer,
                    size: 18,
                  ),
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
      // User-Agent is server-level; selecting a line only changes the address.
      _userAgent.text = server.normalizedUserAgent ?? '';
      _username.text = server.username;
      _password.clear();
      _saveDraft();
    });
    _loadPassword(server.id);
  }
}

/// 三种服务的小标签:标记 + 名称,说明这里能连哪些服务器。
class _SupportedServices extends StatelessWidget {
  const _SupportedServices();

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final type in MediaServerType.values)
          Container(
            padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .6),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ServerTypeMark(type: type, size: 20),
                const SizedBox(width: 8),
                Text(
                  type.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 宽窗口左栏:品牌、欢迎语、支持的服务,下方是已保存的服务器。
class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.l10n, required this.savedServers});

  final AppLocalizations l10n;
  final Widget savedServers;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      key: const ValueKey('connect-hero-panel'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.huge,
          AppSpacing.huge,
          AppSpacing.xxxl,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const LoginBrandMark(size: 40),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  l10n.appName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.huge),
            Text(
              l10n.loginWelcomeTitle,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.loginWelcomeSubtitle,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const _SupportedServices(),
            const SizedBox(height: AppSpacing.xxl),
            Expanded(child: savedServers),
          ],
        ),
      ),
    );
  }
}

/// 窄窗口品牌头:品牌方块 + 应用名 + 一句说明。
class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        const LoginBrandMark(size: 52),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.appName,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          l10n.loginWelcomeSubtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
