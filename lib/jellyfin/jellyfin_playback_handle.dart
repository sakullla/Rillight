part of 'jellyfin_client.dart';

/// Opaque persisted business handle. Contains no authentication secrets.
/// HTTP boundaries always unpack it; the server never sees this envelope.
class _PlaybackHandle {
  const _PlaybackHandle(this.rawId, this.deviceId);
  final String rawId, deviceId;
  String encode() =>
      'jf-play-v1:${base64Url.encode(utf8.encode(jsonEncode({'session': rawId, 'device': deviceId})))}';
  static _PlaybackHandle decode(String value) {
    try {
      if (!value.startsWith('jf-play-v1:') || value.length > 4096) {
        throw const FormatException();
      }
      final data = jsonDecode(
        utf8.decode(base64Url.decode(value.substring(11))),
      );
      if (data is! Map ||
          data.length != 2 ||
          data['session'] is! String ||
          data['device'] is! String) {
        throw const FormatException();
      }
      final raw = data['session'] as String, device = data['device'] as String;
      if (raw.isEmpty ||
          raw.length > 512 ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(raw) ||
          !RegExp(r'^rillight-playback-[A-Za-z0-9_-]{32}$').hasMatch(device)) {
        throw const FormatException();
      }
      return _PlaybackHandle(raw, device);
    } catch (_) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidResponse,
        detail: 'Jellyfin 播放会话句柄无效',
      );
    }
  }
}
