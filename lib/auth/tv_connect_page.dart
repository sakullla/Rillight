import 'tv_server_selection_page.dart';
import 'provider_login_form.dart';
import '../media_server/capabilities.dart';

import 'package:rillight/app/ui/ui.dart';

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/tv_lan_pair.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// Remote connection flow; credentials remain owned by the auth draft.
///
/// 版式:左侧是品牌、说明、外观与已保存服务器(或手机辅助的二维码/确认),
/// 右侧是一张表单卡:地址 → 用户名 → 密码 → User-Agent → 连接,遥控器一路
/// 向下即可完成;卡片底部是手机辅助连接入口。
class TvConnectPage extends StatefulWidget {
  const TvConnectPage({
    super.key,
    this.addingAnother = false,
    this.createLanAssist,
  });

  final bool addingAnother;

  /// 测试注入本机回环地址。正式界面在用户打开辅助后自行创建。
  final TvLanAssist Function()? createLanAssist;

  @override
  State<TvConnectPage> createState() => _TvConnectPageState();
}

class _TvConnectPageState extends State<TvConnectPage> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _userAgent = TextEditingController();
  final _assistFocus = FocusNode(debugLabel: 'tv-lan-assist');
  final _submitFocus = FocusNode(debugLabel: 'tv-connect-submit');
  ConnectDraft? _draft;
  TvLanAssist? _lan;
  bool _openingLan = false;
  bool _authBusy = false;
  TvLanPhase _seenLan = TvLanPhase.idle;

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
      draft.userAgent = server.normalizedUserAgent ?? '';
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

  Future<void> _submit() async {
    final auth = AuthScope.of(context);
    if (auth.isBusy) return;
    final selected = auth.savedServers
        .where((s) => s.id == _draft?.selectedServerId)
        .firstOrNull;

    FocusScope.of(context).unfocus();
    await auth.connect(
      address: _address.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      userAgent: _userAgent.text,
      lineId: selected?.serviceType == MediaServerType.emby
          ? _draft?.selectedLineId
          : null,
    );
    if (mounted && auth.isLoggedIn && widget.addingAnother) context.go('/');
  }

  void _onLan() {
    final phase = _lan?.phase ?? TvLanPhase.idle;
    final previous = _seenLan;
    _seenLan = phase;
    if (mounted) {
      setState(() {});
    }
    if (_lanHandsBack(phase) && !_lanHandsBack(previous)) {
      _focusLater(_assistFocus);
    }
  }

  void _noteAuth(bool busy, Object? failure) {
    final wasBusy = _authBusy;
    if (wasBusy == busy) return;
    _authBusy = busy;
    if (wasBusy && !busy && failure != null && !_lanHandsBack(_lan?.phase)) {
      _focusLater(_submitFocus);
    }
  }

  /// 禁用按钮会退出焦点树，同帧里最近的控件往往是「连接」。
  /// 晚一帧再要焦点，等新按钮已经能接收遥控器。
  void _focusLater(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !node.canRequestFocus) return;
        node.requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      });
    });
  }

  bool _lanHandsBack(TvLanPhase? phase) =>
      phase == TvLanPhase.expired ||
      phase == TvLanPhase.failed ||
      phase == TvLanPhase.rejected ||
      phase == TvLanPhase.cancelled;

  Future<void> _openLan() async {
    if (_openingLan) {
      return;
    }
    final current = _lan;
    if (current != null && !current.isTerminal) {
      return;
    }
    _openingLan = true;
    current?.removeListener(_onLan);
    current?.dispose();
    final lan = widget.createLanAssist?.call() ?? TvLanAssist();
    lan.addListener(_onLan);
    _lan = lan;
    if (mounted) {
      setState(() {});
    }
    await lan.open();
    _openingLan = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _confirmLan() async {
    final lan = _lan;
    if (lan == null) {
      return;
    }
    final auth = AuthScope.of(context);
    final accepted = await lan.confirm(auth);
    if (mounted && accepted && widget.addingAnother) {
      context.go('/');
    }
  }

  @override
  void dispose() {
    _lan?.removeListener(_onLan);
    _lan?.dispose();
    _assistFocus.dispose();
    _submitFocus.dispose();
    for (final field in [_address, _username, _password, _userAgent]) {
      field.dispose();
    }
    super.dispose();
  }

  bool get _lanActive {
    final lan = _lan;
    if (_openingLan) return true;
    if (lan == null) return false;
    return lan.phase == TvLanPhase.waiting ||
        lan.phase == TvLanPhase.pending ||
        lan.phase == TvLanPhase.connecting;
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    _noteAuth(auth.isBusy, auth.failure);
    final l10n = AppLocalizations.of(context);
    final appearance = AppearanceScope.maybeOf(context);
    return TvFrame(
      title: l10n.connectTitle,
      edgeToEdge: true,
      child: ListenableBuilder(
        listenable: appearance == null
            ? auth
            : Listenable.merge([auth, appearance]),
        builder: (context, _) {
          final theme = AppUiTheme.of(context);
          final scheme = theme.colorScheme;
          final size = MediaQuery.sizeOf(context);
          final s = TvDesign.scaleOf(context);
          final gutter = tvSafeGutter(size.width);
          final vertical = tvSafeVertical(size.height);
          return DecoratedBox(
            key: const ValueKey('tv-connect-background'),
            decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter, vertical, gutter, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.only(
                          right: 24 * s,
                          bottom: vertical,
                        ),
                        clipBehavior: Clip.none,
                        children: [
                          _Brand(name: l10n.appName),
                          SizedBox(height: 28 * s),
                          Text(
                            l10n.connectTitle,
                            style: theme.textTheme.displaySmall,
                          ),
                          SizedBox(height: 8 * s),
                          Text(
                            l10n.tvConnectHint,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          SizedBox(height: 24 * s),
                          // 备份导入:无服务与已有服务都可用,遥控可聚焦。
                          TvNavTile(
                            actionKey: const ValueKey('tv-connect-import'),
                            icon: AppIcons.download,
                            title: l10n.backupImportEntry,
                            onPressed: auth.isBusy
                                ? null
                                : () => unawaited(
                                    showBackupImportFlow(context, auth: auth),
                                  ),
                          ),
                          SizedBox(height: 18 * s),
                          if (_lanActive)
                            ..._lanSection(l10n, auth.isBusy)
                          else ...[
                            if (auth.savedServers.isNotEmpty) ...[
                              TvSectionTitle(l10n.savedServers),
                              SizedBox(height: 4 * s),
                              TvNavTile(
                                actionKey: const Key('tv-connect-servers'),
                                icon: AppIcons.server,
                                title: l10n.serversTitle,
                                onPressed: () => showTvServerSelection(
                                  context,
                                  auth: auth,
                                  onEntered: () async {
                                    if (mounted) context.go('/');
                                  },
                                ),
                              ),
                              SizedBox(height: 18 * s),
                            ],
                            TvSectionTitle(l10n.settingsAppearance),
                            SizedBox(height: 6 * s),
                            const TvAppearancePicker(),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: 24 * s),
                    SizedBox(
                      width: 400 * s,
                      child: SingleChildScrollView(
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.only(bottom: vertical),
                        child: _formCard(context, l10n),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _formCard(BuildContext context, AppLocalizations l10n) {
    final auth = AuthScope.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final lan = _lan;
    final phase = lan?.phase ?? TvLanPhase.idle;
    return Container(
      padding: EdgeInsets.all(20 * s),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadii.overlay * s),
        border: Border.all(color: AppEdge.of(theme.brightness)),
        boxShadow: AppShadow.overlay(theme.brightness),
      ),
      child: ProviderLoginForm(
        userAgent: () => _userAgent.text,
        selectedServer: auth.savedServers
            .where((s) => s.id == _draft?.selectedServerId)
            .firstOrNull,
        embyForm: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvInput(
              key: const Key('tv-connect-address'),
              label: l10n.serverAddress,
              controller: _address,
              placeholder: 'https://emby.example.com',
              keyboardType: TextInputType.url,
              leading: const Icon(AppIcons.link, fill: AppIcons.filled),
              autofocus: true,
            ),
            SizedBox(height: 8 * s),
            TvInput(
              key: const Key('tv-connect-username'),
              label: l10n.username,
              controller: _username,
              leading: const Icon(AppIcons.person, fill: AppIcons.filled),
            ),
            SizedBox(height: 8 * s),
            TvInput(
              key: const Key('tv-connect-password'),
              label: l10n.password,
              controller: _password,
              leading: const Icon(AppIcons.lock, fill: AppIcons.filled),
              secret: true,
            ),
            SizedBox(height: 8 * s),
            TvInput(
              label: l10n.tvUserAgentOptional,
              controller: _userAgent,
              leading: const Icon(AppIcons.badge, fill: AppIcons.filled),
            ),
            if (auth.failure != null) ...[
              SizedBox(height: 12 * s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    AppIcons.error,
                    fill: AppIcons.filled,
                    size: 18 * s,
                    color: scheme.error,
                  ),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      embyFailureMessage(l10n, auth.failure!),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            SizedBox(height: 16 * s),
            TvAction(
              key: const Key('tv-connect-submit'),
              emphasized: true,
              pill: true,
              expand: true,
              focusNode: _submitFocus,
              leading: Icon(
                auth.failure != null ? AppIcons.refresh : AppIcons.play,
                fill: AppIcons.filled,
              ),
              onPressed: auth.isBusy ? null : _submit,
              child: Center(
                child: Text(
                  auth.isBusy
                      ? l10n.connecting
                      : auth.failure != null
                      ? l10n.retry
                      : l10n.connect,
                ),
              ),
            ),
            SizedBox(height: 14 * s),
            Row(
              children: [
                Expanded(child: AppDivider(color: scheme.outlineVariant)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10 * s),
                  child: Text(
                    l10n.tvConnectOr,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: AppDivider(color: scheme.outlineVariant)),
              ],
            ),
            SizedBox(height: 10 * s),
            if (phase == TvLanPhase.expired)
              Padding(
                padding: EdgeInsets.only(bottom: 8 * s),
                child: Text(
                  l10n.tvLanExpired,
                  key: const Key('tv-lan-expired'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            if (phase == TvLanPhase.failed)
              Padding(
                padding: EdgeInsets.only(bottom: 8 * s),
                child: Text(
                  l10n.tvLanFailed,
                  key: const Key('tv-lan-failed'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            TvAction(
              key: const Key('tv-lan-assist'),
              expand: true,
              focusNode: _assistFocus,
              leading: const Icon(AppIcons.qrCode, fill: AppIcons.filled),
              onPressed: auth.isBusy || _openingLan || _lanActive
                  ? null
                  : _openLan,
              child: Text(l10n.tvLanAssist),
            ),
          ],
        ),
      ),
    );
  }

  /// 手机辅助进行中:二维码与配对信息,或手机提交后的确认。
  List<Widget> _lanSection(AppLocalizations l10n, bool busy) {
    final lan = _lan;
    final phase = lan?.phase ?? TvLanPhase.idle;
    final offer = lan?.offer;
    final pending = lan?.pending;
    if (_openingLan || (phase == TvLanPhase.waiting && offer == null)) {
      return [
        Row(
          children: [
            SizedBox.square(
              dimension: context.tvdp(18),
              child: const CupertinoActivityIndicator(),
            ),
            SizedBox(width: context.tvdp(10)),
            Text(l10n.tvLanWaiting),
          ],
        ),
      ];
    }
    if (phase == TvLanPhase.waiting && offer != null) {
      return [_TvLanWaiting(offer: offer, lan: lan!, expiresAt: lan.expiresAt)];
    }
    if ((phase == TvLanPhase.pending || phase == TvLanPhase.connecting) &&
        pending != null) {
      return [
        _TvLanPending(
          pending: pending,
          busy: busy,
          onConfirm: _confirmLan,
          onReject: lan!.reject,
        ),
      ];
    }
    return const [];
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    return Row(
      children: [
        Container(
          key: const ValueKey('tv-connect-brand-mark'),
          width: 30 * s,
          height: 30 * s,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm * s),
            color: theme.colorScheme.primary,
          ),
          child: Icon(
            AppIcons.play,
            fill: AppIcons.filled,
            size: 22 * s,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        SizedBox(width: 10 * s),
        Text(name, style: theme.textTheme.titleLarge),
      ],
    );
  }
}

/// 节标题:图标 + 加粗标题。
class _TvLanHeader extends StatelessWidget {
  const _TvLanHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    return Row(
      children: [
        Icon(
          icon,
          fill: AppIcons.filled,
          size: 20 * s,
          color: theme.colorScheme.primary,
        ),
        SizedBox(width: 8 * s),
        Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
      ],
    );
  }
}

/// 等待手机扫码:左侧白底二维码,右侧说明、有效期、地址与指纹。
///
/// 打开扫码会禁用「手机辅助连接」。若不再指定焦点，遥控器会落到紧挨着的
/// 「连接」上，按确认就会用表单登录。这里把焦点放在不会取消、也不会登录的
/// 等待状态上。
class _TvLanWaiting extends StatefulWidget {
  const _TvLanWaiting({
    required this.offer,
    required this.lan,
    required this.expiresAt,
  });

  final TvLanOffer offer;
  final TvLanAssist lan;
  final DateTime? expiresAt;

  @override
  State<_TvLanWaiting> createState() => _TvLanWaitingState();
}

class _TvLanWaitingState extends State<_TvLanWaiting> {
  final _holdFocus = FocusNode(debugLabel: 'tv-lan-waiting');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_holdFocus.canRequestFocus) return;
        _holdFocus.requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      });
    });
  }

  @override
  void dispose() {
    _holdFocus.dispose();
    super.dispose();
  }

  void _keepWaiting() {}

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final lan = widget.lan;
    final expiresAt = widget.expiresAt;
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final mono = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TvLanHeader(icon: AppIcons.qrCode, title: l10n.tvLanScanTitle),
        SizedBox(height: 12 * s),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 156 * s,
              height: 156 * s,
              decoration: BoxDecoration(
                color: AppInk.white,
                borderRadius: BorderRadius.circular(AppRadii.card * s),
              ),
              padding: EdgeInsets.all(10 * s),
              child: TvLanQrImage(
                key: const Key('tv-lan-qr'),
                modules: offer.qrModules,
              ),
            ),
            SizedBox(width: 18 * s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.tvLanScanHint, style: secondary),
                  if (expiresAt != null) ...[
                    SizedBox(height: 10 * s),
                    Row(
                      children: [
                        Icon(
                          AppIcons.schedule,
                          fill: AppIcons.filled,
                          size: 16 * s,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        SizedBox(width: 6 * s),
                        Flexible(
                          child: Text(
                            l10n.tvLanValidUntil(_lanClock(expiresAt)),
                            key: const Key('tv-lan-expires'),
                            style: secondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 14 * s),
        Text(l10n.tvLanAddress, style: label),
        AppSelectableText(
          offer.manualUrl,
          key: const Key('tv-lan-address'),
          style: mono,
        ),
        SizedBox(height: 14 * s),
        TvAction(
          key: const Key('tv-lan-waiting'),
          focusNode: _holdFocus,
          pill: true,
          emphasized: true,
          leading: const Icon(AppIcons.schedule, fill: AppIcons.filled),
          onPressed: _keepWaiting,
          child: Text(l10n.tvLanWaiting),
        ),
        SizedBox(height: 10 * s),
        TvAction(
          key: const Key('tv-lan-incomplete'),
          pill: true,
          leading: const Icon(AppIcons.close, fill: AppIcons.filled),
          onPressed: lan.markIncomplete,
          child: Text(l10n.cancelAction),
        ),
      ],
    );
  }
}

/// 手机已提交:复核服务器与账号,确认/拒绝。
///
/// 等待页和右侧地址栏在提交前已经占着焦点。后插入的按钮只设 autofocus
/// 不会改掉已有焦点,所以确认按钮出现后要自己把遥控器焦点要过来。
class _TvLanPending extends StatefulWidget {
  const _TvLanPending({
    required this.pending,
    required this.busy,
    required this.onConfirm,
    required this.onReject,
  });

  final TvLanSubmission pending;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  State<_TvLanPending> createState() => _TvLanPendingState();
}

class _TvLanPendingState extends State<_TvLanPending> {
  final _confirmFocus = FocusNode(debugLabel: 'tv-lan-confirm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_confirmFocus.canRequestFocus) return;
      _confirmFocus.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    });
  }

  @override
  void dispose() {
    _confirmFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final busy = widget.busy;
    final onConfirm = widget.onConfirm;
    final onReject = widget.onReject;
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    Widget line(IconData icon, String text, Key key) => Padding(
      padding: EdgeInsets.only(bottom: 8 * s),
      child: Row(
        children: [
          Icon(
            icon,
            fill: AppIcons.filled,
            size: 18 * s,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          SizedBox(width: 10 * s),
          Expanded(
            child: Text(
              text,
              key: key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TvLanHeader(icon: AppIcons.shield, title: l10n.tvLanPendingTitle),
        SizedBox(height: 12 * s),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadii.card * s),
          ),
          padding: EdgeInsets.fromLTRB(16 * s, 14 * s, 16 * s, 6 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              line(AppIcons.server, pending.server, const Key('tv-lan-server')),
              line(
                AppIcons.person,
                pending.account,
                const Key('tv-lan-account'),
              ),
              if (pending.userAgent != null)
                line(
                  AppIcons.badge,
                  '${l10n.userAgent}: ${pending.userAgent}',
                  const Key('tv-lan-user-agent'),
                ),
            ],
          ),
        ),
        SizedBox(height: 14 * s),
        Row(
          children: [
            TvAction(
              key: const Key('tv-lan-confirm'),
              emphasized: true,
              pill: true,
              autofocus: true,
              focusNode: _confirmFocus,
              leading: const Icon(AppIcons.check, fill: AppIcons.filled),
              onPressed: busy ? null : onConfirm,
              child: Text(l10n.tvLanConfirm),
            ),
            SizedBox(width: 10 * s),
            TvAction(
              key: const Key('tv-lan-reject'),
              pill: true,
              onPressed: busy ? null : onReject,
              child: Text(l10n.tvLanReject),
            ),
          ],
        ),
      ],
    );
  }
}

String _lanClock(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
