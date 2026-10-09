import 'package:punycoder/punycoder.dart';
import 'package:rillight/emby/emby_errors.dart';

/// Remove session token values without re-encoding a signed media query.
/// Keep each remaining component's order, escaping and duplicate keys intact.
Uri withoutEmbyTokenValues(Uri uri, Set<String> tokens) {
  if (!uri.hasQuery || tokens.isEmpty) return uri;
  final parts = uri.query.split('&');
  final kept = parts.where((part) {
    final equals = part.indexOf('=');
    final value = equals < 0 ? '' : part.substring(equals + 1);
    return !tokens.contains(Uri.decodeQueryComponent(value));
  }).toList();
  if (kept.length == parts.length) return uri;
  return uri.replace(query: kept.join('&'));
}

Uri normalizeEmbyBaseUrl(String input) {
  var trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const EmbyException(EmbyFailureKind.invalidAddress);
  }
  if (!trimmed.contains('://')) {
    trimmed = 'http://$trimmed';
  }

  try {
    final parsed = Uri.parse(trimmed);
    if (parsed.host.isEmpty ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const EmbyException(EmbyFailureKind.invalidAddress);
    }

    // Uri percent-encodes Unicode hosts, but the HTTP client needs DNS ASCII
    // labels. Decode only the host, preserving escaped paths and IPv6 zones.
    final host = parsed.host;
    final asciiHost = !host.contains(':') && host.contains('%')
        ? domainToAscii(Uri.decodeComponent(host))
        : host;

    var path = parsed.path;
    if (path == '/') {
      path = '';
    } else if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    return Uri(
      scheme: parsed.scheme,
      host: asciiHost,
      port: parsed.hasPort ? parsed.port : null,
      path: path,
    );
  } on FormatException {
    // Do not surface parser diagnostics containing the user's server address.
    throw const EmbyException(EmbyFailureKind.invalidAddress);
  }
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
