import 'package:rillight/emby/emby_client.dart';
import 'capabilities.dart';
import 'device.dart';
import 'media_server_client.dart';

typedef MediaServerBuilder =
    MediaServerClient Function(ClientDeviceInfo device);

/// Application composition point. Unknown providers are never treated as Emby.
class MediaServerProviders {
  static final Map<MediaServerType, MediaServerBuilder> _builders = {
    MediaServerType.emby: (device) => EmbyClient(device: device),
  };

  static void register(MediaServerType type, MediaServerBuilder builder) {
    _builders[type] = builder;
  }

  static MediaServerClient create(
    MediaServerType type,
    ClientDeviceInfo device,
  ) {
    final builder = _builders[type];
    if (builder == null) {
      throw StateError('Provider is not registered: ${type.name}');
    }
    final client = builder(device);
    if (client.serviceType != type) {
      throw StateError('Provider identity mismatch');
    }
    return client;
  }
}
