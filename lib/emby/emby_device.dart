import 'package:rillight/media_server/device.dart';

String embyAuthorizationHeader(
  ClientDeviceInfo device, {
  String? userId,
  String? token,
  String? clientName,
  String? clientVersion,
}) {
  final parts = <String>[
    'MediaBrowser Client="${_headerValue(clientName ?? device.clientName)}"',
    'Device="${_headerValue(device.deviceName)}"',
    'DeviceId="${_headerValue(device.deviceId)}"',
    'Version="${_headerValue(clientVersion ?? device.version)}"',
  ];
  if (userId != null && userId.isNotEmpty) {
    parts.add('UserId="${_headerValue(userId)}"');
  }
  if (token != null && token.isNotEmpty) {
    parts.add('Token="${_headerValue(token)}"');
  }
  return parts.join(', ');
}

String _headerValue(String value) {
  final escaped = value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  final ascii = StringBuffer();
  for (final unit in escaped.codeUnits) {
    if (unit >= 0x20 && unit <= 0x7E) {
      ascii.writeCharCode(unit);
    }
  }
  final trimmed = ascii.toString().trim();
  return trimmed.isEmpty ? 'Rillight' : trimmed;
}
