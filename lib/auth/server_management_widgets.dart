import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/errors.dart';
import 'connection_failure.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';
import 'server_ui.dart';

String serverLineLabel(ServerLine line) =>
    line.nickname?.trim().isNotEmpty == true ? line.nickname! : line.hostLabel;

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
  final label = active == null ? '—' : serverLineLabel(active);
  return server.lineSelection.isAutomatic
      ? '${l.serversAutomatic} · ${label}'
      : label;
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
  Widget build(BuildContext context) => ServerIdentityBadge(
    type: server.serviceType,
    iconId: server.iconId,
    size: size,
  );
}

/// Three distinct targets: enter, choose a connection, and organize. None of
/// them expands the server card into an editor.
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
    final borderColor = widget.current
        ? colors.primary.withValues(alpha: .62)
        : widget.error != null
        ? colors.error.withValues(alpha: .42)
        : colors.outlineVariant;
    final meta = widget.locked
        ? '${server.serviceType.label} · ${l.serversLocked}'
        : '${server.serviceType.label} · ${server.username}';
    Widget? status;
    if (widget.busy) {
      status = ServerStatusPill(
        label: l.serversBusy,
        tone: ServerTone.current,
        busy: true,
      );
    } else if (widget.current) {
      status = ServerStatusPill(
        label: l.serversCurrent,
        tone: ServerTone.current,
        icon: AppIcons.checkCircle,
      );
    } else if (widget.locked) {
      status = ServerStatusPill(
        label: l.serversLocked,
        tone: ServerTone.neutral,
        icon: AppIcons.lock,
      );
    } else if (widget.needsLogin) {
      status = ServerStatusPill(
        label: l.serversNoAccount,
        tone: ServerTone.warning,
        icon: AppIcons.person,
      );
    } else if (widget.error != null) {
      status = ServerStatusPill(
        label: l.serversConnectionError,
        tone: ServerTone.error,
        icon: AppIcons.error,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: dark ? colors.surfaceContainer : colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(ServerUi.cardRadius),
          border: Border.all(
            color: borderColor,
            width: widget.current ? 1.3 : 1,
          ),
          boxShadow: hovered && !widget.busy
              ? AppShadow.cardHover(colors.brightness)
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
                    borderRadius: BorderRadius.circular(ServerUi.cardRadius),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 15, 4, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ServerIdentityBadge(
                            type: server.serviceType,
                            iconId: server.iconId,
                            locked: widget.locked,
                            size: 52,
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        server.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: -.1,
                                            ),
                                      ),
                                    ),
                                    if (status != null) ...[
                                      const SizedBox(width: 8),
                                      status,
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ServerMetaText(
                                  icon: widget.locked
                                      ? AppIcons.shield
                                      : AppIcons.person,
                                  text: meta,
                                ),
                                const SizedBox(height: 10),
                                AppSurfaceAction(
                                  key: Key('server-lines-${server.id}'),
                                  onTap: widget.busy ? null : widget.onLines,
                                  borderRadius: BorderRadius.circular(999),
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      minHeight: 42,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colors.primary.withValues(
                                        alpha: dark ? .14 : .08,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: colors.primary.withValues(
                                          alpha: .24,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          widget.locked
                                              ? AppIcons.lock
                                              : AppIcons.bolt,
                                          size: 16,
                                          color: colors.primary,
                                        ),
                                        const SizedBox(width: 7),
                                        Flexible(
                                          child: Text(
                                            widget.locked
                                                ? l.serversLines
                                                : serverLineSummary(l, server),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelLarge
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        Icon(
                                          AppIcons.chevronRight,
                                          size: 17,
                                          color: colors.primary,
                                        ),
                                      ],
                                    ),
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
                  padding: const EdgeInsets.only(top: 6, right: 4),
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
                        child: Text(l.serversRemove),
                      ),
                    ],
                    onSelected: widget.busy ? null : widget.onAction,
                    padding: const EdgeInsets.all(4),
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
                        minimumSize: const Size(44, 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(l.serversRetry),
                      ),
                      AppButton(
                        onPressed: widget.busy ? null : widget.onLines,
                        variant: AppButtonVariant.tinted,
                        minimumSize: const Size(44, 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
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
