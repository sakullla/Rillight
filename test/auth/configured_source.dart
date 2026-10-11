import 'package:rillight/auth/auth_controller.dart';

final _observed = Expando<Map<String, String>>();
String configuredSourceId(AuthController auth, String remoteId) {
  final ids = _observed[auth] ??= {};
  for (final source in auth.savedServers) {
    ids[source.verifiedServerId ?? source.id] = source.id;
  }
  return ids[remoteId] ?? remoteId;
}
