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

  String authorizationHeader({String? userId, String? token}) {
    final parts = <String>[
      'MediaBrowser Client="${_escape(clientName)}"',
      'Device="${_escape(deviceName)}"',
      'DeviceId="${_escape(deviceId)}"',
      'Version="${_escape(version)}"',
    ];
    if (userId != null && userId.isNotEmpty) {
      parts.add('UserId="${_escape(userId)}"');
    }
    if (token != null && token.isNotEmpty) {
      parts.add('Token="${_escape(token)}"');
    }
    return parts.join(', ');
  }
}

String _escape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
