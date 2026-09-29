import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';

/// 线路地址编辑对话框:添加与修改共用,只录入地址,没有 User-Agent 输入项。
class LineAddressDialog extends StatefulWidget {
  const LineAddressDialog({super.key, this.initialAddress});

  /// 传入时为修改模式并预填现有地址;为空时为添加模式。
  final String? initialAddress;

  static const fieldKey = Key('line-address-field');

  static const submitKey = Key('line-address-submit');

  @override
  State<LineAddressDialog> createState() => _LineAddressDialogState();
}

/// 弹出线路地址编辑框;确认返回去空白后的地址,取消返回 null。
Future<String?> showLineAddressDialog(
  BuildContext context, {
  String? initialAddress,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => LineAddressDialog(initialAddress: initialAddress),
  );
}

class _LineAddressDialogState extends State<LineAddressDialog> {
  late final TextEditingController _address;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.initialAddress ?? '');
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    final value = _address.text.trim();
    if (value.isEmpty) {
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.initialAddress == null ? l10n.addLine : l10n.editLine),
      content: TextField(
        key: LineAddressDialog.fieldKey,
        controller: _address,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(context),
        decoration: InputDecoration(
          labelText: l10n.extraLineAddress,
          hintText: l10n.serverAddressHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        ListenableBuilder(
          listenable: _address,
          builder: (context, _) {
            return FilledButton(
              key: LineAddressDialog.submitKey,
              onPressed: _address.text.trim().isEmpty
                  ? null
                  : () => _submit(context),
              child: Text(l10n.lineAddressSave),
            );
          },
        ),
      ],
    );
  }
}
