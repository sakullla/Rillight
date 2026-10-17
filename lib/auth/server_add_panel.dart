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
            AppButton.icon(
              key: const Key('server-add-paste'),
              onPressed: paste,
              icon: const Icon(AppIcons.download),
              label: Text(l.serversPaste),
              variant: AppButtonVariant.tinted,
            ),
            const SizedBox(height: 20),
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
      onBack: back,
      child: body,
    );
  }
}
