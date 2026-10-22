import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'server_line_selector.dart';
import 'server_line_fields.dart';
import 'server_list_store.dart';
import 'server_management_widgets.dart';
import 'tv_server_flow_frame.dart';

class TvLineSelectionPage extends ServerLineSelector {
  const TvLineSelectionPage({
    super.key,
    required super.auth,
    required super.serverId,
    required super.onBack,
    super.onChanged,
  });
  @override
  State<ServerLineSelector> createState() => _TvLineSelectionState();
}

class _TvLineSelectionState extends ServerLineSelectorState {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final server = widget.auth.sources.server(widget.serverId);
      final actual = widget.auth.sources.connectedLineId(server.id);
      final actualLine = server.lines
          .where((line) => line.id == actual)
          .firstOrNull;
      return TvServerFlowFrame(
        title: l.serversLines,
        onBack: back,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ServerIdentityIcon(
                  server,
                  size: 48 * TvDesign.scaleOf(context),
                ),
                SizedBox(width: 16 * TvDesign.scaleOf(context)),
                Expanded(
                  child: Text(
                    '${server.displayName} · ${l.serversLineCount(server.lines.length)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TvAction(
                    key: const Key('server-lines-discover'),
                    pill: true,
                    onPressed: idle ? discover : null,
                    leading: const Icon(AppIcons.refresh),
                    child: Text(
                      discovering
                          ? l.serversDiscoveringLines
                          : l.serversDiscoverLines,
                    ),
                  ),
                ),
                SizedBox(width: 12 * TvDesign.scaleOf(context)),
                Expanded(
                  child: TvAction(
                    key: const Key('server-lines-speed'),
                    pill: true,
                    onPressed: idle ? checkAll : null,
                    leading: const Icon(AppIcons.bolt),
                    child: Text(
                      testing ? l.serversSpeedTesting : l.serversSpeedTest,
                    ),
                  ),
                ),
              ],
            ),
            if (notice != null) ServerFeedback(notice!, error: false),
            const SizedBox(height: 20),
            TvChoiceTile(
              actionKey: const Key('server-line-auto'),
              autofocus: true,
              label: l.serversAutomatic,
              subtitle: server.lineSelection.isAutomatic && actualLine != null
                  ? '${l.serversActualLine} · ${serverLineLabel(actualLine)}'
                  : l.serversAutomaticHint,
              selected: server.lineSelection.isAutomatic,
              onPressed: idle ? () => select(const LineSelection.auto()) : null,
            ),
            const SizedBox(height: 12),
            for (final line in server.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TvChoiceTile(
                        actionKey: Key('server-line-choice-${line.id}'),
                        label: serverLineLabel(line),
                        subtitle:
                            '${actual == line.id ? '${l.serversActualLine} · ' : ''}${serverSafeAddress(line.address)} · ${status(l, line)}',
                        selected: server.lineSelection.fixedLineId == line.id,
                        onPressed: idle
                            ? () => select(LineSelection.fixed(line.id))
                            : null,
                      ),
                    ),
                    const SizedBox(width: 20),
                    TvAction(
                      key: Key('server-line-check-${line.id}'),
                      onPressed: idle ? () => check(line) : null,
                      leading: const Icon(AppIcons.refresh),
                      child: Text(
                        busy == line.id ? l.serversCheckingNow : l.serversCheck,
                      ),
                    ),
                  ],
                ),
              ),
            if (error != null) ServerFeedback(error!),
            Text(l.serversFixedHint),
          ],
        ),
      );
    },
  );
}

class TvServerLineFields extends ServerLineFields {
  const TvServerLineFields({
    super.key,
    super.line,
    required super.onDone,
    required super.onCancel,
    required super.otherLines,
  });
  @override
  State<ServerLineFields> createState() => _TvLineFieldsState();
}

class _TvLineFieldsState extends ServerLineFieldsState {
  @override
  void initState() {
    super.initState();
    address.addListener(addressChanged);
  }

  @override
  void dispose() {
    address.removeListener(addressChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    // The frame titles the step; the address problem sits right under the
    // address, and the two actions keep their own width on the trailing edge.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvInput(
          key: const Key('server-line-name'),
          label: l.serversLineName,
          controller: name,
          autofocus: true,
        ),
        const SizedBox(height: 16),
        TvInput(
          key: const Key('server-line-address'),
          label: l.serversLineAddress,
          controller: address,
          keyboardType: TextInputType.url,
        ),
        if (error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(16 * s, 8 * s, 16 * s, 0),
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Icon(
                    AppIcons.error,
                    size: 18 * s,
                    color: theme.colorScheme.error,
                    fill: AppIcons.filled,
                  ),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      error!,
                      key: const Key('server-line-address-error'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Icon(
              AppIcons.info,
              size: 18 * s,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: 8 * s),
            Expanded(
              child: Text(
                l.serversLineDraftHint,
                key: const Key('server-line-draft-hint'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            SizedBox(width: 20 * s),
            TvAction(
              key: ServerLineFieldsState.cancelKey,
              onPressed: widget.onCancel,
              child: Text(l.serversCancel),
            ),
            SizedBox(width: 16 * s),
            TvAction(
              key: ServerLineFieldsState.doneKey,
              onPressed: done,
              emphasized: true,
              pill: true,
              leading: const Icon(AppIcons.check),
              child: Text(l.serversDone),
            ),
          ],
        ),
      ],
    );
  }
}
