import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/failure_message.dart';

/// 修改当前登录用户的密码。
///
/// 旧密码可留空照常提交,由服务器决定是否要求;新密码需确认一致。
/// 服务器拒绝时留在对话框内显示原因,输入保留;成功后关闭对话框。
/// 服务器吊销会话时控制器会回到登录页,本机保存的新密码可直接重新进入。
/// 电视呈现把输入和确认取消放进同一纵向焦点序列;手机与桌面仍用文本框和
/// Material 按钮。
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key, required this.auth});

  final AuthController auth;

  static const currentPasswordField = Key('change-password-current');
  static const newPasswordField = Key('change-password-new');
  static const confirmField = Key('change-password-confirm');
  static const submitKey = Key('change-password-submit');
  static const cancelKey = Key('change-password-cancel');
  static const failureKey = Key('change-password-failure');

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _current = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 电视编辑框改的是同一控制器,父级要跟着刷新可否提交。
    _newPassword.addListener(_onPasswordEdited);
    _confirm.addListener(_onPasswordEdited);
  }

  void _onPasswordEdited() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _newPassword.removeListener(_onPasswordEdited);
    _confirm.removeListener(_onPasswordEdited);
    _current.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool _isTv(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<PresentationScope>()
            ?.environment
            .isTv ??
        false;
  }

  Future<void> _submit() async {
    final newPassword = _newPassword.text;
    if (newPassword.isEmpty || _confirm.text != newPassword) {
      return;
    }
    final changed = await widget.auth.changePassword(
      currentPassword: _current.text,
      newPassword: newPassword,
    );
    if (!mounted || !changed) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = widget.auth;
    final tv = _isTv(context);
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final failure = auth.passwordChangeFailure;
        final mismatch =
            _confirm.text.isNotEmpty && _confirm.text != _newPassword.text;
        final canSubmit =
            !auth.isBusy && _newPassword.text.isNotEmpty && !mismatch;
        return AlertDialog(
          title: Text(l10n.changePassword),
          content: SizedBox(
            width: tv
                ? context.tvdp(420)
                : AppViewport.fit(
                    360,
                    MediaQuery.sizeOf(context).width - 80,
                    MediaQuery.sizeOf(context),
                  ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (tv)
                    ..._tvFields(l10n, mismatch)
                  else ...[
                    TextField(
                      key: ChangePasswordDialog.currentPasswordField,
                      controller: _current,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: l10n.changePasswordCurrent,
                        helperText: l10n.changePasswordCurrentHint,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: ChangePasswordDialog.newPasswordField,
                      controller: _newPassword,
                      obscureText: true,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.changePasswordNew,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: ChangePasswordDialog.confirmField,
                      controller: _confirm,
                      obscureText: true,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.changePasswordConfirm,
                        errorText: mismatch
                            ? l10n.changePasswordMismatch
                            : null,
                      ),
                    ),
                  ],
                  if (failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        embyFailureMessage(l10n, failure),
                        key: ChangePasswordDialog.failureKey,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (tv) ...[
                    SizedBox(height: context.tvdp(16)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TvAction(
                          key: ChangePasswordDialog.cancelKey,
                          pill: true,
                          onPressed: auth.isBusy
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: Text(l10n.cancelAction),
                        ),
                        SizedBox(width: context.tvdp(10)),
                        TvAction(
                          key: ChangePasswordDialog.submitKey,
                          pill: true,
                          emphasized: true,
                          onPressed: canSubmit ? _submit : null,
                          child: auth.isBusy
                              ? SizedBox.square(
                                  dimension: context.tvdp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10n.changePasswordSubmit),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: tv
              ? null
              : [
                  TextButton(
                    key: ChangePasswordDialog.cancelKey,
                    onPressed: auth.isBusy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(l10n.cancelAction),
                  ),
                  FilledButton(
                    key: ChangePasswordDialog.submitKey,
                    onPressed: canSubmit ? _submit : null,
                    child: auth.isBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.changePasswordSubmit),
                  ),
                ],
        );
      },
    );
  }

  List<Widget> _tvFields(AppLocalizations l10n, bool mismatch) {
    return [
      TvInput(
        key: ChangePasswordDialog.currentPasswordField,
        label: l10n.changePasswordCurrent,
        controller: _current,
        secret: true,
        autofocus: true,
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(
          context.tvdp(4),
          context.tvdp(6),
          0,
          context.tvdp(12),
        ),
        child: Text(
          l10n.changePasswordCurrentHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      TvInput(
        key: ChangePasswordDialog.newPasswordField,
        label: l10n.changePasswordNew,
        controller: _newPassword,
        secret: true,
      ),
      SizedBox(height: context.tvdp(8)),
      TvInput(
        key: ChangePasswordDialog.confirmField,
        label: l10n.changePasswordConfirm,
        controller: _confirm,
        secret: true,
      ),
      if (mismatch)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            l10n.changePasswordMismatch,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ];
  }
}
