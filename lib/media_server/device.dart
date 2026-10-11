class ClientDeviceInfo {
  const ClientDeviceInfo({
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
}

String? normalizeUserAgent(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

String resolveUserAgent(String? custom, ClientDeviceInfo device) {
  return normalizeUserAgent(custom) ?? device.defaultUserAgent;
}
