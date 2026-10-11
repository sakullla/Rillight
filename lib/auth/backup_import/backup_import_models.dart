import '../server_import_models.dart';

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

/// Decryption material for the source formats. The repository itself ships no
/// third-party client key constant; the embedder provisions verified keys
/// through an authorized channel, and a missing key is reported as
/// [BackupImportContainerStatus.decryptionKeyUnavailable] instead of being
/// treated as an empty successful parse.
class BackupImportKeys {
  const BackupImportKeys({
    this.hillsDataKey,
    this.rodelCommonKeysBySource = const <String, List<int>>{},
    this.rodelBackupConfigKeys = const <List<int>>[],
  });

  /// 32-byte AES-256 key for the Hills backup JSON `data` payload.
  final List<int>? hillsDataKey;

  /// AES-256 keys for common-config exports, keyed by the `from` source name.
  /// A self-carried `_key` entry in the file itself takes precedence.
  final Map<String, List<int>> rodelCommonKeysBySource;

  /// Candidate AES-256 keys for the `.rpb` `config.json` payload. The native
  /// key for that entry is not yet available, so this list stays empty until
  /// an authorized source provides one.
  final List<List<int>> rodelBackupConfigKeys;
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
