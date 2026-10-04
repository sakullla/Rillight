import '../../player/player_settings.dart';
import '../identity/media_identity.dart';

Map<String, dynamic> encodeSource(SourceReference source) => {
  'region': source.account.region.name,
  'server': source.account.configuredServerId,
  'verifiedServer': source.account.verifiedServerId,
  'user': source.account.userId,
  'item': source.itemId,
  'version': source.mediaSourceId,
};

SourceReference decodeSource(Map<String, dynamic> json) => SourceReference(
  account: SourceAccount(
    region: AccessRegion.values.byName(json['region'] as String),
    configuredServerId: json['server'] as String,
    verifiedServerId: json['verifiedServer'] as String,
    userId: json['user'] as String,
  ),
  itemId: json['item'] as String,
  mediaSourceId: json['version'] as String?,
);

/// Actual observed timeline, not an assumption that matching works share cuts.
class WatchTimeline {
  const WatchTimeline({
    this.durationTicks,
    this.edition,
    this.season,
    this.episode,
  });
  final int? durationTicks;
  final String? edition;
  final int? season;
  final int? episode;
  Map<String, dynamic> toJson() => {
    'duration': durationTicks,
    'edition': edition,
    'season': season,
    'episode': episode,
  };
  factory WatchTimeline.fromJson(Map<String, dynamic> json) => WatchTimeline(
    durationTicks: json['duration'] as int?,
    edition: json['edition'] as String?,
    season: json['season'] as int?,
    episode: json['episode'] as int?,
  );
}

enum RemoteSyncStatus { pending, succeeded, failed }

class WatchRecord {
  const WatchRecord({
    required this.source,
    required this.work,
    required this.libraryId,
    required this.sessionId,
    required this.eventSequence,
    required this.localOrder,
    required this.observedAt,
    required this.positionTicks,
    required this.played,
    required this.timeline,
    this.remoteStatus = RemoteSyncStatus.pending,
  });
  final SourceReference source;

  /// A source-specific movie/series anchor; never a mutable merged group key.
  final SourceReference work;
  final String libraryId;
  final String sessionId;
  final int eventSequence;
  final int localOrder;
  final DateTime observedAt;
  final int positionTicks;
  final bool played;
  final WatchTimeline timeline;
  final RemoteSyncStatus remoteStatus;
  WatchRecord withRemoteStatus(RemoteSyncStatus status) => WatchRecord(
    source: source,
    work: work,
    libraryId: libraryId,
    sessionId: sessionId,
    eventSequence: eventSequence,
    localOrder: localOrder,
    observedAt: observedAt,
    positionTicks: positionTicks,
    played: played,
    timeline: timeline,
    remoteStatus: status,
  );
  Map<String, dynamic> toJson() => {
    'source': encodeSource(source),
    'work': encodeSource(work),
    'library': libraryId,
    'session': sessionId,
    'event': eventSequence,
    'order': localOrder,
    'at': observedAt.toUtc().toIso8601String(),
    'position': positionTicks,
    'played': played,
    'timeline': timeline.toJson(),
    'remote': remoteStatus.name,
  };
  factory WatchRecord.fromJson(Map<String, dynamic> json) => WatchRecord(
    source: decodeSource(Map<String, dynamic>.from(json['source'] as Map)),
    work: decodeSource(Map<String, dynamic>.from(json['work'] as Map)),
    libraryId: json['library'] as String,
    sessionId: json['session'] as String,
    eventSequence: json['event'] as int,
    localOrder: json['order'] as int,
    observedAt: DateTime.parse(json['at'] as String),
    positionTicks: json['position'] as int,
    played: json['played'] as bool,
    timeline: WatchTimeline.fromJson(
      Map<String, dynamic>.from(json['timeline'] as Map),
    ),
    remoteStatus: RemoteSyncStatus.values.byName(json['remote'] as String),
  );
}

class SourcePreference {
  const SourcePreference({
    required this.owner,
    required this.target,
    required this.libraryId,
    this.lineId,
    this.settings = const PlayerSeriesPreference(),
  });
  final SourceReference owner;
  final SourceReference target;
  final String libraryId;
  final String? lineId;
  final PlayerSeriesPreference settings;
  Map<String, dynamic> toJson() => {
    'owner': encodeSource(owner),
    'target': encodeSource(target),
    'library': libraryId,
    'line': lineId,
    'settings': settings.toJson(),
  };
  factory SourcePreference.fromJson(Map<String, dynamic> json) =>
      SourcePreference(
        owner: decodeSource(Map<String, dynamic>.from(json['owner'] as Map)),
        target: decodeSource(Map<String, dynamic>.from(json['target'] as Map)),
        libraryId: json['library'] as String,
        lineId: json['line'] as String?,
        settings: PlayerSeriesPreference.fromJson(
          Map<String, dynamic>.from(json['settings'] as Map),
        ),
      );
}

class PreferenceCandidate {
  const PreferenceCandidate(this.source, this.libraryId, {this.versionName});
  final SourceReference source;
  final String libraryId;
  final String? versionName;
}

enum PreferenceFailure {
  notConfigured,
  regionLocked,
  wrongRegion,
  serverRemoved,
  accountUnavailable,
  notParticipating,
  unknownScope,
  libraryExcluded,
  targetMissing,
  lineRemoved,
  versionUncertain,
  ambiguousLegacy,
}

class PreferenceResolution {
  const PreferenceResolution({
    this.preference,
    this.selected,
    this.failure,
    required this.allowedCandidates,
  });
  final SourcePreference? preference;
  final PreferenceCandidate? selected;
  final PreferenceFailure? failure;
  final List<PreferenceCandidate> allowedCandidates;
}

class RemoteWatch {
  const RemoteWatch({
    required this.source,
    required this.work,
    required this.libraryId,
    required this.positionTicks,
    this.playedAt,
    this.timeTrusted = false,
  });
  final SourceReference source;
  final SourceReference work;
  final String libraryId;
  final int positionTicks;
  final DateTime? playedAt;
  final bool timeTrusted;
}

enum ResumeKind { empty, local, remote, conflict }

class ResumeChoice {
  const ResumeChoice(
    this.kind, {
    this.local,
    this.remote,
    this.conflicts = const [],
  });
  final ResumeKind kind;
  final WatchRecord? local;
  final RemoteWatch? remote;
  final List<RemoteWatch> conflicts;
}
