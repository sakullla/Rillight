import 'dart:async';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';
import 'server_management_widgets.dart';
import 'server_ui.dart';

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
  State<ServerPasswordFields> createState() => ServerPasswordFieldsState();
}

class ServerPasswordFieldsState extends State<ServerPasswordFields> {
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
    final theme = AppUiTheme.of(context);
    Widget field(
      String key,
      TextEditingController controller,
      String label, {
      bool last = false,
    }) => Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: AppTextField(
        key: Key(key),
        controller: controller,
        label: label,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: last ? (_) => done() : null,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const ServerRowIcon(AppIcons.shield, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.serversPasswordHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (widget.protected)
          ServerGroup(
            children: [
              AppSwitchTile(
                title: Text(l.serversPassword),
                value: enabled,
                onChanged: (value) => setState(() => enabled = value == true),
              ),
            ],
          ),
        ServerSectionCard(
          title: widget.protected
              ? l.serversPasswordChange
              : l.serversPasswordSet,
          children: [
            if (widget.protected)
              field(
                'server-password-old',
                old,
                l.serversPasswordOld,
                last: !enabled,
              ),
            if (enabled) ...[
              field('server-password-new', password, l.serversPasswordNew),
              field(
                'server-password-confirm',
                confirmation,
                l.serversPasswordConfirm,
                last: true,
              ),
            ],
          ],
        ),
        if (error != null) ...[
          ServerFeedback(error!),
          const SizedBox(height: 12),
        ],
        AppButton(
          key: const Key('server-password-done'),
          onPressed: done,
          variant: AppButtonVariant.filled,
          minimumSize: const Size(64, 48),
          child: Text(l.serversDone),
        ),
        const SizedBox(height: 10),
        Text(
          l.serversPasswordPending,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
    this.prompt,
    this.submitLabel,
    this.mark,
  });
  final ValueChanged<String> onSubmit;

  /// Identity of the server being unlocked; defaults to a lock glyph.
  final Widget? mark;
  final String? error;
  final String? prompt, submitLabel;
  final bool busy, unavailable;
  final DateTime? retryAt;
  final DateTime Function()? clock;
  @override
  State<ServerUnlockForm> createState() => ServerUnlockFormState();
}

class ServerUnlockFormState extends State<ServerUnlockForm> {
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
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final enabled = !widget.unavailable && remaining <= 0 && !widget.busy;
    void submit() => widget.onSubmit(password.text);
    return ServerFocusView(
      mark:
          widget.mark ??
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: .12),
            ),
            child: Icon(
              AppIcons.lock,
              size: 32,
              color: colors.primary,
              fill: AppIcons.filled,
            ),
          ),
      title: widget.unavailable ? l.serversPasswordInput : l.serversUnlockTitle,
      message: widget.unavailable
          ? l.serversPasswordUnavailable
          : widget.prompt ?? l.serversPasswordPrompt,
      children: [
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
          if (widget.error != null) ServerFeedback(widget.error!),
          const SizedBox(height: 16),
          AppButton(
            key: const Key('server-unlock-submit'),
            onPressed: widget.busy || remaining > 0 ? null : submit,
            variant: AppButtonVariant.filled,
            minimumSize: const Size(64, 50),
            child: widget.busy
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(
                        radius: 8,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Text(l.serversBusy),
                    ],
                  )
                : Text(
                    remaining > 0
                        ? l.serversPasswordRetryAfter(remaining)
                        : widget.submitLabel ?? l.serversEnter,
                  ),
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(AppIcons.shield, size: 13, color: colors.onSurfaceVariant),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    l.serversPasswordHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ] else if (widget.error != null)
          ServerFeedback(widget.error!),
      ],
    );
  }
}
