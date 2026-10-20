import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/errors.dart';
import 'connection_failure.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';
import 'server_ui.dart';

/// 列表里的紧凑主机名:超长时省略中间的主机部分并加省略号,
/// 避免整串地址把线路芯片撑爆成 "captur…"。完整地址仍见于编辑页。
String serverLineHostLabel(ServerLine line) {
  final uri = Uri.tryParse(line.address);
  final host = (uri?.host.isNotEmpty == true ? uri!.host : line.hostLabel)
      .trim();
  final port = uri?.hasPort == true ? uri!.port : null;
  // 默认端口不重复显示;hostLabel 本身已带端口时也不再追加。
  final tail = (port == null || port == 80 || port == 443) ? '' : ':$port';
  final bare = tail.isEmpty ? host : host.replaceFirst(RegExp(r':\d+$'), '');
  final labels = bare.split('.').where((part) => part.isNotEmpty).toList();
  // 域名比预算长时保留最后两段(capture-mirror.test → mirror.test),
  // 去掉没有辨识价值的前导子域;仍超长才省略前缀。
  String name;
  if (labels.length > 2 &&
      (bare.length + tail.length) > _serverLineHostBudget) {
    name = labels.sublist(labels.length - 2).join('.');
  } else {
    name = bare;
  }
  final withPort = '$name$tail';
  if (withPort.length <= _serverLineHostBudget) return withPort;
  final keep = _serverLineHostBudget - tail.length - 1;
  if (keep <= 1) return withPort;
  return '${withPort.substring(0, keep)}…$tail';
}

/// 线路芯片里主机名连端口的显示预算,超出即省略。
///
/// 无昵称时标签就是主机名本身,芯片里约 130px 可用,约合 22 个西文字符。
/// 取 22 让"capture-mirror.test:8096"这类常见地址完整显示,
/// 只把真正超长的多级子域收成省略号。
const int _serverLineHostBudget = 22;

String serverLineLabel(ServerLine line) =>
    line.nickname?.trim().isNotEmpty == true
    ? line.nickname!
    : serverLineHostLabel(line);
String serverSafeAddress(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null || uri.host.isEmpty) return '';
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

String serverLineSummary(AppLocalizations l, SavedServer server) {
  final active = server.activeLine;
  if (active == null) return '—';
  if (!server.lineSelection.isAutomatic) return serverLineLabel(active);
  // 昵称是用户自己起的短名字,照常显示,只在前面标出当前模式。
  final nickname = active.nickname?.trim();
  if (nickname != null && nickname.isNotEmpty) {
    return '${l.serversAutomatic} · $nickname';
  }
  // 没有昵称时只显示紧凑主机名:"自动选择 · "这六个字在 360dp 上要占掉
  // 半个芯片,后面真正有用的主机名就会被 ellipsis 砍成"captur…"。
  // 自动模式由芯片上的闪电图标表达,文字里不必重复。
  return serverLineHostLabel(active);
}

String serverOperationFailure(
  AppLocalizations l,
  Object error, {
  String? fallback,
}) => switch (connectionFailure(error).kind) {
  MediaServerFailureKind.invalidAddress => l.errorInvalidAddress,
  MediaServerFailureKind.invalidCredentials => l.providerCredentialsRejected,
  MediaServerFailureKind.sessionExpired ||
  MediaServerFailureKind.authorizationExpired => l.serversCheckLogin,
  MediaServerFailureKind.incompatibleServer => l.serversCheckIdentity,
  MediaServerFailureKind.certificate => l.providerCertificateFailure,
  MediaServerFailureKind.forbidden => l.providerPermissionDenied,
  MediaServerFailureKind.rateLimited => l.providerRateLimited,
  MediaServerFailureKind.timeout => l.errorTimeout,
  MediaServerFailureKind.unreachable => l.errorUnreachable,
  _ => fallback ?? l.serversSaveFailed,
};

/// Legacy feedback surface kept for TV and form steps; the visual treatment is
/// shared with [ServerFeedbackCard] so the same failure does not change shape
/// between the list and a child page.
class ServerFeedback extends StatelessWidget {
  const ServerFeedback(this.message, {super.key, this.error = true});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) =>
      ServerFeedbackCard(message, error: error);
}

/// Provider-coloured identity tile. The editor, TV rows and the server hub all
/// use this mark so one server is recognisable across presentations.
class ServerIdentityIcon extends StatelessWidget {
  const ServerIdentityIcon(this.server, {super.key, this.size = 44});
  final SavedServer server;
  final double size;
  @override
  Widget build(BuildContext context) =>
      ServerAvatar(server: server, size: size);
}

/// Health of the line a server would use now, from the last saved check.
ServerTone? serverLineHealth(ServerLine? line) {
  if (line == null || line.checkedAt == null) return null;
  if (line.checkFailureKind != null) return ServerTone.error;
  return switch (line.checkStatus) {
    'success' || 'available' || 'online' => ServerTone.success,
    'identityMismatch' || 'needsLogin' => ServerTone.warning,
    'unknown' => null,
    _ => ServerTone.error,
  };
}

/// Three distinct targets: enter, choose a connection, and organize. None of
/// them expands the server card into an editor.
///
/// Layout: avatar · name and one status line · line chip; the ⋯ menu sits at
/// the trailing edge. The current server is tinted and tagged once; problems
/// add a dot and a short phrase next to the server they belong to.
class ServerSelectionTile extends StatefulWidget {
  const ServerSelectionTile({
    super.key,
    required this.server,
    required this.current,
    required this.locked,
    required this.onEnter,
    required this.onLines,
    required this.onAction,
    this.busy = false,
    this.error,
    this.focusNode,
    this.needsLogin = false,
    this.canMoveUp = false,
    this.canMoveDown = false,
  });
  final SavedServer server;
  final bool current, locked, busy, canMoveUp, canMoveDown;
  final VoidCallback onEnter, onLines;
  final ValueChanged<String> onAction;
  final String? error;
  final FocusNode? focusNode;
  final bool needsLogin;
  @override
  State<ServerSelectionTile> createState() => _ServerSelectionTileState();
}

class _ServerSelectionTileState extends State<ServerSelectionTile> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final server = widget.server;

    // One status line: the most important fact about this server.
    final (ServerTone, String, bool) status = widget.busy
        ? (ServerTone.current, l.serversBusy, false)
        : widget.locked
        ? (ServerTone.neutral, l.serversLockedHint, false)
        : widget.needsLogin
        ? (ServerTone.warning, l.serversNoAccount, true)
        : widget.error != null
        ? (ServerTone.error, l.serversConnectionError, true)
        : (
            ServerTone.neutral,
            server.username.isEmpty
                ? server.serviceType.label
                : '${server.serviceType.label} · ${server.username}',
            false,
          );
    final (statusTone, statusText, statusDot) = status;
    final background = widget.current
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: dark ? .10 : .055),
            ServerUi.groupColor(colors),
          )
        : ServerUi.groupColor(colors);
    final health = widget.locked ? null : serverLineHealth(server.activeLine);
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: hovered && !widget.busy
              ? Color.alphaBlend(
                  colors.onSurface.withValues(alpha: .03),
                  background,
                )
              : background,
          borderRadius: BorderRadius.circular(ServerUi.cardRadius + 2),
          border: Border.all(
            color: widget.current
                ? colors.primary.withValues(alpha: dark ? .38 : .28)
                : widget.error != null
                ? colors.error.withValues(alpha: .35)
                : ServerUi.groupStroke(colors),
            width: widget.current ? 1 : .6,
          ),
          boxShadow: hovered && !widget.busy
              ? [
                  BoxShadow(
                    color: colors.scrim.withValues(alpha: dark ? .32 : .10),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppSurfaceAction(
                    key: Key('server-enter-${server.id}'),
                    focusNode: widget.focusNode,
                    onTap: widget.busy ? null : widget.onEnter,
                    borderRadius: BorderRadius.circular(
                      ServerUi.cardRadius + 2,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ServerAvatar(
                            server: server,
                            locked: widget.locked,
                            size: 50,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        server.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: -.2,
                                            ),
                                      ),
                                    ),
                                    if (widget.current) ...[
                                      const SizedBox(width: 8),
                                      ServerStatusPill(
                                        label: l.serversCurrent,
                                        tone: ServerTone.current,
                                        icon: AppIcons.checkCircle,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (widget.busy) ...[
                                      Icon(
                                        AppIcons.hourglass,
                                        size: 13,
                                        color: colors.primary,
                                      ),
                                      const SizedBox(width: 5),
                                    ] else if (widget.locked) ...[
                                      Icon(
                                        AppIcons.lock,
                                        size: 13,
                                        color: colors.onSurfaceVariant,
                                        fill: AppIcons.filled,
                                      ),
                                      const SizedBox(width: 5),
                                    ] else if (statusDot) ...[
                                      ServerStatusDot(tone: statusTone),
                                      const SizedBox(width: 6),
                                    ],
                                    Expanded(
                                      child: Text(
                                        statusText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: statusDot || widget.busy
                                                  ? serverToneColor(
                                                      colors,
                                                      statusTone,
                                                    )
                                                  : colors.onSurfaceVariant,
                                              fontWeight:
                                                  statusDot || widget.busy
                                                  ? FontWeight.w600
                                                  : null,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                // 横向撑满内容列:Column 是 start 对齐,芯片按内容
                                // 收缩时 Flexible 只拿到很小的宽度,长线路名被截断。
                                SizedBox(
                                  width: double.infinity,
                                  child: _ServerLineChip(
                                    key: Key('server-lines-${server.id}'),
                                    label: widget.locked
                                        ? l.serversLines
                                        : serverLineSummary(l, server),
                                    icon: widget.locked
                                        ? AppIcons.lock
                                        : server.lineSelection.isAutomatic
                                        ? AppIcons.bolt
                                        : AppIcons.route,
                                    health: health,
                                    onTap: widget.busy ? null : widget.onLines,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 6),
                  child: AppMenuButton<String>(
                    key: Key('server-more-${server.id}'),
                    tooltip: l.serversMore,
                    items: [
                      AppMenuEntry(
                        key: Key('server-action-edit-${server.id}'),
                        value: 'edit',
                        child: Text(l.serversEdit),
                      ),
                      if (widget.canMoveUp)
                        AppMenuEntry(value: 'up', child: Text(l.serversUp)),
                      if (widget.canMoveDown)
                        AppMenuEntry(value: 'down', child: Text(l.serversDown)),
                      AppMenuEntry(
                        key: Key('server-action-remove-${server.id}'),
                        value: 'remove',
                        child: Text(
                          l.serversRemove,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    ],
                    onSelected: widget.busy ? null : widget.onAction,
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      AppIcons.more,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: ServerFeedbackCard(
                  widget.error!,
                  action: Wrap(
                    spacing: 6,
                    children: [
                      AppButton(
                        onPressed: widget.busy ? null : widget.onEnter,
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(l.serversRetry),
                      ),
                      AppButton(
                        onPressed: widget.busy ? null : widget.onLines,
                        variant: AppButtonVariant.tinted,
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(l.serversSwitchLine),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The line entry on a server row: mode icon, "自动选择 · 家庭直连", the last
/// known health of that line and a chevron. Opens the line picker directly.
class _ServerLineChip extends StatefulWidget {
  const _ServerLineChip({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.health,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final ServerTone? health;
  @override
  State<_ServerLineChip> createState() => _ServerLineChipState();
}

class _ServerLineChipState extends State<_ServerLineChip> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return AppSurfaceAction(
      onTap: widget.onTap,
      onHover: (value) => setState(() => hovered = value),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
        decoration: BoxDecoration(
          color: hovered
              ? colors.primary.withValues(alpha: dark ? .16 : .10)
              : colors.onSurface.withValues(alpha: dark ? .06 : .04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: 16,
              color: colors.primary,
              fill: AppIcons.filled,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.health != null) ...[
              const SizedBox(width: 8),
              ServerStatusDot(tone: widget.health!, size: 7),
            ],
            const SizedBox(width: 4),
            Icon(
              AppIcons.chevronDown,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class ServerFormSection extends StatelessWidget {
  const ServerFormSection({
    super.key,
    required this.title,
    required this.children,
    this.icon,
  });
  final String title;
  final List<Widget> children;
  final IconData? icon;
  @override
  Widget build(BuildContext context) =>
      ServerSectionCard(title: title, icon: icon, children: children);
}
