import 'package:punycoder/punycoder.dart';
import 'package:rillight/media_server/errors.dart';

/// Remove session token values without re-encoding a signed media query.
/// Keep each remaining component's order, escaping and duplicate keys intact.
Uri withoutCredentialValues(Uri uri, Set<String> tokens) {
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

Uri normalizeServerAddress(String input) {
  var trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const MediaServerException(MediaServerFailureKind.invalidAddress);
  }
  if (!trimmed.contains('://')) {
    trimmed = 'http://$trimmed';
  }

  try {
    final parsed = Uri.parse(trimmed);
    if (parsed.host.isEmpty ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const MediaServerException(MediaServerFailureKind.invalidAddress);
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
    throw const MediaServerException(MediaServerFailureKind.invalidAddress);
  }
}

Uri joinServerPath(Uri baseUrl, String path) {
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
