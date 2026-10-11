import 'server_import_models.dart';
import 'server_list_store.dart';
import 'source_sessions.dart';

/// The registry owns both persistence and access checks; this facade does not
/// hold another server list or connect to any address found in a backup.
class ServerImportService {
  const ServerImportService(this.sources);
  final SourceSessionRegistry sources;

  Future<ServerImportResult> commit(
    Iterable<ServerImportDraft> drafts, {
    AccessRegion region = AccessRegion.ordinary,
  }) => sources.importServers(drafts, region: region);
}
