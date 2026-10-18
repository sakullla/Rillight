import 'server_entry_coordinator.dart';
import '../app/presentation_environment.dart';
import '../app/ui/ui.dart';
import '../app/l10n/app_localizations.dart';
import 'auth_controller.dart';
import 'server_selection_page.dart';
import 'tv_server_selection_page.dart';

/// Preserve the caller's destination while the same selection/entry controller
/// verifies the password and connection. No separate private route or account.
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
  var entered = false;
  Future<void> done() async {
    entered = true;
  }

  if (PresentationScope.of(context).isTv) {
    await showTvServerSelection(
      context,
      auth: auth,
      initialServerId: serverId,
      onEntered: done,
      validateEntry: validateEntry,
    );
  } else {
    await showServerSelection(
      context,
      auth: auth,
      phone: !PresentationScope.of(context).isDesktop,
      initialServerId: serverId,
      onEntered: done,
      validateEntry: validateEntry,
    );
  }
  return entered &&
      auth.serverAccess.allows(serverId) &&
      auth.session?.server.id == serverId;
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
            AppButton(
              onPressed: busy ? null : enter,
              child: Text(l.serversEnter),
            ),
          ],
        ),
      ),
    );
  }
}
