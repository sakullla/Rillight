import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_runtime.dart';
import '../emby/fake_emby_server.dart';

/// Full-app fixtures explicitly declare their synthetic libraries and use
/// independent registry clients. This never changes production unknown scope.
class SyntheticSourceAuth extends AuthController {
  SyntheticSourceAuth._({
    required super.client,
    required super.credentials,
    required super.servers,
    required super.sources,
    required this.libraryIds,
  });
  factory SyntheticSourceAuth({
    required FakeEmbyAdapter adapter,
    required EmbyDeviceInfo device,
    required Set<String> libraryIds,
  }) {
    final credentials = MemoryCredentialStore();
    final store = MemoryServerListStore();
    EmbyClient client() =>
        EmbyClient(device: device, dio: dioForFakeEmby(adapter));
    final sources = SourceSessionRegistry(
      access: RegionAccessController(),
      store: store,
      credentials: credentials,
      createClient: client,
    );
    return SyntheticSourceAuth._(
      client: client(),
      credentials: credentials,
      servers: store,
      sources: sources,
      libraryIds: Set.unmodifiable(libraryIds),
    );
  }
  final Set<String> libraryIds;
  @override
  Future<bool> connect({
    required String address,
    required String username,
    required String password,
    String? userAgent,
    String? lineId,
    bool preserveSessionOnFailure = false,
  }) async {
    final result = await super.connect(
      address: address,
      username: username,
      password: password,
      userAgent: userAgent,
      lineId: lineId,
      preserveSessionOnFailure: preserveSessionOnFailure,
    );
    if (result && session != null) {
      final server = sources
          .project(AccessRegion.ordinary)
          .firstWhere((s) => s.id == session!.server.id);
      if (!server.scopeKnown) {
        await sources.configureScope(
          server.id,
          participates: true,
          libraryIds: libraryIds,
        );
      }
    }
    return result;
  }

  Future<PlaybackRuntime> runtime() async {
    await sources.load();
    return PlaybackRuntime(
      auth: this,
      history: await HistoryWriter.open(
        registry: sources,
        store: MemoryHistoryStore(),
      ),
    );
  }
}
