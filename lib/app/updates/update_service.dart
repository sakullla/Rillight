import 'package:dio/dio.dart';
import 'package:pub_semver/pub_semver.dart';

import '../product.dart';

class AppRelease {
  const AppRelease({required this.version, required this.url, this.notes = ''});
  final Version version;
  final Uri url;
  final String notes;

  bool isNewerThan(String current) => version > Version.parse(current);

  factory AppRelease.fromJson(Object? data) {
    if (data is! Map || data['draft'] != false || data['prerelease'] != false) {
      throw const FormatException('No stable release');
    }
    final tag = data['tag_name'];
    if (tag is! String) throw const FormatException('Missing release tag');
    final version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    if (version.isPreRelease) throw const FormatException('Prerelease');
    // Construct the destination from the fixed repository and verified tag;
    // API response links cannot redirect the user to an unrelated site.
    final url = Uri.https('github.com', '/sakullla/Rillight/releases/tag/$tag');
    return AppRelease(
      version: version,
      url: url,
      notes: data['body'] is String ? data['body'] as String : '',
    );
  }
}

/// Uses its own unauthenticated client, never media-server headers or tokens.
class UpdateService {
  UpdateService({Dio? dio}) : _dio = dio ?? Dio(), _ownsDio = dio == null;
  final Dio _dio;
  final bool _ownsDio;

  Future<AppRelease> check() async {
    final response = await _dio
        .get<Object?>(
          'https://api.github.com/repos/sakullla/Rillight/releases/latest',
          options: Options(
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': '$kHttpClientName/$kAppVersion',
            },
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
        )
        .timeout(const Duration(seconds: 15));
    return AppRelease.fromJson(response.data);
  }

  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }
}
