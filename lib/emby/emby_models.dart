import 'package:rillight/emby/emby_errors.dart';

class PublicServerInfo {
  const PublicServerInfo({
    required this.id,
    required this.serverName,
    this.version,
  });

  final String id;
  final String serverName;
  final String? version;

  factory PublicServerInfo.fromJson(
    Map<String, dynamic> json, {
    String? fallbackName,
  }) {
    final id = json['Id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const EmbyException(EmbyFailureKind.notEmby);
    }
    final name = json['ServerName']?.toString().trim() ?? '';
    return PublicServerInfo(
      id: id,
      serverName: name.isEmpty ? (fallbackName ?? id) : name,
      version: json['Version']?.toString(),
    );
  }
}

class EmbyUser {
  const EmbyUser({required this.id, required this.name});

  final String id;
  final String name;
}

class AuthenticationResult {
  const AuthenticationResult({
    required this.accessToken,
    required this.serverId,
    required this.user,
  });

  final String accessToken;
  final String serverId;
  final EmbyUser user;

  factory AuthenticationResult.fromJson(
    Map<String, dynamic> json, {
    required String fallbackServerId,
  }) {
    final token = json['AccessToken']?.toString() ?? '';
    if (token.isEmpty) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final userJson = json['User'];
    if (userJson is! Map) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final userMap = Map<String, dynamic>.from(userJson);
    final userId = userMap['Id']?.toString() ?? '';
    if (userId.isEmpty) {
      throw const EmbyException(EmbyFailureKind.unknown);
    }
    final serverId = json['ServerId']?.toString().trim();
    return AuthenticationResult(
      accessToken: token,
      serverId: (serverId == null || serverId.isEmpty)
          ? fallbackServerId
          : serverId,
      user: EmbyUser(id: userId, name: userMap['Name']?.toString() ?? ''),
    );
  }
}
