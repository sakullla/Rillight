import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'provider_connect_dialog.dart';
import 'server_flow_frame.dart';
import 'server_management_widgets.dart';
import 'server_paste_draft.dart';

class ServerAddPanel extends StatefulWidget {
  const ServerAddPanel({
    super.key,
    required this.auth,
    required this.onBack,
    required this.onConnected,
    required this.onImport,
  });
  final AuthController auth;
  final VoidCallback onBack, onConnected, onImport;
  @override
  State<ServerAddPanel> createState() => ServerAddPanelState();
}

class ServerAddPanelState extends State<ServerAddPanel> {
  final raw = TextEditingController();
  String step = 'connect';
  ServerPastePreview? preview;
  ServerPasteDraft? selected;
  String? error;
  @override
  void dispose() {
    raw.dispose();
    super.dispose();
  }

  void back() {
    if (step == 'connect' && selected == null) {
      widget.onBack();
    } else {
      setState(() {
        step = 'connect';
        selected = null;
        preview = null;
        error = null;
      });
    }
  }

  Future<void> paste() async {
    setState(() {
      step = 'paste';
      error = null;
    });
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      raw.text = value?.text ?? '';
      if (raw.text.isNotEmpty) parse();
    } catch (_) {
      /* Manual paste is still available. */
    }
  }

  void parse() {
    final result = ServerPastePreview.parse(raw.text);
    setState(() {
      preview = result;
      if (!result.recognized) {
        error = AppLocalizations.of(context).serversPasteUnknown;
      } else if (result.needsGroupSelection) {
        step = 'groups';
        selected = null;
        error = null;
      } else {
        selected = result.groups.single;
        step = 'connect';
        error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget body;
    if (step == 'paste') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversPasteHint),
          const SizedBox(height: 16),
          AppTextField(
            key: const Key('server-paste-text'),
            controller: raw,
            label: l.serversPasteText,
            minLines: 6,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
          ),
          if (error != null) ServerFeedback(error!),
          const SizedBox(height: 20),
          AppButton(
            key: const Key('server-paste-parse'),
            onPressed: parse,
            variant: AppButtonVariant.filled,
            child: Text(l.serversParse),
          ),
        ],
      );
    } else if (step == 'groups') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversPasteGroups),
          const SizedBox(height: 16),
          for (var i = 0; i < preview!.groups.length; i++)
            AppListTile(
              key: Key('server-paste-group-$i'),
              title: Text(
                preview!.groups[i].name.isEmpty
                    ? '${l.serversPasteGroup} ${i + 1}'
                    : preview!.groups[i].name,
              ),
              subtitle: Text(
                '${preview!.groups[i].username}\n${preview!.groups[i].lines.map(serverSafeAddress).join('\n')}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(AppIcons.chevronRight),
              onTap: () => setState(() {
                selected = preview!.groups[i];
                step = 'connect';
              }),
            ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null) ...[
            ServerFeedback(l.serversPasteIncomplete, error: false),
            const SizedBox(height: 8),
          ] else ...[
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              decoration: BoxDecoration(
                color: AppUiTheme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .42),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppUiTheme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppUiTheme.of(context).colorScheme.primary
                          .withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      AppIcons.download,
                      size: 21,
                      color: AppUiTheme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.serversPaste,
                          style: AppUiTheme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l.serversPasteHint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppUiTheme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppUiTheme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    key: const Key('server-add-paste'),
                    onPressed: paste,
                    variant: AppButtonVariant.outlined,
                    child: Text(l.serversPaste),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          ProviderConnectDialog(
            key: ValueKey(selected),
            auth: widget.auth,
            inline: true,
            showTypePicker: true,
            initialDraft: selected,
            onConnected: widget.onConnected,
          ),
          const SizedBox(height: 24),
          const AppDivider(),
          AppButton(
            key: const Key('server-add-import'),
            onPressed: widget.onImport,
            child: Text(l.serversImportFile),
          ),
        ],
      );
    }
    return ServerFlowFrame(
      title: selected != null ? l.serversPastePreview : l.serversAddTitle,
      subtitle: selected != null
          ? l.serversPasteIncomplete
          : l.serversAddSubtitle,
      onBack: back,
      child: body,
    );
  }
}
