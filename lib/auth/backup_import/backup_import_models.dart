import '../server_import_models.dart';

export 'backup_import_keys.dart';

/// Container formats recognized by the backup import parser.
enum BackupImportFormat {
  hillsBackupJson,
  rodelCommonConfig,
  rodelBackupPackage,
}

/// Whole-file outcome. Every status except [ready] yields zero drafts, so an
/// unrecognizable, corrupt or undecryptable backup can never cause a write.
enum BackupImportContainerStatus {
  ready,
  unrecognizedFormat,
  corruptContainer,
  unsupportedVersion,
  decryptionKeyUnavailable,
  undecryptablePayload,
  sizeLimitExceeded,
}

/// Per-record outcome inside a structurally valid container.
enum BackupRecordStatus { ready, skippedNonTarget, invalid }

/// Safe classifications only; never parser diagnostics, addresses or
/// credentials from the backup.
enum BackupRecordReason {
  nonTargetServerType,
  missingRequiredFields,
  malformedRecord,
  undecryptableRecord,
}

class BackupRecordOutcome {
  const BackupRecordOutcome({
    required this.index,
    required this.status,
    this.reason,
    this.draft,
  });

  final int index;
  final BackupRecordStatus status;
  final BackupRecordReason? reason;

  /// Non-null exactly when [status] is [BackupRecordStatus.ready].
  final ServerImportDraft? draft;
}

class BackupImportParseResult {
  const BackupImportParseResult({
    required this.format,
    required this.status,
    this.records = const <BackupRecordOutcome>[],
  });

  /// The recognized format, or null when detection failed entirely.
  final BackupImportFormat? format;
  final BackupImportContainerStatus status;
  final List<BackupRecordOutcome> records;

  bool get hasDrafts =>
      records.any((record) => record.status == BackupRecordStatus.ready);

  int count(BackupRecordStatus status) =>
      records.where((record) => record.status == status).length;

  /// Drafts for commit through the existing import registry, in backup order.
  Iterable<ServerImportDraft> get drafts sync* {
    for (final record in records) {
      if (record.status == BackupRecordStatus.ready) {
        yield record.draft!;
      }
    }
  }
}

/// Bounds for untrusted input. Archive entries are decoded in memory only and
/// never extracted to the file system.
class BackupImportLimits {
  const BackupImportLimits({
    this.maxInputBytes = 32 << 20,
    this.maxArchiveEntries = 128,
    this.maxArchiveEntryBytes = 16 << 20,
  });

  final int maxInputBytes;
  final int maxArchiveEntries;
  final int maxArchiveEntryBytes;
}
