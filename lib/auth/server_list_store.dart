import 'dart:convert';
import 'dart:io';
import 'dart:math';

class SavedServer {
  const SavedServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String username;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'username': username,
  };

  factory SavedServer.fromJson(Map<String, dynamic> json) {
    return SavedServer(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
    );
  }
}

class ServerListSnapshot {
  const ServerListSnapshot({required this.servers, this.lastServerId});

  final List<SavedServer> servers;
  final String? lastServerId;
}

abstract class ServerListStore {
  Future<ServerListSnapshot> load();

  Future<void> save(ServerListSnapshot snapshot);
}

class MemoryServerListStore implements ServerListStore {
  MemoryServerListStore([ServerListSnapshot? seed])
    : _snapshot = seed ?? const ServerListSnapshot(servers: []);

  ServerListSnapshot _snapshot;

  @override
  Future<ServerListSnapshot> load() async => _snapshot;

  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

class FileServerListStore implements ServerListStore {
  FileServerListStore(this.file);

  final File file;

  @override
  Future<ServerListSnapshot> load() async {
    if (!await file.exists()) {
      return const ServerListSnapshot(servers: []);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return const ServerListSnapshot(servers: []);
      }
      final map = Map<String, dynamic>.from(decoded);
      final rawServers = map['servers'];
      final servers = <SavedServer>[];
      if (rawServers is List) {
        for (final item in rawServers) {
          if (item is Map) {
            final server = SavedServer.fromJson(
              Map<String, dynamic>.from(item),
            );
            if (server.id.isNotEmpty && server.baseUrl.isNotEmpty) {
              servers.add(server);
            }
          }
        }
      }
      return ServerListSnapshot(
        servers: servers,
        lastServerId: map['lastServerId']?.toString(),
      );
    } on FormatException {
      return const ServerListSnapshot(servers: []);
    }
  }

  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'lastServerId': snapshot.lastServerId,
      'servers': snapshot.servers.map((server) => server.toJson()).toList(),
    };
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }
}

Future<String> loadOrCreateDeviceId(File file) async {
  if (await file.exists()) {
    final existing = (await file.readAsString()).trim();
    if (existing.isNotEmpty) {
      return existing;
    }
  }
  final id = generateDeviceId();
  await file.parent.create(recursive: true);
  await file.writeAsString(id);
  return id;
}

String generateDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
