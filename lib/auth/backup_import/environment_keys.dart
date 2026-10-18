import 'backup_import_keys.dart';

/// Builds the default [BackupImportKeys] for a release build from
/// `--dart-define` hex constants. CI injects the constants from repository
/// secrets; without defines every key stays absent and imports report
/// `decryptionKeyUnavailable` instead of failing silently.
BackupImportKeys buildEnvironmentBackupImportKeys({
  String hillsHex = '',
  String commonHex = '',
  String rpbHex = '',
}) {
  final hills = _hexBytesOrNull(hillsHex);
  final common = _hexBytesOrNull(commonHex);
  final rpb = _hexBytesOrNull(rpbHex);
  return BackupImportKeys(
    hillsDataKey: hills,
    rodelCommonKeysBySource: common == null || common.isEmpty
        ? const <String, List<int>>{}
        : <String, List<int>>{'RodelPlayer': common},
    rodelBackupConfigKeys: rpb == null || rpb.isEmpty
        ? const <List<int>>[]
        : <List<int>>[rpb],
  );
}

/// Release builds carry the keys as compile-time defines; the values are
/// provisioned from repository secrets and never committed.
final defaultBackupImportKeys = buildEnvironmentBackupImportKeys(
  hillsHex: const String.fromEnvironment('RILLIGHT_HILLS_KEY'),
  commonHex: const String.fromEnvironment('RILLIGHT_COMMON_KEY'),
  rpbHex: const String.fromEnvironment('RILLIGHT_RPB_KEY'),
);

List<int>? _hexBytesOrNull(String hex) {
  if (hex.isEmpty) return null;
  if (hex.length.isOdd) return null;
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final hi = _hexDigit(hex.codeUnitAt(i));
    final lo = _hexDigit(hex.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) return null;
    out.add(hi * 16 + lo);
  }
  return out;
}

int _hexDigit(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x57;
  if (code >= 0x41 && code <= 0x46) return code - 0x37;
  return -1;
}
