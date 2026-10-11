import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../media_server/capabilities.dart';
import '../media_server/authentication.dart';

enum AccessRegion { ordinary, private }

class ServerLine {
  const ServerLine({
    required this.id,
    required this.address,
    this.nickname,
    this.checkStatus = 'unknown',
    this.checkedAt,
  });

  final String checkStatus;
  final DateTime? checkedAt;

  final String? nickname;

  final String id;
  final String address;

  String get hostLabel {
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) {
      return address;
    }
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'address': address,
    if (nickname != null) 'nickname': nickname,
    'checkStatus': checkStatus,
    'checkedAt': checkedAt?.toIso8601String(),
  };

  factory ServerLine.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final address =
        json['address']?.toString() ?? json['baseUrl']?.toString() ?? '';
    return ServerLine(
      id: id.isNotEmpty ? id : 'line-$address',
      address: address,
      nickname: json['nickname']?.toString(),
      checkStatus: json['checkStatus']?.toString() ?? 'unknown',
      checkedAt: DateTime.tryParse(json['checkedAt']?.toString() ?? ''),
    );
  }

  ServerLine copyWith({
    String? id,
    String? address,
    String? nickname,
    String? checkStatus,
    DateTime? checkedAt,
  }) {
    return ServerLine(
      id: id ?? this.id,
      address: address ?? this.address,
      nickname: nickname ?? this.nickname,
      checkStatus:
          checkStatus ??
          (address != null && address != this.address
              ? 'unknown'
              : this.checkStatus),
      checkedAt:
          checkedAt ??
          (address != null && address != this.address ? null : this.checkedAt),
    );
  }
}

class SavedServer {
  const SavedServer({
    required this.id,
    required this.name,
    required this.username,
    required this.lines,
    this.activeLineId,
    this.userAgent,
    this.nickname,
    this.region = AccessRegion.ordinary,
    this.participates = true,
    this.libraryIds = const [],
    this.scopeKnown = false,
    this.verifiedServerId,
    this.serviceType = MediaServerType.emby,
    this.authorizationMethod = AuthorizationMethod.password,
    this.cloudCredentialRef,
    this.cloudAccountId,
    this.homeUserId,
    this.resourceCredentialRef,
    this.checkedAt,
    this.checkStatus = 'unknown',
  });

  final MediaServerType serviceType;
  final AuthorizationMethod authorizationMethod;
  final String? cloudCredentialRef;
  final String? cloudAccountId;
  final String? homeUserId;
  final String? resourceCredentialRef;
  final AccessRegion region;
  final bool participates;

  /// An unknown legacy scope is empty until explicitly discovered/selected.
  final List<String> libraryIds;
  final bool scopeKnown;
  final String? verifiedServerId;
  final DateTime? checkedAt;
  final String checkStatus;

  final String id;
  final String name;
  final String? nickname;
  String get displayName =>
      nickname?.trim().isNotEmpty == true ? nickname!.trim() : name;
  final String username;
  final List<ServerLine> lines;
  final String? activeLineId;

  /// Server-level HTTP User-Agent; every line of this server shares it.
  final String? userAgent;

  String? get normalizedUserAgent {
    final value = userAgent?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  ServerLine? get activeLine {
    if (lines.isEmpty) {
      return null;
    }
    if (activeLineId != null && activeLineId!.isNotEmpty) {
      for (final line in lines) {
        if (line.id == activeLineId) {
          return line;
        }
      }
    }
    return lines.first;
  }

  String get baseUrl => activeLine?.address ?? '';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (nickname?.trim().isNotEmpty == true) 'nickname': nickname!.trim(),
    'username': username,
    'serviceType': serviceType.name,
    'authorizationMethod': authorizationMethod.name,
    'cloudCredentialRef': cloudCredentialRef,
    'cloudAccountId': cloudAccountId,
    'homeUserId': homeUserId,
    'resourceCredentialRef': resourceCredentialRef,
    'region': region.name,
    'participates': participates,
    'libraryIds': libraryIds,
    'scopeKnown': scopeKnown,
    'verifiedServerId': verifiedServerId,
    'checkedAt': checkedAt?.toIso8601String(),
    'checkStatus': checkStatus,
    'activeLineId': activeLineId,
    if (normalizedUserAgent != null) 'userAgent': normalizedUserAgent,
    'lines': lines.map((line) => line.toJson()).toList(),
  };

  factory SavedServer.fromJson(Map<String, dynamic> json) {
    final lines = <ServerLine>[];
    final rawLines = json['lines'];
    if (rawLines is List) {
      for (final item in rawLines) {
        if (item is Map) {
          final line = ServerLine.fromJson(Map<String, dynamic>.from(item));
          if (line.address.isNotEmpty) {
            lines.add(line);
          }
        }
      }
    }
    if (lines.isEmpty) {
      final baseUrl = json['baseUrl']?.toString() ?? '';
      if (baseUrl.isNotEmpty) {
        lines.add(ServerLine(id: 'default', address: baseUrl));
      }
    }
    final activeLineId = json['activeLineId']?.toString();
    final resolvedActiveLineId =
        (activeLineId != null && activeLineId.isNotEmpty)
        ? activeLineId
        : (lines.isNotEmpty ? lines.first.id : null);
    return SavedServer(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      nickname: json['nickname']?.toString(),
      username: json['username']?.toString() ?? '',
      serviceType: MediaServerType.values.byName(
        json['serviceType'] as String? ?? 'emby',
      ),
      authorizationMethod: AuthorizationMethod.values.byName(
        json['authorizationMethod'] as String? ?? 'password',
      ),
      cloudCredentialRef: json['cloudCredentialRef'] as String?,
      cloudAccountId: json['cloudAccountId'] as String?,
      homeUserId: json['homeUserId'] as String?,
      resourceCredentialRef: json['resourceCredentialRef'] as String?,
      lines: List<ServerLine>.unmodifiable(lines),
      activeLineId: resolvedActiveLineId,
      userAgent: _resolveUserAgent(json, resolvedActiveLineId),
      region: json['region'] == 'private'
          ? AccessRegion.private
          : AccessRegion.ordinary,
      participates: json['participates'] != false,
      libraryIds: List<String>.unmodifiable(
        (json['libraryIds'] as List? ?? []).whereType<String>(),
      ),
      scopeKnown: json['scopeKnown'] == true,
      verifiedServerId: json['verifiedServerId']?.toString(),
      checkedAt: DateTime.tryParse(json['checkedAt']?.toString() ?? ''),
      checkStatus: json['checkStatus']?.toString() ?? 'unknown',
    );
  }

  /// Old JSON stored User-Agent per line; migrate the active line's value to
  /// the server level and leave lines carrying only addresses.
  static String? _resolveUserAgent(
    Map<String, dynamic> json,
    String? activeLineId,
  ) {
    final serverLevel = json['userAgent']?.toString().trim();
    if (serverLevel != null && serverLevel.isNotEmpty) {
      return serverLevel;
    }
    final rawLines = json['lines'];
    if (rawLines is! List) {
      return null;
    }
    String? first;
    for (var i = 0; i < rawLines.length; i++) {
      final item = rawLines[i];
      if (item is! Map) {
        continue;
      }
      final value = item['userAgent']?.toString().trim();
      if (value == null || value.isEmpty) {
        continue;
      }
      first ??= value;
      final id = item['id']?.toString();
      final address =
          item['address']?.toString() ?? item['baseUrl']?.toString() ?? '';
      final lineId = (id != null && id.isNotEmpty) ? id : 'line-$address';
      if (lineId == activeLineId) {
        return value;
      }
    }
    return first;
  }

  SavedServer copyWith({
    String? id,
    String? name,
    String? username,
    List<ServerLine>? lines,
    String? activeLineId,
    String? userAgent,
    String? nickname,
    AccessRegion? region,
    bool? participates,
    List<String>? libraryIds,
    bool? scopeKnown,
    String? verifiedServerId,
    MediaServerType? serviceType,
    AuthorizationMethod? authorizationMethod,
    String? cloudCredentialRef,
    String? cloudAccountId,
    String? homeUserId,
    String? resourceCredentialRef,
    DateTime? checkedAt,
    String? checkStatus,
  }) {
    return SavedServer(
      id: id ?? this.id,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      username: username ?? this.username,
      lines: List<ServerLine>.unmodifiable(lines ?? this.lines),
      activeLineId: activeLineId ?? this.activeLineId,
      userAgent: userAgent ?? this.userAgent,
      region: region ?? this.region,
      participates: participates ?? this.participates,
      libraryIds: List<String>.unmodifiable(libraryIds ?? this.libraryIds),
      scopeKnown: scopeKnown ?? this.scopeKnown,
      verifiedServerId: verifiedServerId ?? this.verifiedServerId,
      serviceType: serviceType ?? this.serviceType,
      authorizationMethod: authorizationMethod ?? this.authorizationMethod,
      cloudCredentialRef: cloudCredentialRef ?? this.cloudCredentialRef,
      cloudAccountId: cloudAccountId ?? this.cloudAccountId,
      homeUserId: homeUserId ?? this.homeUserId,
      resourceCredentialRef:
          resourceCredentialRef ?? this.resourceCredentialRef,
      checkedAt: checkedAt ?? this.checkedAt,
      checkStatus: checkStatus ?? this.checkStatus,
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
      if (decoded is! Map ||
          decoded['servers'] is! List ||
          (decoded['version'] != null &&
              !const [1, 2, 3].contains(decoded['version']))) {
        throw const FormatException('Invalid server configuration');
      }
      final servers = <SavedServer>[];
      final ids = <String>{};
      for (final item in decoded['servers'] as List) {
        if (item is! Map) throw const FormatException('Invalid server record');
        final server = SavedServer.fromJson(Map<String, dynamic>.from(item));
        if (server.id.isEmpty || server.lines.isEmpty || !ids.add(server.id)) {
          throw const FormatException('Invalid or duplicate source identity');
        }
        servers.add(server);
      }
      return ServerListSnapshot(
        servers: servers,
        lastServerId: decoded['lastServerId'] as String?,
      );
    } on FormatException {
      throw const FormatException(
        'Invalid server configuration; original retained',
      );
    } on Object {
      // Do not include raw JSON (possibly private names) in the error.
      throw const FormatException('Unable to read server configuration');
    }
  }

  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    // Validate the existing document before replacing it; corruption is never empty.
    if (await file.exists()) await load();
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'version': 3,
      'lastServerId': snapshot.lastServerId,
      'servers': snapshot.servers.map((server) => server.toJson()).toList(),
    };
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
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

String generateLineId() {
  final random = Random.secure();
  final bytes = List<int>.generate(8, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
