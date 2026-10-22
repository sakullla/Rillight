import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'provider_connect_dialog.dart';
import 'server_add_panel.dart';
import 'server_management_widgets.dart';
import 'tv_server_flow_frame.dart';

/// The remote presentation shares parsing, drafts and cancellation with touch.
class TvServerAddPanel extends ServerAddPanel {
  const TvServerAddPanel({
    super.key,
    required super.auth,
    required super.onBack,
    required super.onConnected,
    required super.onImport,
  });

  @override
  State<ServerAddPanel> createState() => _TvServerAddPanelState();
}

class _TvServerAddPanelState extends ServerAddPanelState {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TvServerFlowFrame(
      key: ValueKey((step, selected)),
      title: selected != null ? l.serversPastePreview : l.serversAddTitle,
      onBack: back,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (step == 'paste') ...[
            Text(
              l.serversPasteHint,
              style: AppUiTheme.of(context).textTheme.bodyMedium
                  ?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 16),
            TvInput(
              key: const Key('server-paste-text'),
              autofocus: true,
              controller: raw,
              label: l.serversPasteText,
              keyboardType: TextInputType.multiline,
              maxLines: 4,
            ),
            if (error != null) ServerFeedback(error!),
            const SizedBox(height: 20),
            TvAction(
              key: const Key('server-paste-parse'),
              onPressed: parse,
              emphasized: true,
              child: Text(l.serversParse),
            ),
          ] else if (step == 'groups') ...[
            Text(l.serversPasteGroups),
            const SizedBox(height: 16),
            for (var i = 0; i < preview!.groups.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TvAction(
                  key: Key('server-paste-group-$i'),
                  autofocus: i == 0,
                  variant: TvActionVariant.tile,
                  trailing: const Icon(AppIcons.chevronRight),
                  onPressed: () => setState(() => adopt(preview!.groups[i])),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preview!.groups[i].name.isEmpty
                            ? '${l.serversPasteGroup} ${i + 1}'
                            : preview!.groups[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${preview!.groups[i].username}\n${preview!.groups[i].lines.map(serverSafeAddress).join('\n')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
          ] else ...[
            if (selected != null)
              ServerFeedback(l.serversPasteIncomplete, error: false),
            ProviderConnectDialog(
              key: ValueKey(selected),
              auth: widget.auth,
              inline: true,
              showTypePicker: true,
              initialDraft: selected,
              onConnected: widget.onConnected,
            ),
            const SizedBox(height: 24),
            if (selected == null)
              TvAction(
                key: const Key('server-add-paste'),
                pill: true,
                onPressed: paste,
                leading: const Icon(AppIcons.copy),
                child: Text(l.serversPaste),
              ),
            const SizedBox(height: 12),
            TvAction(
              key: const Key('server-add-import'),
              pill: true,
              leading: const Icon(AppIcons.download),
              onPressed: widget.onImport,
              child: Text(l.serversImportFile),
            ),
          ],
        ],
      ),
    );
  }
}
