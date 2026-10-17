import 'server_import_models.dart';
import 'source_sessions.dart';

/// The registry owns both persistence and access checks; this facade does not
/// hold another server list or connect to any address found in a backup.
class ServerImportService {
  const ServerImportService(this.sources);
  final SourceSessionRegistry sources;

  Future<ServerImportResult> commit(Iterable<ServerImportDraft> drafts) =>
      sources.importServers(drafts);
}
