import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import '../media_server/errors.dart';
import 'connection_failure.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';

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

String serverOperationFailure(AppLocalizations l, Object error) =>
    switch (connectionFailure(error).kind) {
      MediaServerFailureKind.invalidAddress => l.errorInvalidAddress,
      MediaServerFailureKind.invalidCredentials =>
        l.providerCredentialsRejected,
      MediaServerFailureKind.sessionExpired ||
      MediaServerFailureKind.authorizationExpired => l.serversCheckLogin,
      MediaServerFailureKind.incompatibleServer => l.serversCheckIdentity,
      MediaServerFailureKind.certificate => l.providerCertificateFailure,
      MediaServerFailureKind.forbidden => l.providerPermissionDenied,
      MediaServerFailureKind.rateLimited => l.providerRateLimited,
      MediaServerFailureKind.timeout => l.errorTimeout,
      MediaServerFailureKind.unreachable => l.errorUnreachable,
      _ => l.serversSaveFailed,
    };

class ServerFeedback extends StatelessWidget {
  const ServerFeedback(this.message, {super.key, this.error = true});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (error ? theme.colorScheme.error : theme.colorScheme.primary)
              .withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(error ? AppIcons.error : AppIcons.info, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class ServerIdentityIcon extends StatelessWidget {
  const ServerIdentityIcon(this.server, {super.key});
  final SavedServer server;
  @override
  Widget build(BuildContext context) {
    final icon = switch (server.iconId) {
      'home' => AppIcons.home,
      'cinema' => AppIcons.movie,
      'cloud' => AppIcons.globe,
      _ => null,
    };
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppUiTheme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: icon == null
            ? ServerTypeMark(type: server.serviceType, size: 28)
            : Icon(icon, size: 26, fill: AppIcons.filled),
      ),
    );
  }
}

/// Three distinct targets: enter, choose a connection, and organize. None of
/// them expands the server card into an editor.
class ServerSelectionTile extends StatelessWidget {
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
    this.canMoveUp = false,
    this.canMoveDown = false,
  });
  final SavedServer server;
  final bool current, locked, busy, canMoveUp, canMoveDown;
  final VoidCallback onEnter, onLines;
  final ValueChanged<String> onAction;
  final String? error;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = AppUiTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: current
              ? theme.colorScheme.primary.withValues(alpha: .6)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppSurfaceAction(
                  key: Key('server-enter-${server.id}'),
                  focusNode: focusNode,
                  onTap: busy ? null : onEnter,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 0, 12),
                    child: Row(
                      children: [
                        ServerIdentityIcon(server),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                server.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                locked
                                    ? l.serversLocked
                                    : '${server.username} · ${server.activeLine?.hostLabel ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
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
                padding: const EdgeInsets.only(top: 8, right: 4),
                child: AppMenuButton<String>(
                  key: Key('server-more-${server.id}'),
                  tooltip: l.serversMore,
                  items: [
                    AppMenuEntry(
                      key: Key('server-action-edit-${server.id}'),
                      value: 'edit',
                      child: Text(l.serversEdit),
                    ),
                    if (canMoveUp)
                      AppMenuEntry(value: 'up', child: Text(l.serversUp)),
                    if (canMoveDown)
                      AppMenuEntry(value: 'down', child: Text(l.serversDown)),
                    AppMenuEntry(
                      key: Key('server-action-remove-${server.id}'),
                      value: 'remove',
                      child: Text(l.serversRemove),
                    ),
                  ],
                  onSelected: busy ? null : onAction,
                  child: const Text(
                    '•••',
                    style: TextStyle(fontSize: 18, letterSpacing: 1),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppButton.icon(
                  key: Key('server-lines-${server.id}'),
                  onPressed: busy ? null : onLines,
                  minimumSize: const Size(48, 48),
                  icon: Icon(locked ? AppIcons.lock : AppIcons.link, size: 18),
                  label: Text(
                    locked
                        ? l.serversLines
                        : '${server.lineSelection.isAutomatic ? l.serversAutomatic : l.serversLines} · ${server.activeLine == null ? '—' : serverLineLabel(server.activeLine!)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  variant: AppButtonVariant.tinted,
                ),
                if (current)
                  Text(l.serversCurrent, style: theme.textTheme.labelSmall),
                if (busy)
                  Text(l.serversBusy, style: theme.textTheme.labelSmall),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ServerFeedback(error!),
            ),
        ],
      ),
    );
  }
}

class ServerFormSection extends StatelessWidget {
  const ServerFormSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: AppUiTheme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );
}
