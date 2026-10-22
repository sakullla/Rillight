import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../media_server/server_address.dart';
import 'server_flow_frame.dart';
import 'server_list_store.dart';
import '../app/ui/app_icons.dart';
import 'server_ui.dart';

/// Add or edit one line inside the server editor.
///
/// The surrounding [ServerFlowFrame] already titles the step ("添加线路" /
/// "编辑线路"), so the fields sit in an untitled card. An invalid or duplicate
/// address is reported under the address field and keeps the form open.
/// "完成" only returns the line to the editor draft; nothing is written until
/// the server form is saved.
class ServerLineFields extends StatefulWidget {
  const ServerLineFields({
    super.key,
    this.line,
    required this.onDone,
    required this.onCancel,
    required this.otherLines,
  });
  final ServerLine? line;
  final List<ServerLine> otherLines;
  final ValueChanged<ServerLine> onDone;

  /// Leaves the step without changing the draft; same as the frame's back.
  final VoidCallback onCancel;
  @override
  State<ServerLineFields> createState() => ServerLineFieldsState();
}

class ServerLineFieldsState extends State<ServerLineFields> {
  static const cancelKey = Key('server-line-cancel');
  static const doneKey = Key('server-line-done');

  final name = TextEditingController(), address = TextEditingController();

  /// Address problem shown under the address field.
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

  /// Clears a reported problem once the user edits the address again.
  void addressChanged([String? _]) {
    if (error != null) setState(() => error = null);
  }

  void done() {
    final l = AppLocalizations.of(context);
    final String normalized;
    try {
      normalized = normalizeServerAddress(address.text).toString();
    } catch (_) {
      setState(() => error = l.errorInvalidAddress);
      return;
    }
    final duplicate = widget.otherLines.any((other) {
      if (other.id == widget.line?.id) return false;
      try {
        return normalizeServerAddress(other.address).toString() == normalized;
      } catch (_) {
        return false;
      }
    });
    if (duplicate) {
      setState(() => error = l.serversLineDuplicate);
      return;
    }
    widget.onDone(
      ServerLine(
        id: widget.line?.id ?? generateLineId(),
        address: normalized,
        nickname: name.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final compact = ServerPanelScope.maybeOf(context)?.compact ?? theme.phone;
    final cancel = AppActionButton(
      key: cancelKey,
      tier: AppActionTier.tertiary,
      onPressed: widget.onCancel,
      label: l.serversCancel,
    );
    final confirm = AppActionButton(
      key: doneKey,
      tier: AppActionTier.primary,
      onPressed: done,
      icon: AppIcons.check,
      label: l.serversDone,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServerSectionCard(
          title: null,
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
              onChanged: addressChanged,
              errorText: error,
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
        Row(
          children: [
            Icon(
              AppIcons.info,
              size: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.serversLineDraftHint,
                key: const Key('server-line-draft-hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (compact)
          Row(
            children: [
              Expanded(child: cancel),
              const SizedBox(width: 10),
              Expanded(child: confirm),
            ],
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [cancel, const SizedBox(width: 8), confirm],
          ),
      ],
    );
  }
}
