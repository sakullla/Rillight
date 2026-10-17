import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pub_semver/pub_semver.dart';

import '../product.dart';

class AppRelease {
  AppRelease({
    required this.version,
    required this.url,
    this.notes = '',
    String? tag,
    this.id,
    List<ReleaseAsset> assets = const [],
  }) : tag = tag ?? url.pathSegments.last,
       assets = List.unmodifiable(assets);
  final Version version;
  final Uri url;
  final String notes;
  final String tag;
  final int? id;
  final List<ReleaseAsset> assets;

  // pub_semver orders build metadata as well; SemVer precedence must not.
  bool isNewerThan(String current) =>
      _withoutBuild(version) > _withoutBuild(Version.parse(current));

  static Version _withoutBuild(Version value) =>
      Version.parse(value.toString().split('+').first);

  bool get isOfficial =>
      _stableTag.hasMatch(tag) &&
      !version.isPreRelease &&
      Version.parse(tag.startsWith('v') ? tag.substring(1) : tag) == version &&
      url == Uri.https('github.com', '/sakullla/Rillight/releases/tag/$tag');

  bool ownsAsset(ReleaseAsset asset) =>
      isOfficial && assets.contains(asset) && asset.isOfficialFor(tag);

  static final _stableTag = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$',
  );

  factory AppRelease.fromJson(Object? data) {
    if (data is! Map || data['draft'] != false || data['prerelease'] != false) {
      throw const FormatException('No stable release');
    }
    final tag = data['tag_name'];
    if (tag is! String || !_stableTag.hasMatch(tag)) {
      throw const FormatException('Invalid stable release tag');
    }
    final version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    if (version.isPreRelease) throw const FormatException('Prerelease');
    // Construct the destination from the fixed repository and verified tag;
    // API response links cannot redirect the user to an unrelated site.
    final url = Uri.https('github.com', '/sakullla/Rillight/releases/tag/$tag');
    return AppRelease(
      version: version,
      url: url,
      notes: data['body'] is String ? data['body'] as String : '',
      tag: tag,
      id: data['id'] is int ? data['id'] as int : null,
      assets: switch (data['assets']) {
        null =>
          const [], // Metadata-only responses remain backwards compatible.
        List items => items.map(ReleaseAsset.fromJson).toList(),
        _ => throw const FormatException('Invalid assets'),
      },
    );
  }
}

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.size});
  final String name;
  final Uri url;
  final int? size;

  factory ReleaseAsset.fromJson(Object? data) {
    if (data is! Map ||
        data['name'] is! String ||
        data['browser_download_url'] is! String ||
        (data['size'] != null &&
            (data['size'] is! int || (data['size'] as int) < 0))) {
      throw const FormatException('Invalid release asset');
    }
    return ReleaseAsset(
      name: data['name'] as String,
      url: Uri.parse(data['browser_download_url'] as String),
      size: data['size'] as int?,
    );
  }

  bool isOfficialFor(String tag) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(name) &&
      !name.contains('..') &&
      url ==
          Uri.https(
            'github.com',
            '/sakullla/Rillight/releases/download/$tag/$name',
          );
}

/// Uses its own unauthenticated client, never media-server headers or tokens.
class UpdateService {
  UpdateService({Dio? dio}) : _dio = dio ?? Dio(), _ownsDio = dio == null;
  final Dio _dio;
  final bool _ownsDio;
  Future<AppRelease>? _pending;
  CancelToken? _cancelToken;
  bool _disposed = false;

  Future<AppRelease> check() => _pending ??= _check().whenComplete(() {
    _pending = null;
  });

  Future<AppRelease> _check() async {
    if (_disposed) throw StateError('UpdateService is disposed');
    final token = _cancelToken = CancelToken();
    final response = await _dio
        .get<Object?>(
          'https://api.github.com/repos/sakullla/Rillight/releases/latest',
          options: Options(
            followRedirects: false,
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': '$kHttpClientName/$kAppVersion',
            },
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
          cancelToken: token,
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            token.cancel();
            throw TimeoutException('Release request timed out');
          },
        );
    return AppRelease.fromJson(response.data);
  }

  void dispose() {
    _disposed = true;
    _cancelToken?.cancel();
    if (_ownsDio) _dio.close(force: true);
  }
}
