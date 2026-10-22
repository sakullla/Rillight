import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'server_flow_frame.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'server_ui.dart';
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
  String? busy, error, notice;
  bool discovering = false, testing = false;
  final Map<String, ManualCheckResult> checks = {};
  final Set<String> checking = {};
  int revision = 0;

  bool get idle => busy == null && !discovering && !testing;
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

  Future<void> discover() async {
    if (!idle) return;
    final l = AppLocalizations.of(context);
    setState(() {
      discovering = true;
      error = null;
      notice = null;
    });
    try {
      final added = await widget.auth.discoverExtendedLines(
        widget.serverId,
        force: true,
      );
      if (!mounted) return;
      setState(() {
        notice = added < 0
            ? l.serversDiscoverNeedCurrent
            : added == 0
            ? l.serversDiscoverNone
            : l.serversDiscoverAdded(added);
      });
    } catch (failure) {
      if (mounted) setState(() => error = serverOperationFailure(l, failure));
    } finally {
      if (mounted) setState(() => discovering = false);
    }
  }

  Future<void> checkAll() async {
    if (!idle) return;
    final lines = List<ServerLine>.of(
      widget.auth.sources.server(widget.serverId).lines,
    );
    setState(() {
      testing = true;
      error = null;
      notice = null;
    });
    try {
      for (final line in lines) {
        if (!mounted) return;
        await check(line);
      }
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> check(ServerLine line) async {
    final l = AppLocalizations.of(context);
    setState(() {
      busy = line.id;
      checking.add(line.id);
      error = null;
    });
    try {
      checks[line.id] = await widget.auth.sources.check(
        widget.serverId,
        lineId: line.id,
      );
      await widget.auth.refreshServers();
    } catch (failure) {
      error = serverOperationFailure(l, failure);
    } finally {
      checking.remove(line.id);
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
    final when =
        '$label · ${l.serversCheckedAt} ${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final latency = result?.latencyMs ?? line.latencyMs;
    if (latency == null) return when;
    return '${l.serversLatency(latency)} · $when';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final theme = AppUiTheme.of(context);
      final colors = theme.colorScheme;
      final server = widget.auth.sources.server(widget.serverId);
      final actual = widget.auth.sources.connectedLineId(server.id);
      final actualLine = server.lines
          .where((line) => line.id == actual)
          .firstOrNull;
      final automatic = server.lineSelection.isAutomatic;
      return ServerFlowFrame(
        title: l.serversLines,
        subtitle: server.displayName,
        onBack: back,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ServerIdentityCard(
              server: server,
              subtitle:
                  '${server.username} · ${l.serversLineCount(server.lines.length)}',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    key: const Key('server-lines-discover'),
                    onPressed: idle ? discover : null,
                    child: Text(
                      discovering
                          ? l.serversDiscoveringLines
                          : l.serversDiscoverLines,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppButton(
                    key: const Key('server-lines-speed'),
                    onPressed: idle ? checkAll : null,
                    child: Text(
                      testing ? l.serversSpeedTesting : l.serversSpeedTest,
                    ),
                  ),
                ),
              ],
            ),
            if (notice != null) ServerFeedback(notice!, error: false),
            const SizedBox(height: 22),
            ServerGroup(
              title: l.serversLineAutoSection,
              children: [
                ServerRow(
                  key: const Key('server-line-auto'),
                  selected: automatic,
                  onTap: idle ? () => select(const LineSelection.auto()) : null,
                  leading: ServerRowIcon(
                    AppIcons.bolt,
                    tone: automatic ? ServerTone.current : ServerTone.neutral,
                    size: 36,
                  ),
                  title: Row(
                    children: [
                      Flexible(child: Text(l.serversAutomatic)),
                      const SizedBox(width: 8),
                      ServerStatusPill(
                        label: l.serversRecommend,
                        tone: ServerTone.success,
                      ),
                    ],
                  ),
                  subtitle: Text(
                    automatic && actualLine != null
                        ? '${l.serversActualLine} · ${serverLineLabel(actualLine)}'
                        : l.serversAutomaticHint,
                    style: automatic && actualLine != null
                        ? TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : null,
                  ),
                  trailing: busy == 'auto'
                      ? const CupertinoActivityIndicator(radius: 9)
                      : _SelectionMark(selected: automatic),
                ),
              ],
            ),
            ServerGroup(
              title: l.serversLineFixedSection,
              trailing: Text(
                l.serversLineCount(server.lines.length),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              description: l.serversFixedHint,
              dividerIndent: 60,
              children: [
                for (final line in server.lines)
                  ServerLineChoice(
                    key: Key('server-line-choice-${line.id}'),
                    line: line,
                    selected: server.lineSelection.fixedLineId == line.id,
                    actual: actual == line.id,
                    busy: busy == line.id,
                    expanded: false,
                    status: status(l, line),
                    onSelect: idle
                        ? () => select(LineSelection.fixed(line.id))
                        : null,
                    onDetails: () {},
                    onCheck: idle ? () => check(line) : null,
                    checking: busy == line.id && checking.contains(line.id),
                  ),
              ],
            ),
            if (error != null) ServerFeedback(error!),
          ],
        ),
      );
    },
  );
}

/// Radio mark that reads without colour: filled check vs empty ring.
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: AppMotion.fast,
      child: selected
          ? Icon(
              AppIcons.checkCircle,
              key: const ValueKey(true),
              size: 24,
              color: colors.primary,
              fill: AppIcons.filled,
            )
          : Icon(
              AppIcons.circle,
              key: const ValueKey(false),
              size: 24,
              color: colors.outline,
            ),
    );
  }
}

/// One connection line: selection mark, name, address and last check result,
/// with a direct "check" action. Selecting and checking are separate targets.
class ServerLineChoice extends StatelessWidget {
  const ServerLineChoice({
    super.key,
    required this.line,
    required this.selected,
    required this.actual,
    required this.busy,
    required this.expanded,
    required this.status,
    required this.onSelect,
    required this.onDetails,
    required this.onCheck,
    required this.checking,
  });

  final ServerLine line;
  final bool selected, actual, busy, expanded, checking;
  final String status;
  final VoidCallback? onSelect;
  final VoidCallback onDetails;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final health = serverLineHealth(line);
    final statusTone = checking ? ServerTone.current : health;
    final statusColor = statusTone == null
        ? colors.onSurfaceVariant
        : serverToneColor(colors, statusTone);
    return ServerRow(
      selected: selected,
      onTap: onSelect,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      leading: SizedBox(
        width: 30,
        child: busy && !checking
            ? const CupertinoActivityIndicator(radius: 9)
            : _SelectionMark(selected: selected),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              serverLineLabel(line),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (actual) ...[
            const SizedBox(width: 8),
            ServerStatusPill(
              label: l.serversActualLine,
              tone: ServerTone.success,
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            serverSafeAddress(line.address),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (statusTone == null)
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.outline, width: 1.2),
                  ),
                )
              else
                ServerStatusDot(tone: statusTone, size: 7),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  checking ? l.serversCheckingNow : status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    fontWeight: statusTone == null ? null : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: AppIconButton(
        key: Key('server-line-check-${line.id}'),
        tooltip: l.serversCheck,
        onPressed: onCheck,
        minimumSize: const Size(44, 44),
        icon: checking
            ? const CupertinoActivityIndicator(radius: 9)
            : Icon(AppIcons.refresh, size: 20, color: colors.onSurfaceVariant),
      ),
    );
  }
}
