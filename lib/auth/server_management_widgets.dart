import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/errors.dart';
import 'connection_failure.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';
import 'server_ui.dart';

/// 无昵称线路的标签:完整主机名,非默认端口时带端口
/// (capture-mirror.test:8096)。不截断、不在中间插省略号;放不下时由
/// [ServerLineLabelText] 先去掉端口([withPort] 为 false),再折成两行。
String serverLineHostLabel(ServerLine line, {bool withPort = true}) {
  final uri = Uri.tryParse(line.address);
  if (uri == null || uri.host.isEmpty) return line.hostLabel.trim();
  // IPv6 字面量带回方括号,端口才不会与地址混在一起。
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final port = uri.hasPort ? uri.port : null;
  // 默认端口不重复显示。
  if (!withPort || port == null || port == 80 || port == 443) return host;
  return '$host:$port';
}

String serverLineLabel(ServerLine line, {bool withPort = true}) =>
    line.nickname?.trim().isNotEmpty == true
    ? line.nickname!
    : serverLineHostLabel(line, withPort: withPort);
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

String serverLineSummary(
  AppLocalizations l,
  SavedServer server, {
  bool withPort = true,
}) {
  final active = server.activeLine;
  if (active == null) return '—';
  if (!server.lineSelection.isAutomatic) {
    return serverLineLabel(active, withPort: withPort);
  }
  // 昵称是用户自己起的短名字,照常显示,只在前面标出当前模式。
  final nickname = active.nickname?.trim();
  if (nickname != null && nickname.isNotEmpty) {
    return '${l.serversAutomatic} · $nickname';
  }
  // 没有昵称时只显示主机名:"自动选择 · "这六个字在 360dp 上要占掉
  // 半个芯片,挤掉真正有用的主机名。自动模式由芯片上的闪电图标表达,
  // 文字里不必重复。
  return serverLineHostLabel(active, withPort: withPort);
}

/// 服务器编辑器线路行的状态标记:当前使用的线路([current] 为 false 时
/// 由调用方用标签单独标出)、自动选择模式下由自动选中的线路,以及有测速
/// 数据时的延迟。与线路选择页同一套措辞。
List<String> serverLineEditorMarks(
  AppLocalizations l,
  SavedServer server,
  ServerLine line, {
  bool current = true,
}) {
  final active = server.activeLine?.id == line.id;
  final latency = line.latencyMs;
  return [
    if (current && active) l.serversLineActual,
    if (active && server.lineSelection.isAutomatic) l.serversAutomatic,
    if (latency != null) l.serversLatency(latency),
  ];
}

/// 线路标签的自适应排布,三端的线路入口共用:
///
/// 1. [full](主机:端口)单行放得下就单行显示;
/// 2. 放不下时改用 [compact](去掉端口的主机名),单行显示;
/// 3. 仍放不下才折行,最多 [maxLines] 行。
///
/// 任何一档都不在中间插入省略号;完整地址由调用方的 tooltip 或语义
/// label 提供。
class ServerLineLabelText extends StatelessWidget {
  const ServerLineLabelText({
    super.key,
    required this.full,
    String? compact,
    this.style,
    this.maxLines = 2,
  }) : compact = compact ?? full;

  final String full, compact;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final resolved = DefaultTextStyle.of(context).style.merge(style);
      final direction = Directionality.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      bool fits(String text) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: resolved),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout(maxWidth: box.maxWidth);
        final result = !painter.didExceedMaxLines;
        painter.dispose();
        return result;
      }

      if (!box.maxWidth.isFinite || fits(full)) {
        return Text(full, maxLines: 1, softWrap: false, style: style);
      }
      if (compact != full && fits(compact)) {
        return Text(compact, maxLines: 1, softWrap: false, style: style);
      }
      return Text(
        compact,
        maxLines: maxLines,
        softWrap: true,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    },
  );
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
                ? colors.primary.withValues(alpha: dark ? .48 : .36)
                : widget.error != null
                ? colors.error.withValues(alpha: .38)
                : ServerUi.groupStroke(colors),
            width: widget.current ? 1.2 : .8,
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
                                    compactLabel: widget.locked
                                        ? null
                                        : serverLineSummary(
                                            l,
                                            server,
                                            withPort: false,
                                          ),
                                    address:
                                        widget.locked ||
                                            server.activeLine == null
                                        ? null
                                        : serverSafeAddress(
                                            server.activeLine!.address,
                                          ),
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
                  // 重试是这里的次级操作,切换线路为第三级纯文字。
                  action: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      AppActionButton(
                        key: Key('server-switch-line-${server.id}'),
                        tier: AppActionTier.tertiary,
                        onPressed: widget.busy ? null : widget.onLines,
                        label: l.serversSwitchLine,
                      ),
                      AppActionButton(
                        key: Key('server-retry-${server.id}'),
                        icon: AppIcons.refresh,
                        onPressed: widget.busy ? null : widget.onEnter,
                        label: l.serversRetry,
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
///
/// The label never shortens in the middle: host and port on one line, then
/// the host alone, then two lines. The full safe address is both the hover
/// tooltip and the semantic tooltip.
class _ServerLineChip extends StatefulWidget {
  const _ServerLineChip({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.compactLabel,
    this.address,
    this.health,
  });
  final String label;
  final String? compactLabel, address;
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
    final address = widget.address;
    final chip = AppSurfaceAction(
      onTap: widget.onTap,
      onHover: (value) => setState(() => hovered = value),
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
        decoration: BoxDecoration(
          color: hovered
              ? colors.primary.withValues(alpha: dark ? .16 : .10)
              : colors.onSurface.withValues(alpha: dark ? .06 : .04),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: hovered
                ? colors.primary.withValues(alpha: .36)
                : AppEdge.of(colors.brightness, strong: !dark),
          ),
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
              child: ServerLineLabelText(
                full: widget.label,
                compact: widget.compactLabel,
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
    if (address == null || address.isEmpty) return chip;
    return AppTooltip(
      message: address,
      child: Semantics(tooltip: address, child: chip),
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
