import 'dart:async';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'server_management_widgets.dart';

class ServerPasswordDraft {
  ServerPasswordDraft({
    required this.enabled,
    required this.password,
    required this.confirmation,
    required this.oldPassword,
  });
  final bool enabled;
  final String password, confirmation, oldPassword;
}

class ServerPasswordFields extends StatefulWidget {
  const ServerPasswordFields({
    super.key,
    required this.protected,
    required this.onDone,
    this.initial,
  });
  final bool protected;
  final ServerPasswordDraft? initial;
  final ValueChanged<ServerPasswordDraft> onDone;
  @override
  State<ServerPasswordFields> createState() => _ServerPasswordFieldsState();
}

class _ServerPasswordFieldsState extends State<ServerPasswordFields> {
  final old = TextEditingController(),
      password = TextEditingController(),
      confirmation = TextEditingController();
  late bool enabled;
  String? error;
  @override
  void initState() {
    super.initState();
    enabled = widget.initial?.enabled ?? true;
    old.text = widget.initial?.oldPassword ?? '';
    password.text = widget.initial?.password ?? '';
    confirmation.text = widget.initial?.confirmation ?? '';
  }

  @override
  void dispose() {
    old.dispose();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  void done() {
    final l = AppLocalizations.of(context);
    if (enabled && (password.text.isEmpty || password.text.length > 1024)) {
      setState(() => error = l.serversPasswordRequired);
      return;
    }
    if (enabled && password.text != confirmation.text) {
      setState(() => error = l.serversPasswordMismatch);
      return;
    }
    if (widget.protected && old.text.isEmpty) {
      setState(() => error = l.serversPasswordOld);
      return;
    }
    widget.onDone(
      ServerPasswordDraft(
        enabled: enabled,
        password: password.text,
        confirmation: confirmation.text,
        oldPassword: old.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget field(String key, TextEditingController controller, String label) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: AppTextField(
            key: Key(key),
            controller: controller,
            label: label,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.serversPasswordHint),
        const SizedBox(height: 20),
        if (widget.protected) ...[
          AppSwitchTile(
            title: Text(l.serversPassword),
            value: enabled,
            onChanged: (value) => setState(() => enabled = value == true),
          ),
          const SizedBox(height: 16),
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
        Text(
          l.serversPasswordPending,
          style: AppUiTheme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        AppButton(
          key: const Key('server-password-done'),
          onPressed: done,
          variant: AppButtonVariant.filled,
          child: Text(l.serversDone),
        ),
      ],
    );
  }
}

class ServerUnlockForm extends StatefulWidget {
  const ServerUnlockForm({
    super.key,
    required this.onSubmit,
    this.error,
    this.busy = false,
    this.unavailable = false,
    this.retryAt,
    this.clock,
  });
  final ValueChanged<String> onSubmit;
  final String? error;
  final bool busy, unavailable;
  final DateTime? retryAt;
  final DateTime Function()? clock;
  @override
  State<ServerUnlockForm> createState() => _ServerUnlockFormState();
}

class _ServerUnlockFormState extends State<ServerUnlockForm> {
  final password = TextEditingController();
  Timer? timer;
  DateTime get now => widget.clock?.call() ?? DateTime.now();
  int get remaining => widget.retryAt == null
      ? 0
      : (widget.retryAt!.difference(now).inMilliseconds / 1000).ceil().clamp(
          0,
          60,
        );
  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(ServerUnlockForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryAt != widget.retryAt) schedule();
  }

  void schedule() {
    timer?.cancel();
    if (remaining <= 0) return;
    timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {});
      if (remaining <= 0) {
        timer?.cancel();
        timer = null;
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Center(child: Icon(AppIcons.lock, size: 44)),
        const SizedBox(height: 24),
        Text(
          widget.unavailable
              ? l.serversPasswordUnavailable
              : l.serversPasswordPrompt,
        ),
        const SizedBox(height: 24),
        if (!widget.unavailable) ...[
          AppTextField(
            key: const Key('server-unlock-password'),
            controller: password,
            label: l.serversPasswordInput,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: widget.busy || remaining > 0 ? null : widget.onSubmit,
          ),
          const SizedBox(height: 20),
          AppButton(
            key: const Key('server-unlock-submit'),
            onPressed: widget.busy || remaining > 0
                ? null
                : () => widget.onSubmit(password.text),
            variant: AppButtonVariant.filled,
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
