import 'package:rillight/media_server/server_address.dart';

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
    return joinServerPath(baseUrl.replace(path: ''), resource);
  }
  if (resource == '/emby' || resource.startsWith('/emby/')) {
    resource = resource.substring('/emby'.length);
  }
  return joinServerPath(baseUrl.replace(path: apiPath), resource);
}
