/// Decryption material for the source formats. The repository itself ships no
/// third-party client key constant; the embedder provisions verified keys
/// through an authorized channel, and a missing key is reported as
/// `decryptionKeyUnavailable` instead of being
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

  /// Candidate 16-byte AES-128 keys for the `.rpb` `config.json` payload
  /// (`base64(IV || AES-128-CBC(PKCS7))`). The real client key constant is
  /// provisioned through an authorized runtime channel and never committed;
  /// without a key the parse reports `decryptionKeyUnavailable`
  /// rather than an empty success.
  final List<List<int>> rodelBackupConfigKeys;
}
