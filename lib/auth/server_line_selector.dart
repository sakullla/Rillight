import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'server_flow_frame.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'source_sessions.dart';
import '../media_server/errors.dart';

class ServerLineSelector extends StatefulWidget {
  const ServerLineSelector({
    super.key,
    required this.auth,
    required this.serverId,
    required this.onBack,
    this.onChanged,
  });
  final AuthController auth;
  final String serverId;
  final VoidCallback onBack;
  final Future<void> Function()? onChanged;
  @override
  State<ServerLineSelector> createState() => ServerLineSelectorState();
}

class ServerLineSelectorState extends State<ServerLineSelector> {
  String? busy, error;
  final Map<String, ManualCheckResult> checks = {};
  final Set<String> expanded = {};
  int revision = 0;
  @override
  void dispose() {
    revision++;
    super.dispose();
  }

  void back() {
    revision++;
    widget.onBack();
  }

  Future<void> select(LineSelection value) async {
    if (busy != null) return;
    setState(() {
      busy = value.fixedLineId ?? 'auto';
      error = null;
    });
    final attempt = ++revision;
    void guard() {
      if (!mounted || attempt != revision) {
        throw StateError('Line selection superseded');
      }
    }

    try {
      await widget.auth.chooseConnection(widget.serverId, value, guard: guard);
      guard();
      await widget.onChanged?.call();
    } catch (failure) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        error = serverOperationFailure(
          l,
          failure,
          fallback: l.serversConnectionFailed,
        );
      }
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> check(ServerLine line) async {
    final l = AppLocalizations.of(context);
    setState(() => busy = line.id);
    try {
      checks[line.id] = await widget.auth.sources.check(
        widget.serverId,
        lineId: line.id,
      );
      await widget.auth.refreshServers();
    } catch (failure) {
      error = serverOperationFailure(l, failure);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  String status(AppLocalizations l, ServerLine line) {
    final result = checks[line.id];
    final at = (result?.checkedAt ?? line.checkedAt)?.toLocal();
    if (at == null) return l.serversNotChecked;
    final failureKind =
        result?.failureKind ??
        MediaServerFailureKind.values
            .where((kind) => kind.name == line.checkFailureKind)
            .firstOrNull;
    final label = failureKind != null
        ? serverOperationFailure(
            l,
            MediaServerException(failureKind),
            fallback: l.serversCheckFailed,
          )
        : switch (result?.status.name ?? line.checkStatus) {
            'success' || 'available' || 'online' => l.serversCheckPassed,
            'identityMismatch' => l.serversCheckIdentity,
            'needsLogin' => l.serversCheckLogin,
            'unknown' => l.serversCheckUnknown,
            _ => l.serversCheckFailed,
          };
    return '$label · ${l.serversCheckedAt} ${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final server = widget.auth.sources.server(widget.serverId);
      final actual = widget.auth.sources.connectedLineId(server.id);
      return ServerFlowFrame(
        title: l.serversLines,
        onBack: back,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              server.displayName,
              style: AppUiTheme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            AppListTile(
              key: const Key('server-line-auto'),
              selected: server.lineSelection.isAutomatic,
              leading: Icon(
                server.lineSelection.isAutomatic
                    ? AppIcons.checkCircle
                    : AppIcons.circle,
              ),
              title: Text(l.serversAutomatic),
              subtitle: Text(l.serversAutomaticHint),
              onTap: busy == null
                  ? () => select(const LineSelection.auto())
                  : null,
            ),
            const SizedBox(height: 12),
            const AppDivider(),
            for (final line in server.lines) ...[
              AppListTile(
                key: Key('server-line-choice-${line.id}'),
                selected: server.lineSelection.fixedLineId == line.id,
                leading: Icon(
                  server.lineSelection.fixedLineId == line.id
                      ? AppIcons.checkCircle
                      : AppIcons.circle,
                ),
                title: Text(
                  serverLineLabel(line),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  actual == line.id
                      ? '${l.serversActualLine}${line.checkedAt == null ? '' : '\n${status(l, line)}'}'
                      : line.checkedAt == null
                      ? l.serversNotChecked
                      : status(l, line),
                ),
                trailing: AppIconButton(
                  key: Key('server-line-details-${line.id}'),
                  tooltip: l.serversCheck,
                  icon: Icon(
                    expanded.contains(line.id)
                        ? AppIcons.chevronUp
                        : AppIcons.chevronDown,
                  ),
                  onPressed: () => setState(() {
                    expanded.contains(line.id)
                        ? expanded.remove(line.id)
                        : expanded.add(line.id);
                  }),
                ),
                onTap: busy == null
                    ? () => select(LineSelection.fixed(line.id))
                    : null,
              ),
              if (expanded.contains(line.id))
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(serverSafeAddress(line.address)),
                      const SizedBox(height: 8),
                      AppButton(
                        key: Key('server-line-check-${line.id}'),
                        onPressed: busy == null ? () => check(line) : null,
                        child: Text(
                          busy == line.id ? l.serversBusy : l.serversCheck,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (busy != null) const AppLoadingBar(),
            if (error != null) ServerFeedback(error!),
            const SizedBox(height: 12),
            Text(l.serversFixedHint),
          ],
        ),
      );
    },
  );
}
