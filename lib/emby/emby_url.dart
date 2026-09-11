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
