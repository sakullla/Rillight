import 'credential_store.dart';

/// Format adapters produce these values only after recognizing the container.
/// Source IDs never become local configuration IDs or verified server IDs.
class ServerImportDraft {
  const ServerImportDraft({
    required this.name,
    required this.username,
    required this.lines,
    this.credentials,
    this.userAgent,
    this.isPrivate = false,
  });

  final String name;
  final String username;

  /// First entry is the primary line. The registry owns new line IDs.
  final List<ServerImportLine> lines;
  final StoredCredentials? credentials;
  final String? userAgent;
  final bool isPrivate;
}

class ServerImportLine {
  const ServerImportLine({required this.address, this.name});
  final String address;
  final String? name;
}

enum ServerImportStatus { added, duplicate, skipped, failed }

/// Safe classifications, never parser diagnostics, addresses or credentials.
enum ServerImportReason {
  privateAccessRequired,
  invalidConfiguration,
  unsupportedConnectionOptions,
  accessRevoked,
  persistenceFailed,
  rollbackFailed,
}

class ServerImportItemResult {
  const ServerImportItemResult({
    required this.index,
    required this.status,
    this.serverId,
    this.reason,
  });
  final int index;
  final ServerImportStatus status;
  final String? serverId;
  final ServerImportReason? reason;
}

class ServerImportResult {
  ServerImportResult(Iterable<ServerImportItemResult> items)
    : items = List.unmodifiable(items);
  final List<ServerImportItemResult> items;
  int count(ServerImportStatus status) =>
      items.where((item) => item.status == status).length;
}
