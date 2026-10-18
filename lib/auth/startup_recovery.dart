/// Safe recovery facts; exception details can contain credentials and are not
/// part of the startup UI. Paths identify the retained files on this machine.
class ConfigurationUpgradeFailure implements Exception {
  const ConfigurationUpgradeFailure(
    this.directory, {
    this.originalPath,
    this.backupPath,
    this.history = false,
  });
  final String directory;
  final String? originalPath;
  final String? backupPath;
  final bool history;
}
