import 'dart:async';
import 'dart:typed_data';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/backup_import/backup_import.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';
import 'package:rillight/auth/server_import_models.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 三端共用的备份导入流程:T2 文件读取边界 → T4 解析 → T3 提交服务,
/// 结果面板逐类列出新增/重复/非目标/失败/私密跳过与待登录数量。
/// 取消与整体解析失败不触碰任何已有配置、凭据与活动会话。
abstract final class BackupImportFlowKeys {
  static const loading = Key('backup-import-loading');
  static const result = Key('backup-import-result');
  static const failure = Key('backup-import-failure');
  static const failureMessage = Key('backup-import-failure-message');
  static const close = Key('backup-import-close');
  static const added = Key('backup-import-result-added');
  static const pendingLogin = Key('backup-import-result-pending');
  static const duplicate = Key('backup-import-result-duplicate');
  static const nonTarget = Key('backup-import-result-non-target');
  static const failed = Key('backup-import-result-failed');
  static const privateSkipped = Key('backup-import-result-private');
}

/// 备份文件选择器接受的扩展名;识别以容器内容为准,扩展名只用于筛选。
const kBackupImportExtensions = <String>['json', 'rpb'];

enum BackupImportFlowStatus {
  /// 用户在系统文件选择器中取消;不提示、不改动任何状态。
  cancelled,

  /// 设备没有可处理文档选择的 provider(常见于部分电视)。
  pickerUnavailable,

  /// 文件超过解析上限。
  tooLarge,

  /// 文件读取失败。
  unreadable,

  /// 容器损坏/未知/不可解密等整体失败;零写入。
  containerRejected,

  /// 解析完成;有草稿时已提交,全部记录结果逐项可见。
  committed,
}

class BackupImportFlowOutcome {
  const BackupImportFlowOutcome({
    required this.status,
    this.containerStatus,
    this.parse,
    this.commit,
  });

  final BackupImportFlowStatus status;
  final BackupImportContainerStatus? containerStatus;
  final BackupImportParseResult? parse;
  final ServerImportResult? commit;

  int get added => commit?.count(ServerImportStatus.added) ?? 0;
  int get duplicate => commit?.count(ServerImportStatus.duplicate) ?? 0;
  int get nonTarget => parse?.count(BackupRecordStatus.skippedNonTarget) ?? 0;
  int get invalidRecords => parse?.count(BackupRecordStatus.invalid) ?? 0;
  int get failedRecords =>
      (commit?.count(ServerImportStatus.failed) ?? 0) + invalidRecords;
  int get privateSkipped => commit?.count(ServerImportStatus.skipped) ?? 0;

  /// 新增里没有可用凭据、需要用户连接时登录的数量;与已带凭据区分展示。
  int get pendingLogin {
    final commit = this.commit;
    final drafts = parse?.drafts.toList() ?? const <ServerImportDraft>[];
    if (commit == null) return 0;
    var count = 0;
    for (final item in commit.items) {
      if (item.status != ServerImportStatus.added) continue;
      if (item.index < drafts.length &&
          drafts[item.index].credentials == null) {
        count++;
      }
    }
    return count;
  }

  int get credentialsReady => added - pendingLogin;

  List<ServerImportReason> get failureReasons {
    final commit = this.commit;
    if (commit == null) return const <ServerImportReason>[];
    return <ServerImportReason>{
      for (final item in commit.items)
        if (item.status == ServerImportStatus.failed && item.reason != null)
          item.reason!,
    }.toList();
  }
}

/// 读取并解析已选中的备份文件,有草稿时经 [commit] 提交。
/// 该函数不触碰任何 store;提交语义完全由调用方注入的提交服务决定。
Future<BackupImportFlowOutcome> parseAndCommitBackup(
  PickedAppFile file, {
  required Future<ServerImportResult> Function(
    Iterable<ServerImportDraft> drafts,
  )
  commit,
  BackupImportKeys keys = const BackupImportKeys(),
  BackupImportLimits limits = const BackupImportLimits(),
}) async {
  final Uint8List bytes;
  try {
    bytes = await file.readBytes(limits.maxInputBytes);
  } on AppFileTooLargeException {
    return const BackupImportFlowOutcome(
      status: BackupImportFlowStatus.tooLarge,
    );
  } on AppFileReadException {
    return const BackupImportFlowOutcome(
      status: BackupImportFlowStatus.unreadable,
    );
  }
  final parse = await parseBackupForImport(bytes, keys: keys, limits: limits);
  if (parse.status != BackupImportContainerStatus.ready) {
    return BackupImportFlowOutcome(
      status: BackupImportFlowStatus.containerRejected,
      containerStatus: parse.status,
      parse: parse,
    );
  }
  if (!parse.hasDrafts) {
    return BackupImportFlowOutcome(
      status: BackupImportFlowStatus.committed,
      parse: parse,
    );
  }
  final committed = await commit(parse.drafts);
  return BackupImportFlowOutcome(
    status: BackupImportFlowStatus.committed,
    parse: parse,
    commit: committed,
  );
}

/// 完整 UI 流程:选择 → 读取/解析/提交 → 结果面板。
/// 取消时静默返回;其余结果经 [BackupImportResultDialog] 反馈。
///
/// 对话框挂在根导航上;发起页面在导入过程中被重建或卸载(例如顶部栏
/// 随 auth 通知换树)时,加载与结果面板仍能正确关闭和出现。
Future<void> showBackupImportFlow(
  BuildContext context, {
  required AuthController auth,
  AppFilePicker? picker,
  BackupImportLimits limits = const BackupImportLimits(),
}) async {
  final l10n = AppLocalizations.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final selection =
      picker ?? auth.backupImportPicker ?? const DefaultAppFilePicker();
  PickedAppFile? picked;
  try {
    picked = await selection.pickFile(
      dialogTitle: l10n.backupImportPickerTitle,
      allowedExtensions: kBackupImportExtensions,
    );
  } on AppFilePickerUnavailableException {
    await _showOutcome(
      navigator,
      const BackupImportFlowOutcome(
        status: BackupImportFlowStatus.pickerUnavailable,
      ),
    );
    return;
  }
  if (picked == null) return;
  // 读取、解析与提交期间给出明确的加载态;与系统选择器不同时出现。
  // 根导航常驻,其 context 不随发起页面卸载失效。
  unawaited(
    showAppDialog<void>(
      // ignore: use_build_context_synchronously
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => const BackupImportWorkingDialog(),
    ),
  );
  final outcome = await parseAndCommitBackup(
    picked,
    keys: auth.backupImportKeys,
    limits: limits,
    commit: (drafts) => auth.importServers(drafts),
  );
  navigator.pop();
  await _showOutcome(navigator, outcome);
}

Future<void> _showOutcome(
  NavigatorState navigator,
  BackupImportFlowOutcome outcome,
) {
  return showAppDialog<void>(
    context: navigator.context,
    builder: (_) => BackupImportResultDialog(outcome: outcome),
  );
}

/// 读取/解析/提交中的加载态;不可点击穿透关闭。
class BackupImportWorkingDialog extends StatelessWidget {
  const BackupImportWorkingDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: AppDialog(
        key: BackupImportFlowKeys.loading,
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CupertinoActivityIndicator(),
            ),
            const SizedBox(width: 16),
            Text(l10n.backupImportWorking),
          ],
        ),
      ),
    );
  }
}

/// 结果面板:提交类结果逐类计数,整体失败给出安全分类原因。
/// 关闭按钮自动聚焦,电视遥控出现面板后可直接确认返回。
class BackupImportResultDialog extends StatelessWidget {
  const BackupImportResultDialog({super.key, required this.outcome});

  final BackupImportFlowOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final committed = outcome.status == BackupImportFlowStatus.committed;
    return AppDialog(
      key: committed
          ? BackupImportFlowKeys.result
          : BackupImportFlowKeys.failure,
      title: Text(
        committed
            ? l10n.backupImportResultTitle
            : l10n.backupImportFailureTitle,
      ),
      content: SizedBox(
        width: 420,
        child: committed ? _summary(context, l10n) : _failure(l10n),
      ),
      actions: [
        AppButton(
          key: BackupImportFlowKeys.close,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.backupImportClose),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context, AppLocalizations l10n) {
    final scheme = AppUiTheme.of(context).colorScheme;
    Widget row(Key key, IconData icon, String text, {Color? color}) => Row(
      children: [
        Icon(
          icon,
          fill: AppIcons.filled,
          size: 18,
          color: color ?? scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, key: key)),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          BackupImportFlowKeys.added,
          AppIcons.link,
          l10n.backupImportAddedCount(outcome.added),
        ),
        if (outcome.added > 0) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(
              '${l10n.backupImportCredentialsReady(outcome.credentialsReady)}'
              ' · ${l10n.backupImportPendingLogin(outcome.pendingLogin)}',
              key: BackupImportFlowKeys.pendingLogin,
              style: AppUiTheme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        if (outcome.duplicate > 0) ...[
          const SizedBox(height: 6),
          row(
            BackupImportFlowKeys.duplicate,
            AppIcons.copy,
            l10n.backupImportDuplicateCount(outcome.duplicate),
          ),
        ],
        if (outcome.nonTarget > 0) ...[
          const SizedBox(height: 6),
          row(
            BackupImportFlowKeys.nonTarget,
            AppIcons.block,
            l10n.backupImportNonTargetCount(outcome.nonTarget),
          ),
        ],
        if (outcome.privateSkipped > 0) ...[
          const SizedBox(height: 6),
          row(
            BackupImportFlowKeys.privateSkipped,
            AppIcons.lock,
            l10n.backupImportPrivateSkippedCount(outcome.privateSkipped),
          ),
        ],
        if (outcome.failedRecords > 0) ...[
          const SizedBox(height: 6),
          row(
            BackupImportFlowKeys.failed,
            AppIcons.error,
            l10n.backupImportFailedCount(outcome.failedRecords),
            color: scheme.error,
          ),
          for (final reason in outcome.failureReasons)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 4),
              child: Text(
                _commitReason(l10n, reason),
                style: AppUiTheme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          if (outcome.invalidRecords > 0)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 4),
              child: Text(
                l10n.backupImportReasonMissingFields,
                style: AppUiTheme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ],
    );
  }

  Widget _failure(AppLocalizations l10n) {
    return Text(
      _failureMessage(l10n),
      key: BackupImportFlowKeys.failureMessage,
    );
  }

  String _failureMessage(AppLocalizations l10n) {
    switch (outcome.status) {
      case BackupImportFlowStatus.pickerUnavailable:
        return l10n.backupImportPickerUnavailable;
      case BackupImportFlowStatus.tooLarge:
        return l10n.backupImportTooLarge;
      case BackupImportFlowStatus.unreadable:
        return l10n.backupImportUnreadable;
      case BackupImportFlowStatus.containerRejected:
        return switch (outcome.containerStatus) {
          BackupImportContainerStatus.corruptContainer =>
            l10n.backupImportCorrupt,
          BackupImportContainerStatus.unsupportedVersion =>
            l10n.backupImportUnsupportedVersion,
          BackupImportContainerStatus.decryptionKeyUnavailable =>
            l10n.backupImportKeyUnavailable,
          BackupImportContainerStatus.undecryptablePayload =>
            l10n.backupImportUndecryptable,
          BackupImportContainerStatus.sizeLimitExceeded =>
            l10n.backupImportTooLarge,
          _ => l10n.backupImportUnrecognized,
        };
      case BackupImportFlowStatus.cancelled:
      case BackupImportFlowStatus.committed:
        return l10n.backupImportUnrecognized;
    }
  }

  String _commitReason(AppLocalizations l10n, ServerImportReason reason) {
    switch (reason) {
      case ServerImportReason.privateAccessRequired:
        return l10n.backupImportPrivateSkippedCount(1);
      case ServerImportReason.invalidConfiguration:
        return l10n.backupImportReasonInvalid;
      case ServerImportReason.unsupportedConnectionOptions:
        return l10n.backupImportReasonUnsupportedOptions;
      case ServerImportReason.accessRevoked:
        return l10n.backupImportReasonAccessRevoked;
      case ServerImportReason.persistenceFailed:
        return l10n.backupImportReasonPersistence;
      case ServerImportReason.rollbackFailed:
        return l10n.backupImportReasonRollback;
    }
  }
}
