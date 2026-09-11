class EmbyDeviceInfo {
  const EmbyDeviceInfo({
    required this.clientName,
    required this.deviceName,
    required this.deviceId,
    required this.version,
  });

  final String clientName;
  final String deviceName;
  final String deviceId;
  final String version;

  String get defaultUserAgent => 'Rillight/$version';

  String authorizationHeader({String? userId, String? token}) {
    final parts = <String>[
      'MediaBrowser Client="${_headerValue(clientName)}"',
      'Device="${_headerValue(deviceName)}"',
      'DeviceId="${_headerValue(deviceId)}"',
      'Version="${_headerValue(version)}"',
    ];
    if (userId != null && userId.isNotEmpty) {
      parts.add('UserId="${_headerValue(userId)}"');
    }
    if (token != null && token.isNotEmpty) {
      parts.add('Token="${_headerValue(token)}"');
    }
    return parts.join(', ');
  }
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

String? normalizeUserAgent(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

String resolveUserAgent(String? custom, EmbyDeviceInfo device) {
  return normalizeUserAgent(custom) ?? device.defaultUserAgent;
}
