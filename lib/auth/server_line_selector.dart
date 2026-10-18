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
      final theme = AppUiTheme.of(context);
      final server = widget.auth.sources.server(widget.serverId);
      final actual = widget.auth.sources.connectedLineId(server.id);
      final actualLine = server.lines
          .where((line) => line.id == actual)
          .firstOrNull;
      return ServerFlowFrame(
        title: l.serversLines,
        subtitle: l.serversLineSubtitle,
        onBack: back,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ServerIdentityCard(
              server: server,
              subtitle:
                  '${server.username} · ${l.serversLineCount(server.lines.length)}',
            ),
            const SizedBox(height: 20),
            _LineAutoCard(
              selected: server.lineSelection.isAutomatic,
              actualLine: server.lineSelection.isAutomatic ? actualLine : null,
              onTap: busy == null
                  ? () => select(const LineSelection.auto())
                  : null,
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Text(
                  l.serversLines,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l.serversLineCount(server.lines.length),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final line in server.lines)
              ServerLineChoice(
                key: Key('server-line-choice-${line.id}'),
                line: line,
                selected: server.lineSelection.fixedLineId == line.id,
                actual: actual == line.id,
                busy: busy == line.id,
                expanded: expanded.contains(line.id),
                status: status(l, line),
                onSelect: busy == null
                    ? () => select(LineSelection.fixed(line.id))
                    : null,
                onDetails: () => setState(() {
                  expanded.contains(line.id)
                      ? expanded.remove(line.id)
                      : expanded.add(line.id);
                }),
                onCheck: busy == null ? () => check(line) : null,
                checking: busy == line.id,
              ),
            if (busy != null) const AppLoadingBar(),
            if (error != null) ServerFeedback(error!),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: .45,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    AppIcons.info,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      l.serversFixedHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _LineAutoCard extends StatelessWidget {
  const _LineAutoCard({
    required this.selected,
    required this.actualLine,
    required this.onTap,
  });

  final bool selected;
  final ServerLine? actualLine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return AppSurfaceAction(
      key: const Key('server-line-auto'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected
              ? Color.alphaBlend(
                  colors.primary.withValues(alpha: dark ? .13 : .07),
                  dark
                      ? colors.surfaceContainer
                      : colors.surfaceContainerLowest,
                )
              : dark
              ? colors.surfaceContainer
              : colors.surfaceContainerLowest,
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: .55)
                : colors.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.primary.withValues(alpha: .24),
                    colors.primary.withValues(alpha: .08),
                  ],
                ),
              ),
              child: Icon(AppIcons.bolt, size: 23, color: colors.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          l.serversAutomatic,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ServerStatusPill(
                        label: l.serversRecommend,
                        tone: ServerTone.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.serversAutomaticHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  if (actualLine != null) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(AppIcons.bolt, size: 14, color: colors.primary),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${l.serversActualLine} · ${serverLineLabel(actualLine!)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              selected ? AppIcons.checkCircle : AppIcons.circle,
              size: 23,
              color: selected ? colors.primary : colors.outline,
            ),
          ],
        ),
      ),
    );
  }
}

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
    final dark = colors.brightness == Brightness.dark;
    final failed = line.checkFailureKind != null;
    final passed =
        line.checkStatus == 'success' ||
        line.checkStatus == 'available' ||
        line.checkStatus == 'online';
    final statusColor = failed
        ? colors.error
        : passed
        ? colors.tertiary
        : colors.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(
                colors.primary.withValues(alpha: dark ? .11 : .06),
                dark ? colors.surfaceContainer : colors.surfaceContainerLowest,
              )
            : dark
            ? colors.surfaceContainer
            : colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? colors.primary.withValues(alpha: .52)
              : colors.outlineVariant,
          width: selected ? 1.3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSurfaceAction(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 6, 13),
              child: Row(
                children: [
                  Icon(
                    selected ? AppIcons.checkCircle : AppIcons.circle,
                    size: 22,
                    color: selected ? colors.primary : colors.outline,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                serverLineLabel(line),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (actual) ...[
                              const SizedBox(width: 8),
                              ServerStatusPill(
                                label: l.serversActualLine,
                                tone: ServerTone.success,
                                busy: busy,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          serverSafeAddress(line.address),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                checking ? l.serversBusy : status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  AppIconButton(
                    key: Key('server-line-details-${line.id}'),
                    tooltip: l.serversLineDetails,
                    onPressed: onDetails,
                    minimumSize: const Size(44, 44),
                    icon: Icon(
                      expanded ? AppIcons.chevronUp : AppIcons.chevronDown,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 13),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .42),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.serversLineAddress,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        AppSelectableText(
                          serverSafeAddress(line.address),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AppButton(
                    key: Key('server-line-check-${line.id}'),
                    onPressed: onCheck,
                    variant: AppButtonVariant.tinted,
                    minimumSize: const Size(40, 36),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    child: Text(checking ? l.serversBusy : l.serversCheck),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
