import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'auth_controller.dart';
import 'provider_connect_dialog.dart';
import 'server_flow_frame.dart';
import 'server_management_widgets.dart';
import 'server_paste_draft.dart';
import 'server_ui.dart';

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
      if (raw.text.trim().isEmpty) {
        setState(() => error = AppLocalizations.of(context).serversPasteEmpty);
      } else {
        parse();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = AppLocalizations.of(context).serversPasteReadFailed,
        );
      }
    }
  }

  /// Keeps the recognized server, including a password found in the text.
  void adopt(ServerPasteDraft draft) {
    selected = draft;
    step = 'connect';
    error = null;
  }

  void parse() {
    if (raw.text.trim().isEmpty) {
      setState(() => error = AppLocalizations.of(context).serversPasteEmpty);
      return;
    }
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
        adopt(result.groups.single);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget body;
    if (step == 'paste') {
      final theme = AppUiTheme.of(context);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.serversPasteHint,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
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
          // The step's one primary action: full row on phone, trailing and
          // content-wide in the desktop panel.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: ServerPanelScope.maybeOf(context)?.compact == true
                    ? double.infinity
                    : 0,
              ),
              child: AppActionButton(
                key: const Key('server-paste-parse'),
                tier: AppActionTier.primary,
                onPressed: parse,
                icon: AppIcons.check,
                label: l.serversParse,
              ),
            ),
          ),
        ],
      );
    } else if (step == 'groups') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.serversPasteGroups),
          const SizedBox(height: 16),
          ServerGroup(
            dividerIndent: 60,
            children: [
              for (var i = 0; i < preview!.groups.length; i++)
                ServerRow(
                  key: Key('server-paste-group-$i'),
                  leading: ServerRowIcon(
                    AppIcons.person,
                    tone: ServerTone.neutral,
                    size: 34,
                  ),
                  title: Text(
                    preview!.groups[i].name.isEmpty
                        ? '${l.serversPasteGroup} ${i + 1}'
                        : preview!.groups[i].name,
                  ),
                  subtitle: Text(
                    [
                      preview!.groups[i].username,
                      ...preview!.groups[i].lines.map(serverSafeAddress),
                    ].join('\n'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  chevron: true,
                  onTap: () => setState(() => adopt(preview!.groups[i])),
                ),
            ],
          ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null) ...[
            ServerFeedback(l.serversPasteSuccess, error: false),
            const SizedBox(height: 8),
          ] else
            ServerGroupHeader(title: l.serversSelectType),
          ProviderConnectDialog(
            key: ValueKey(selected),
            auth: widget.auth,
            inline: true,
            showTypePicker: true,
            initialDraft: selected,
            onConnected: widget.onConnected,
          ),
          const SizedBox(height: 26),
          ServerGroup(
            title: l.serversMoreOptions,
            margin: EdgeInsets.zero,
            children: [
              ServerRow(
                key: const Key('server-add-paste'),
                onTap: paste,
                leading: const ServerRowIcon(
                  AppIcons.copy,
                  tone: ServerTone.neutral,
                ),
                title: Text(
                  selected == null ? l.serversPaste : l.serversPasteAgain,
                ),
                subtitle: Text(l.serversPasteRowHint),
                chevron: true,
              ),
              ServerRow(
                key: const Key('server-add-import'),
                onTap: widget.onImport,
                leading: const ServerRowIcon(
                  AppIcons.download,
                  tone: ServerTone.neutral,
                ),
                title: Text(l.serversImportFile),
                chevron: true,
              ),
            ],
          ),
        ],
      );
    }
    return ServerFlowFrame(
      title: selected != null ? l.serversPastePreview : l.serversAddTitle,
      subtitle: selected != null
          ? l.serversPastePreviewHint
          : l.serversAddSubtitle,
      onBack: back,
      child: body,
    );
  }
}
