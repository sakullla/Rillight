import 'server_entry_coordinator.dart';
import '../app/presentation_environment.dart';
import '../app/ui/ui.dart';
import '../app/l10n/app_localizations.dart';
import '../media_server/errors.dart';
import '../player/player_bindings.dart';
import 'auth_controller.dart';
import 'provider_connect_dialog.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'server_password_form.dart';
import 'tv_server_access_page.dart';

/// Open a poster, episode or play target on [serverId].
///
/// The server list is the management button. A content tap switches straight
/// to that server. A locked server asks only for its password, and leaving
/// playback on a protected server asks before the current session is replaced.
Future<bool> enterServerContent(
  BuildContext context,
  AuthController auth,
  String serverId, {
  Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry,
}) async {
  if (auth.session?.server.id == serverId &&
      auth.serverAccess.allows(serverId)) {
    return true;
  }
  final server = _contentServer(auth, serverId);
  if (server == null || !context.mounted) return false;
  await auth.serverAccess.register(server);
  if (!context.mounted) return false;
  if (!await _confirmProtectedPlayback(context, auth, server)) return false;
  if (!context.mounted) return false;
  if (!auth.serverAccess.allows(server.id)) {
    final entered = await showAppDialog<bool>(
      context: context,
      builder: (_) => _ContentUnlockDialog(
        auth: auth,
        server: server,
        tv: PresentationScope.of(context).isTv,
        validateEntry: validateEntry,
      ),
    );
    if (!context.mounted) return false;
    return entered == true &&
        auth.serverAccess.allows(serverId) &&
        auth.session?.server.id == serverId;
  }
  return _enterUnlocked(context, auth, server, validateEntry);
}

SavedServer? _contentServer(AuthController auth, String serverId) {
  for (final server in auth.savedServers) {
    if (server.id == serverId) return server;
  }
  try {
    return auth.sources.server(serverId);
  } on StateError {
    return null;
  }
}

bool _leavesProtectedPlayback(
  BuildContext context,
  AuthController auth,
  String serverId,
) {
  final current = auth.session?.server.id;
  if (current == null || current == serverId) return false;
  if (!auth.serverAccess.isProtected(current)) return false;
  final bindings = PlayerScope.of(context);
  if (bindings.runtime?.hasPlaybackFor(current) == true) return true;
  final host = bindings.windowHost;
  if (host?.playbackOccupied != true) return false;
  final playing = host!.current?.source?.account.configuredServerId;
  return host.current?.source == null || playing == current;
}

Future<bool> _confirmProtectedPlayback(
  BuildContext context,
  AuthController auth,
  SavedServer server,
) async {
  if (!_leavesProtectedPlayback(context, auth, server.id)) return true;
  final l = AppLocalizations.of(context);
  final accepted = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AppDialog(
      title: Text(server.displayName),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.serversEnterOtherTitle),
          const SizedBox(height: 8),
          Text(l.serversEntryPlaybackImpact),
        ],
      ),
      actions: [
        AppButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.serversCancel),
        ),
        AppButton(
          key: const Key('server-entry-continue'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          variant: AppButtonVariant.filled,
          child: Text(l.serversContinue),
        ),
      ],
    ),
  );
  return accepted == true && context.mounted;
}

Future<bool> _enterUnlocked(
  BuildContext context,
  AuthController auth,
  SavedServer server,
  Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry, {
  bool allowLogin = true,
}) async {
  final l = AppLocalizations.of(context);
  var connected = false;
  bool ok;
  try {
    ok = await auth.serverEntry.enter<void>(
      server: server,
      destination: null,
      requestPassword: () async => null,
      connect: (guard) async {
        connected = true;
        return auth.prepareServerEntry(server.id, guard: guard);
      },
      navigate: (_) async {},
      validate: validateEntry == null
          ? null
          : (ticket) => validateEntry(server.id, ticket),
    );
  } on StateError {
    return false;
  } catch (error) {
    if (context.mounted) {
      showAppNotice(context, serverOperationFailure(l, error));
    }
    return false;
  }
  if (!context.mounted) return false;
  if (ok &&
      auth.serverAccess.allows(server.id) &&
      auth.session?.server.id == server.id) {
    return true;
  }
  if (!connected) return false;
  if (allowLogin &&
      auth.failure?.kind == MediaServerFailureKind.sessionExpired) {
    final loggedIn = await showProviderConnect(context, auth, existing: server);
    if (loggedIn == true && context.mounted) {
      return _enterUnlocked(
        context,
        auth,
        server,
        validateEntry,
        allowLogin: false,
      );
    }
    return false;
  }
  showAppNotice(
    context,
    auth.failure == null
        ? l.serversConnectionFailed
        : serverOperationFailure(l, auth.failure!),
  );
  return false;
}

/// A route owns the generation it opened with. Locking replaces its entire
/// child tree, so cached pages/images cannot remain visible or revive later.
class ServerContentGate extends StatefulWidget {
  const ServerContentGate({
    super.key,
    required this.auth,
    required this.serverId,
    required this.builder,
    this.activeContentAllowed,
    this.onAccessRevoked,
    this.validateEntry,
  });
  final Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry;
  final AuthController auth;
  final String serverId;
  final Widget Function(int accessGeneration) builder;
  final bool Function()? activeContentAllowed;
  final VoidCallback? onAccessRevoked;
  @override
  State<ServerContentGate> createState() => _ServerContentGateState();
}

class _ServerContentGateState extends State<ServerContentGate> {
  int? accepted;
  bool busy = false;
  bool revocationScheduled = false;
  @override
  void initState() {
    super.initState();
    widget.auth.serverAccess.addListener(changed);
    if (widget.auth.serverAccess.allows(widget.serverId) &&
        widget.auth.session?.server.id == widget.serverId) {
      accepted = widget.auth.serverAccess.generation(widget.serverId);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) enter();
      });
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> enter() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (await enterServerContent(
            context,
            widget.auth,
            widget.serverId,
            validateEntry: widget.validateEntry,
          ) &&
          mounted) {
        accepted = widget.auth.serverAccess.generation(widget.serverId);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.auth.serverAccess.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (accepted != null &&
        (widget.activeContentAllowed?.call() == true ||
            (widget.auth.serverAccess.allows(widget.serverId) &&
                accepted ==
                    widget.auth.serverAccess.generation(widget.serverId)))) {
      return widget.builder(accepted!);
    }
    if (accepted != null &&
        widget.onAccessRevoked != null &&
        !revocationScheduled) {
      revocationScheduled = true;
      final exit = widget.onAccessRevoked!;
      WidgetsBinding.instance.addPostFrameCallback((_) => exit());
    }
    if (busy) return const Center(child: CupertinoActivityIndicator());
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.auth.savedServers
                      .where((s) => s.id == widget.serverId)
                      .firstOrNull
                      ?.displayName ??
                  l.serversTitle,
            ),
            const SizedBox(height: 16),
            AppButton(onPressed: enter, child: Text(l.serversEnter)),
          ],
        ),
      ),
    );
  }
}

/// Password for one server. Cancel closes it; success does not return to the
/// server list.
class _ContentUnlockDialog extends StatefulWidget {
  const _ContentUnlockDialog({
    required this.auth,
    required this.server,
    required this.tv,
    this.validateEntry,
  });

  final AuthController auth;
  final SavedServer server;
  final bool tv;
  final Future<bool> Function(String serverId, ServerEntryTicket ticket)?
  validateEntry;

  @override
  State<_ContentUnlockDialog> createState() => _ContentUnlockDialogState();
}

class _ContentUnlockDialogState extends State<_ContentUnlockDialog> {
  String? error;
  bool busy = false;
  bool finished = false;
  int revision = 0;

  @override
  void dispose() {
    if (!finished) widget.auth.serverEntry.cancel();
    super.dispose();
  }

  Future<void> submit(String password) async {
    final attempt = ++revision;
    setState(() {
      busy = true;
      error = null;
    });
    await _enter(password, attempt, allowLogin: true);
  }

  Future<void> _enter(
    String password,
    int attempt, {
    required bool allowLogin,
  }) async {
    var rejected = false;
    var connected = false;
    bool ok;
    try {
      ok = await widget.auth.serverEntry.enter<void>(
        server: widget.server,
        destination: null,
        requestPassword: () async => password,
        connect: (guard) async {
          connected = true;
          return widget.auth.prepareServerEntry(widget.server.id, guard: guard);
        },
        navigate: (_) async {},
        onPasswordRejected: () => rejected = true,
        validate: widget.validateEntry == null
            ? null
            : (ticket) => widget.validateEntry!(widget.server.id, ticket),
      );
    } on StateError {
      if (mounted && attempt == revision) setState(() => busy = false);
      return;
    } catch (failure) {
      if (!mounted || attempt != revision) return;
      setState(() {
        busy = false;
        error = serverOperationFailure(AppLocalizations.of(context), failure);
      });
      return;
    }
    if (!mounted || attempt != revision) return;
    if (ok &&
        widget.auth.serverAccess.allows(widget.server.id) &&
        widget.auth.session?.server.id == widget.server.id) {
      finished = true;
      Navigator.of(context).pop(true);
      return;
    }
    final l = AppLocalizations.of(context);
    if (rejected) {
      setState(() {
        busy = false;
        error = l.serversPasswordWrong;
      });
      return;
    }
    if (allowLogin &&
        connected &&
        widget.auth.failure?.kind == MediaServerFailureKind.sessionExpired) {
      final loggedIn = await showProviderConnect(
        context,
        widget.auth,
        existing: widget.server,
      );
      if (!mounted || attempt != revision) return;
      if (loggedIn == true) {
        await _enter(password, attempt, allowLogin: false);
        return;
      }
    }
    setState(() {
      busy = false;
      error = !connected
          ? null
          : widget.auth.failure == null
          ? l.serversConnectionFailed
          : serverOperationFailure(l, widget.auth.failure!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final access = widget.auth.serverAccess;
    final form = widget.tv
        ? TvServerUnlockForm(
            onSubmit: submit,
            error: error,
            busy: busy,
            unavailable: access.isUnavailable(widget.server.id),
            retryAt: access.retryAt(widget.server.id),
          )
        : ServerUnlockForm(
            onSubmit: submit,
            error: error,
            busy: busy,
            unavailable: access.isUnavailable(widget.server.id),
            retryAt: access.retryAt(widget.server.id),
          );
    return AppDialog(
      maxWidth: 420,
      title: Text(widget.server.displayName),
      content: form,
      actions: [
        AppButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.serversCancel),
        ),
      ],
    );
  }
}
