import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/playback.dart';

import '../aggregation/history/history_models.dart'
    show encodeSource, decodeSource;
import '../aggregation/identity/media_identity.dart' show SourceReference;

const int kLegacyTicksPerSecond = 10000000;

Duration durationFromTicks(int ticks) {
  if (ticks <= 0) {
    return Duration.zero;
  }
  return Duration(microseconds: ticks ~/ 10);
}

int ticksFromDuration(Duration duration) {
  if (duration <= Duration.zero) {
    return 0;
  }
  return duration.inMicroseconds * 10;
}

/// 由播放进程留下的会话快照构造宿主代发的 Stopped 载荷。
///
/// 进程已终止,只保留会话标识与最后位置;暂停态记为已暂停,
/// 音量/轨道等仅播放进程知道的字段取默认值。
PlaybackReport playbackReportFromSnapshot(PlaybackSessionSnapshot snapshot) {
  return PlaybackReport(
    itemId: snapshot.itemId,
    mediaSourceId: snapshot.mediaSourceId,
    playSessionId: snapshot.playSessionId,
    playMethod: snapshot.playMethod,
    position: snapshot.position,
    isPaused: true,
  );
}

/// 播放进程持续落盘的会话快照:宿主在播放进程被终止或意外退出后,
/// 据此用主进程会话代发 Stopped(见 `PlaybackSessionSnapshotStore`)。
///
/// 字段与 [PlaybackReport] 的会话标识一致;[baseUrl]/[userId]
/// 供宿主校验快照归属,避免串服务器代发。
class PlaybackSessionSnapshot {
  const PlaybackSessionSnapshot({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.position,
    required this.baseUrl,
    required this.userId,
    required this.timestamp,
    this.playMethod = PlayMethod.directStream,
    this.serviceType = MediaServerType.emby,
    this.source,
    this.libraryId,
    this.regionGeneration,
    this.cleanupOnly = false,
    this.pendingCleanups = const [],
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final Duration position;
  final MediaServerType serviceType;
  final String baseUrl;
  final String userId;
  final DateTime timestamp;
  final PlayMethod playMethod;
  final SourceReference? source;
  final String? libraryId;
  final int? regionGeneration;

  /// A prepared resource existed, but playback had not started. Recovery must
  /// release it without writing a watched/progress event.
  final bool cleanupOnly;
  static const maxPendingCleanups = 64;
  final List<PlaybackSessionSnapshot> pendingCleanups;

  List<PlaybackSessionSnapshot> get validatedPendingCleanups {
    if (pendingCleanups.length > maxPendingCleanups ||
        pendingCleanups.any(
          (value) => !value.cleanupOnly || value.pendingCleanups.isNotEmpty,
        )) {
      throw const FormatException('Invalid pending playback cleanups');
    }
    return List.unmodifiable(pendingCleanups);
  }

  PlaybackSessionSnapshot withPendingCleanups(
    List<PlaybackSessionSnapshot> pending, {
    bool? cleanupOnly,
  }) {
    final result = PlaybackSessionSnapshot(
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      position: position,
      baseUrl: baseUrl,
      userId: userId,
      timestamp: timestamp,
      playMethod: playMethod,
      serviceType: serviceType,
      source: source,
      libraryId: libraryId,
      regionGeneration: regionGeneration,
      cleanupOnly: cleanupOnly ?? this.cleanupOnly,
      pendingCleanups: List.unmodifiable(pending),
    );
    result.validatedPendingCleanups;
    return result;
  }

  Map<String, dynamic> toJson() {
    final pending = validatedPendingCleanups;
    return {
      'itemId': itemId,
      'mediaSourceId': mediaSourceId,
      'playSessionId': playSessionId,
      'playMethod': playMethod.name,
      'schema': 2,
      'serviceType': serviceType.name,
      'positionUs': position.inMicroseconds,
      'baseUrl': baseUrl,
      'userId': userId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      if (source != null) 'source': encodeSource(source!),
      if (libraryId != null) 'libraryId': libraryId,
      if (regionGeneration != null) 'regionGeneration': regionGeneration,
      if (cleanupOnly) 'cleanupOnly': true,
      if (pending.isNotEmpty)
        'pendingCleanups': [for (final value in pending) value.toJson()],
    };
  }

  /// 缺少任一会话标识字段时返回 null(视为无效快照)。
  static PlaybackSessionSnapshot? fromJson(Map<String, dynamic> json) {
    final rawPending = json['pendingCleanups'];
    if (rawPending != null &&
        (rawPending is! List || rawPending.length > maxPendingCleanups)) {
      return null;
    }
    final pending = <PlaybackSessionSnapshot>[];
    for (final value in rawPending as List? ?? const []) {
      // Reject recursion before decoding a child, including deeply nested input.
      if (value is! Map ||
          value['cleanupOnly'] != true ||
          value.containsKey('pendingCleanups')) {
        return null;
      }
      final child = fromJson(Map<String, dynamic>.from(value));
      if (child == null) return null;
      pending.add(child);
    }
    final serviceName = json['serviceType'] ?? 'emby';
    final serviceType = MediaServerType.values
        .where((type) => type.name == serviceName)
        .firstOrNull;
    if (serviceName is! String ||
        serviceType == null ||
        (json['schema'] != null && json['schema'] != 2)) {
      return null;
    }
    final itemId = json['itemId']?.toString();
    final mediaSourceId = json['mediaSourceId']?.toString();
    final playSessionId = json['playSessionId']?.toString();
    final baseUrl = json['baseUrl']?.toString();
    final userId = json['userId']?.toString();
    if (itemId == null ||
        itemId.isEmpty ||
        mediaSourceId == null ||
        playSessionId == null ||
        baseUrl == null ||
        baseUrl.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return null;
    }
    final wire = json['playMethod']?.toString();
    var playMethod = PlayMethod.directStream;
    for (final value in PlayMethod.values) {
      if (value.name.toLowerCase() == wire?.toLowerCase()) {
        playMethod = value;
        break;
      }
    }
    final timestamp =
        DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final source = json['source'] is Map
        ? decodeSource(Map<String, dynamic>.from(json['source'] as Map))
        : null;
    if (source != null && source.account.serviceType != serviceType) {
      return null;
    }
    return PlaybackSessionSnapshot(
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      playMethod: playMethod,
      position: json['schema'] == 2
          ? Duration(microseconds: _asInt(json['positionUs']) ?? 0)
          : durationFromTicks(_asInt(json['positionTicks']) ?? 0),
      serviceType: serviceType,
      baseUrl: baseUrl,
      userId: userId,
      timestamp: timestamp,
      source: source,
      libraryId: json['libraryId'] as String?,
      regionGeneration: json['regionGeneration'] as int?,
      cleanupOnly: json['cleanupOnly'] == true,
      pendingCleanups: List.unmodifiable(pending),
    );
  }
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}
