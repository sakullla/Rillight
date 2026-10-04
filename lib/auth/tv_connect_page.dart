import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/tv_lan_pair.dart';
import 'package:rillight/app/tv_widgets.dart';

/// Remote connection flow; credentials remain owned by the auth draft.
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
  ConnectDraft? _draft;
  TvLanAssist? _lan;
  bool _openingLan = false;

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

  void _select(SavedServer server) {
    _draft!
      ..selectedServerId = server.id
      ..selectedLineId = server.activeLine?.id;
    _address.text = server.baseUrl;
    _username.text = server.username;
    _password.clear();
    _userAgent.text = server.normalizedUserAgent ?? '';
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

  void _onLan() {
    if (mounted) {
      setState(() {});
    }
  }

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
    for (final field in [_address, _username, _password, _userAgent]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    final appearance = AppearanceScope.maybeOf(context);
    return TvFrame(
      title: l10n.connectTitle,
      back: widget.addingAnother,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: AppViewport.dp(680, MediaQuery.sizeOf(context)),
          ),
          child: ListenableBuilder(
            listenable: appearance == null
                ? auth
                : Listenable.merge([auth, appearance]),
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
                const SizedBox(height: 8),
                // TV 外观三态:方向键在三个选项间移动,选中即生效并持久化。
                Text(l10n.settingsAppearance),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final value in AppearanceStyle.values) ...[
                      TvAction(
                        key: Key('tv-appearance-${value.name}'),
                        selected:
                            (appearance?.style ?? AppearanceStyle.system) ==
                            value,
                        onPressed: appearance == null
                            ? null
                            : () => appearance.setStyle(value),
                        child: Text(value.label(l10n)),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
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
                const SizedBox(height: 16),
                ..._lanSection(l10n, auth.isBusy),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 遥控器登录在前,手机辅助在后。证书警告过不去时只说明未完成。
  List<Widget> _lanSection(AppLocalizations l10n, bool busy) {
    final lan = _lan;
    final phase = lan?.phase ?? TvLanPhase.idle;
    final offer = lan?.offer;
    final pending = lan?.pending;
    if (_openingLan || (phase == TvLanPhase.waiting && offer == null)) {
      return [Text(l10n.tvLanWaiting)];
    }
    if (phase == TvLanPhase.waiting && offer != null) {
      return [_TvLanWaiting(offer: offer, lan: lan!, expiresAt: lan.expiresAt)];
    }
    if (phase == TvLanPhase.pending && pending != null) {
      return [
        _TvLanPending(
          pending: pending,
          busy: busy,
          onConfirm: _confirmLan,
          onReject: lan!.reject,
        ),
      ];
    }
    return [
      if (phase == TvLanPhase.expired)
        Text(l10n.tvLanExpired, key: const Key('tv-lan-expired')),
      if (phase == TvLanPhase.failed)
        Text(l10n.tvLanFailed, key: const Key('tv-lan-failed')),
      TvAction(
        key: const Key('tv-lan-assist'),
        onPressed: busy || _openingLan ? null : _openLan,
        child: Text(l10n.tvLanAssist),
      ),
    ];
  }
}

/// 节标题:图标 + 加粗标题,与设置面板的分节节奏一致。
class _TvLanHeader extends StatelessWidget {
  const _TvLanHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 等待手机扫码:左侧说明/有效期/地址/指纹,右侧白底圆角二维码卡。
class _TvLanWaiting extends StatelessWidget {
  const _TvLanWaiting({
    required this.offer,
    required this.lan,
    required this.expiresAt,
  });

  final TvLanOffer offer;
  final TvLanAssist lan;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final mono = theme.textTheme.bodySmall?.copyWith(letterSpacing: .2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TvLanHeader(icon: Icons.qr_code_2_rounded, title: l10n.tvLanScanTitle),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.tvLanScanHint, style: secondary),
                  if (expiresAt != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.tvLanValidUntil(_lanClock(expiresAt!)),
                          key: const Key('tv-lan-expires'),
                          style: secondary,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(l10n.tvLanAddress, style: label),
                  const SizedBox(height: 2),
                  SelectableText(
                    offer.manualUrl,
                    key: const Key('tv-lan-address'),
                    style: mono,
                  ),
                  const SizedBox(height: 10),
                  Text(l10n.tvLanFingerprint, style: label),
                  const SizedBox(height: 2),
                  SelectableText(
                    offer.fingerprint,
                    key: const Key('tv-lan-fingerprint'),
                    style: mono?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 18,
                    offset: Offset(0, 6),
                    color: Color(0x33000000),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(14),
              child: TvLanQrImage(
                key: const Key('tv-lan-qr'),
                modules: offer.qrModules,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TvAction(
          key: const Key('tv-lan-incomplete'),
          onPressed: lan.markIncomplete,
          child: Text(l10n.tvLanFailed),
        ),
      ],
    );
  }
}

/// 手机已提交:卡片内复核服务器与账号,确认/拒绝胶囊按钮。
class _TvLanPending extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TvLanHeader(
          icon: Icons.phonelink_lock_rounded,
          title: l10n.tvLanPendingTitle,
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.dns_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pending.server,
                      key: const Key('tv-lan-server'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pending.account,
                      key: const Key('tv-lan-account'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TvAction(
              key: const Key('tv-lan-confirm'),
              emphasized: true,
              pill: true,
              onPressed: busy ? null : onConfirm,
              child: Text(l10n.tvLanConfirm),
            ),
            const SizedBox(width: 8),
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
