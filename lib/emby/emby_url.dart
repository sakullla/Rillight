import 'package:rillight/emby/emby_errors.dart';

Uri normalizeEmbyBaseUrl(String input) {
  var trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const EmbyException(EmbyFailureKind.invalidAddress);
  }
  if (!trimmed.contains('://')) {
    trimmed = 'http://$trimmed';
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.host.isEmpty) {
    throw const EmbyException(EmbyFailureKind.invalidAddress);
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw const EmbyException(EmbyFailureKind.invalidAddress);
  }

  var path = parsed.path;
  if (path == '/') {
    path = '';
  } else if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  );
}

Uri joinEmbyPath(Uri baseUrl, String path) {
  final suffix = path.startsWith('/') ? path : '/$path';
  var basePath = baseUrl.path;
  if (basePath.endsWith('/')) {
    basePath = basePath.substring(0, basePath.length - 1);
  }
  return Uri(
    scheme: baseUrl.scheme,
    userInfo: baseUrl.userInfo,
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    path: '$basePath$suffix',
  );
}

/// REST resources use /emby/{apipath}, including server-relative media URLs.
/// Keep the user's reverse-proxy mount and accept an already qualified path.
/// https://dev.emby.media/doc/restapi/index.html#accessing-the-api
Uri joinEmbyApiPath(Uri baseUrl, String path) {
  final basePath = baseUrl.path.replaceFirst(RegExp(r'/+$'), '');
  final apiPath = basePath.toLowerCase().endsWith('/emby')
      ? basePath
      : '$basePath/emby';
  var resource = path.startsWith('/') ? path : '/$path';
  if (resource == apiPath || resource.startsWith('$apiPath/')) {
    return joinEmbyPath(baseUrl.replace(path: ''), resource);
  }
  if (resource == '/emby' || resource.startsWith('/emby/')) {
    resource = resource.substring('/emby'.length);
  }
  return joinEmbyPath(baseUrl.replace(path: apiPath), resource);
}
