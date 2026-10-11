enum MediaServerType { emby, jellyfin, plex }

enum CapabilityAvailability { available, unsupported, restricted, unknown }

enum ServiceCapability {
  passwordLogin,
  quickConnect,
  browserAuthorization,
  accountResources,
  homeUsers,
  changePassword,
  resume,
  nextUp,
  latest,
  search,
  filters,
  pagination,
  watchedState,
  directPlay,
  directStream,
  transcode,
  preview,
  chapters,
  notifications,
}

/// Unknown includes unverified server state, never a transport-success result.
class CapabilityStatus {
  const CapabilityStatus(this.availability, {required this.reason});
  final CapabilityAvailability availability;
  final String reason;
  bool get isAvailable => availability == CapabilityAvailability.available;
}

class ServiceCapabilities {
  const ServiceCapabilities(this.values);
  final Map<ServiceCapability, CapabilityStatus> values;
  CapabilityStatus operator [](ServiceCapability capability) =>
      values[capability] ??
      const CapabilityStatus(
        CapabilityAvailability.unknown,
        reason: '尚未核实此服务能力',
      );
}
