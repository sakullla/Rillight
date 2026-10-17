import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';
import 'server_password_form.dart';
import 'server_management_widgets.dart';

/// TV presentation reuses the password draft validation and retry clock.
class TvServerUnlockForm extends ServerUnlockForm {
  const TvServerUnlockForm({
    super.key,
    required super.onSubmit,
    super.error,
    super.busy,
    super.unavailable,
    super.retryAt,
  });
  @override
  State<ServerUnlockForm> createState() => _TvUnlockState();
}

class _TvUnlockState extends ServerUnlockFormState {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.unavailable
              ? l.serversPasswordUnavailable
              : l.serversPasswordPrompt,
        ),
        const SizedBox(height: 20),
        if (!widget.unavailable) ...[
          TvInput(
            key: const Key('server-unlock-password'),
            label: l.serversPasswordInput,
            controller: password,
            secret: true,
            autofocus: true,
          ),
          const SizedBox(height: 20),
          TvAction(
            key: const Key('server-unlock-submit'),
            emphasized: true,
            onPressed: widget.busy || remaining > 0
                ? null
                : () => widget.onSubmit(password.text),
            child: Text(
              remaining > 0
                  ? l.serversPasswordRetryAfter(remaining)
                  : widget.busy
                  ? l.serversBusy
                  : l.serversEnter,
            ),
          ),
        ],
        if (widget.error != null) ServerFeedback(widget.error!),
      ],
    );
  }
}

class TvServerPasswordFields extends ServerPasswordFields {
  const TvServerPasswordFields({
    super.key,
    required super.protected,
    required super.onDone,
    super.initial,
  });
  @override
  State<ServerPasswordFields> createState() => _TvPasswordState();
}

class _TvPasswordState extends ServerPasswordFieldsState {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget field(String key, TextEditingController value, String label) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TvInput(
            key: Key(key),
            label: label,
            controller: value,
            autofocus:
                key ==
                (widget.protected
                    ? 'server-password-old'
                    : 'server-password-new'),
            secret: true,
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.serversPasswordHint),
        const SizedBox(height: 16),
        if (widget.protected) ...[
          TvChoiceTile(
            label: l.serversPassword,
            selected: enabled,
            onPressed: () => setState(() => enabled = !enabled),
          ),
          const SizedBox(height: 12),
          field('server-password-old', old, l.serversPasswordOld),
        ],
        if (enabled) ...[
          field('server-password-new', password, l.serversPasswordNew),
          field(
            'server-password-confirm',
            confirmation,
            l.serversPasswordConfirm,
          ),
        ],
        if (error != null) ServerFeedback(error!),
        Text(l.serversPasswordPending),
        const SizedBox(height: 16),
        TvAction(
          key: const Key('server-password-done'),
          onPressed: done,
          emphasized: true,
          child: Text(l.serversDone),
        ),
      ],
    );
  }
}
