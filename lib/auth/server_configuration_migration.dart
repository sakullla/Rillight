import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'credential_store.dart';
import 'server_access_store.dart';
import 'server_list_store.dart';

/// Explicit source mapping for history/preferences/cache consumers. Only the
/// obsolete region is removed; local server, remote server and user never merge.
class ServerSourceMapping {
  const ServerSourceMapping(this.entries);
  final List<Map<String, dynamic>> entries;

  Map<String, dynamic> migrateSource(Map<String, dynamic> source) {
    final provider = source['serviceType'] ?? 'emby';
    if (!const ['emby', 'jellyfin', 'plex'].contains(provider) ||
        ['server', 'verifiedServer', 'user', 'item'].any(
          (key) => source[key] is! String || (source[key] as String).isEmpty,
        ) ||
        (source.containsKey('region') &&
            !const ['ordinary', 'private'].contains(source['region']))) {
      throw const FormatException('Invalid stored source identity');
    }
    // Historical accounts may differ from the currently logged-in account.
    // Removed entries also keep their original identity; never rebind by name.
    return {...source, 'serviceType': provider}..remove('region');
  }

  String migrateSourceKey(String key) {
    final value = jsonDecode(key);
    if (value is! List) {
      throw const FormatException('Invalid stored source key');
    }
    final List<Object?> legacy;
    if (value.length == 8) {
      legacy = [...value.take(3), 'ordinary', ...value.skip(3)];
    } else if (value.length == 6) {
      legacy = ['emby', null, null, ...value];
    } else if (value.length == 9) {
      legacy = value;
    } else {
      throw const FormatException('Invalid stored source key');
    }
    migrateSource({
      'serviceType': legacy[0],
      'cloudAccountId': legacy[1],
      'homeUserId': legacy[2],
      'region': legacy[3],
      'server': legacy[4],
      'verifiedServer': legacy[5],
      'user': legacy[6],
      'item': legacy[7],
      'version': legacy[8],
    });
    return jsonEncode([...legacy.take(3), ...legacy.skip(4)]);
  }

  /// Builds a new document without writing or mutating the source. T5 publishes
  /// this with the new history reader, never through the old region consumer.
  Map<String, dynamic> migrateHistory(Map<String, dynamic> history) {
    final result = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(history)) as Map,
    );
    if (result['version'] != 1 ||
        result['records'] is! List ||
        result['preferences'] is! List) {
      throw const FormatException('Invalid history configuration');
    }
    for (final group in ['records', 'preferences']) {
      final seen = <String>{};
      for (final raw in result[group] as List) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Invalid history entry');
        }
        final fields = group == 'records'
            ? ['source', 'work']
            : ['owner', 'target'];
        for (final field in fields) {
          raw[field] = migrateSource(
            Map<String, dynamic>.from(raw[field] as Map),
          );
        }
        final source = raw[fields.first] as Map;
        final identity = jsonEncode([
          source['serviceType'],
          source['cloudAccountId'],
          source['homeUserId'],
          source['server'],
          source['verifiedServer'],
          source['user'],
          source['item'],
          source['version'],
        ]);
        if (!seen.add(identity)) {
          // Two old regions with the exact same account must be resolved by
          // migration policy, never last-write-wins in a map reader.
          throw const FormatException(
            'Conflicting historical source identities',
          );
        }
      }
    }
    result['sourceIdentityVersion'] = 2;
    return result;
  }
}

class ServerMigrationResult {
  const ServerMigrationResult({
    required this.snapshot,
    required this.sources,
    required this.unavailableProtectionIds,
  });
  final ServerListSnapshot snapshot;
  final ServerSourceMapping sources;
  final List<String> unavailableProtectionIds;
}

/// Startup-only migration. The caller must await completion before mounting
/// registries/content. No existing credentials or history files are rewritten.
/// Journal + original bytes survive failure, including a crash after publish.
class ServerConfigurationMigration {
  ServerConfigurationMigration({
    required this.configuration,
    required this.credentials,
    required this.accessStore,
    required this.readLegacyVerifier,
    this.checkpoint,
  });
  final File configuration;
  final CredentialStore credentials;
  final ServerAccessStore accessStore;
  final Future<Map<String, dynamic>?> Function() readLegacyVerifier;

  /// Fault injection / observable startup progress, never a commit authority.
  final Future<void> Function(String step)? checkpoint;
  File get backup => File('${configuration.path}.pre-v4');
  File get journal => File('${configuration.path}.migration-v4.json');
  Future<ServerMigrationResult>? _running;
  static final Set<String> _activePaths = {};

  Future<ServerMigrationResult> migrate() =>
      _running ??= _run().whenComplete(() {
        _running = null;
      });

  Future<String> _digest(String text) async =>
      base64Encode((await Sha256().hash(utf8.encode(text))).bytes);

  Future<void> _replace(File file, String text) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.migration-next');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }

  Future<ServerMigrationResult> _run() async {
    await configuration.parent.create(recursive: true);
    final path = configuration.absolute.path;
    if (!_activePaths.add(path)) {
      throw StateError('Configuration upgrade already running');
    }
    RandomAccessFile? lease;
    try {
      lease = await File('$path.migration-v4.lock').open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      return await _runLocked();
    } finally {
      await lease?.close();
      _activePaths.remove(path);
    }
  }

  Future<ServerMigrationResult> _runLocked() async {
    Map<String, dynamic> state;
    if (await journal.exists()) {
      try {
        state = Map<String, dynamic>.from(
          jsonDecode(await journal.readAsString()) as Map,
        );
        if (state['version'] != 1 ||
            !const ['prepared', 'complete'].contains(state['stage']) ||
            state['sources'] is! List ||
            state['target'] is! Map ||
            state['originalHash'] is! String ||
            state['targetHash'] is! String ||
            !await backup.exists() ||
            await _digest(await backup.readAsString()) !=
                state['originalHash'] ||
            await _digest(jsonEncode(state['target'])) != state['targetHash']) {
          throw const FormatException('Invalid migration journal');
        }
      } catch (_) {
        throw const FormatException(
          'Configuration upgrade incomplete; original retained',
        );
      }
    } else {
      final original = await configuration.exists()
          ? await configuration.readAsString()
          : jsonEncode({'version': 3, 'servers': []});
      final decoded = jsonDecode(original) as Map;
      final snapshot = await FileServerListStore(configuration).load();
      if (decoded['version'] == 4) {
        return ServerMigrationResult(
          snapshot: snapshot,
          sources: const ServerSourceMapping([]),
          unavailableProtectionIds: const [],
        );
      }
      // Preserve original bytes before any external side effects. An orphaned
      // backup from an interrupted prepare must match, not be overwritten.
      if (await backup.exists()) {
        if (await backup.readAsString() != original) {
          throw const FormatException('Original migration backup differs');
        }
      } else {
        await _replace(backup, original);
      }
      final ordered = [
        ...snapshot.servers.where((s) => s.region == AccessRegion.ordinary),
        ...snapshot.servers.where((s) => s.region == AccessRegion.private),
      ];
      final sources = <Map<String, dynamic>>[];
      final targetServers = <Map<String, dynamic>>[];
      for (final server in ordered) {
        final credential = await credentials.read(
          server.effectiveCredentialRef,
        );
        if (credential != null &&
            credential.serviceType != server.serviceType) {
          throw const FormatException('Credential provider identity differs');
        }
        sources.add({
          'server': server.id,
          'serviceType': server.serviceType.name,
          'legacyRegion': server.region.name,
          'verifiedServer': server.expectedServerId,
          'user': credential?.userId,
          'cloudAccountId': server.cloudAccountId,
          'homeUserId': server.homeUserId,
          'credentialRef': server.effectiveCredentialRef,
        });
        final active = server.activeLineId;
        if (active == null || !server.lines.any((line) => line.id == active)) {
          throw const FormatException(
            'Missing active line; explicit choice required',
          );
        }
        targetServers.add(
          server
              .copyWith(
                lineSelection: LineSelection.fixed(active),
                protectionRef: server.region == AccessRegion.private
                    ? 'migrated-v4:${server.id}'
                    : server.protectionRef,
              )
              .toConfigurationJson(),
        );
      }
      final target = {
        'version': 4,
        'lastServerId': snapshot.lastServerId,
        'servers': targetServers,
      };
      state = {
        'version': 1,
        'stage': 'prepared',
        'originalHash': await _digest(original),
        'targetHash': await _digest(jsonEncode(target)),
        'target': target,
        'sources': sources,
      };
      await _replace(journal, jsonEncode(state));
      await checkpoint?.call('prepared');
    }

    final mapping = ServerSourceMapping([
      for (final entry in state['sources'] as List)
        Map<String, dynamic>.from(entry as Map),
    ]);
    if (state['stage'] != 'complete') {
      final current = await configuration.exists()
          ? await configuration.readAsString()
          : await backup.readAsString();
      final isOriginal = await _digest(current) == state['originalHash'];
      final isTarget =
          await _digest(jsonEncode(jsonDecode(current))) == state['targetHash'];
      if (!isOriginal && !isTarget) {
        throw const FormatException(
          'Configuration changed during upgrade; original retained',
        );
      }
      ServerPasswordVerifier? legacy;
      try {
        final value = await readLegacyVerifier();
        if (value != null) legacy = ServerPasswordVerifier.fromJson(value);
      } catch (_) {
        /* Missing/damaged protection is an explicit locked state. */
      }
      for (final raw in (state['target'] as Map)['servers'] as List) {
        final ref = raw['protectionRef'] as String?;
        if (ref == null) continue;
        final existing = await accessStore.read(ref);
        if (existing == null) {
          await accessStore.write(
            ref,
            legacy == null
                ? const ServerAccessRecord.unavailable()
                : ServerAccessRecord.protected(legacy),
          );
        }
        final persisted = await accessStore.read(ref);
        if (persisted == null || !persisted.enabled) {
          throw const FormatException('Protection migration incomplete');
        }
      }
      await checkpoint?.call('protection-ready');
      final beforePublish = await configuration.exists()
          ? await configuration.readAsString()
          : await backup.readAsString();
      if (await _digest(beforePublish) != await _digest(current)) {
        throw const FormatException(
          'Configuration changed during upgrade; original retained',
        );
      }
      if (!isTarget) await _replace(configuration, jsonEncode(state['target']));
      await checkpoint?.call('configuration-published');
      // Re-read through the actual v4 reader before publishing completion.
      await FileServerListStore(configuration).load();
      state['stage'] = 'complete';
      await _replace(journal, jsonEncode(state));
    }
    if (!await configuration.exists() ||
        (jsonDecode(await configuration.readAsString()) as Map)['version'] !=
            4) {
      throw const FormatException(
        'Completed configuration missing; original retained',
      );
    }
    final snapshot = await FileServerListStore(configuration).load();
    final unavailable = <String>[];
    for (final server in snapshot.servers) {
      if (server.protectionRef == null) continue;
      try {
        final record = await accessStore.read(server.protectionRef!);
        if (record == null || record.unavailable) unavailable.add(server.id);
      } catch (_) {
        unavailable.add(server.id);
      }
    }
    return ServerMigrationResult(
      snapshot: snapshot,
      sources: mapping,
      unavailableProtectionIds: List.unmodifiable(unavailable),
    );
  }
}
