import 'dart:convert';
import 'dart:io';

class WebDavConfig {
  const WebDavConfig({
    this.address = '',
    this.username = '',
    this.password = '',
    this.directory = '',
  });

  final String address;
  final String username;
  final String password;
  final String directory;

  bool get isEmpty =>
      address.isEmpty &&
      username.isEmpty &&
      password.isEmpty &&
      directory.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'address': address,
    'username': username,
    'password': password,
    'directory': directory,
  };

  factory WebDavConfig.fromJson(Map<String, dynamic> json) => WebDavConfig(
    address: json['address'] as String? ?? '',
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    directory: json['directory'] as String? ?? '',
  );
}

class WebDavConfigStore {
  WebDavConfigStore(this.file);

  final File file;

  Future<WebDavConfig> load() async {
    if (!await file.exists()) return const WebDavConfig();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Invalid WebDAV configuration');
      }
      return WebDavConfig.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      // Corruption fails closed; never silently reset a configured server.
      throw const FormatException(
        'Invalid WebDAV configuration; original retained',
      );
    }
  }

  Future<void> save(WebDavConfig config) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(config.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
