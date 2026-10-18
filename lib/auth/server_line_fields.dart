import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../media_server/server_address.dart';
import 'server_list_store.dart';
import '../app/ui/app_icons.dart';
import 'server_management_widgets.dart';
import 'server_ui.dart';

class ServerLineFields extends StatefulWidget {
  const ServerLineFields({
    super.key,
    this.line,
    required this.onDone,
    required this.otherLines,
  });
  final ServerLine? line;
  final List<ServerLine> otherLines;
  final ValueChanged<ServerLine> onDone;
  @override
  State<ServerLineFields> createState() => ServerLineFieldsState();
}

class ServerLineFieldsState extends State<ServerLineFields> {
  final name = TextEditingController(), address = TextEditingController();
  String? error;
  @override
  void initState() {
    super.initState();
    name.text = widget.line?.nickname ?? '';
    address.text = widget.line?.address ?? '';
  }

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    super.dispose();
  }

  void done() {
    try {
      final normalized = normalizeServerAddress(address.text).toString();
      if (widget.otherLines.any(
        (l) =>
            l.id != widget.line?.id &&
            normalizeServerAddress(l.address).toString() == normalized,
      )) {
        throw StateError('Duplicate');
      }
      widget.onDone(
        ServerLine(
          id: widget.line?.id ?? generateLineId(),
          address: normalized,
          nickname: name.text.trim(),
        ),
      );
    } catch (_) {
      setState(() => error = AppLocalizations.of(context).serversInvalidDraft);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServerSectionCard(
          title: widget.line == null ? l.serversLineAdd : l.serversLineEdit,
          children: [
            AppTextField(
              key: const Key('server-line-address'),
              controller: address,
              label: l.serversLineAddress,
              placeholder: 'https://emby.example.com',
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: widget.line == null,
              prefix: const Icon(AppIcons.link),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            AppTextField(
              key: const Key('server-line-name'),
              controller: name,
              label: l.serversLineName,
              maxLength: 80,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => done(),
            ),
          ],
        ),
        if (error != null) ...[
          ServerFeedback(error!),
          const SizedBox(height: 14),
        ],
        AppButton(
          key: const Key('server-line-done'),
          onPressed: done,
          variant: AppButtonVariant.filled,
          minimumSize: const Size(64, 48),
          child: Text(l.serversDone),
        ),
        const SizedBox(height: 10),
        Text(
          l.serversLineDraftHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
