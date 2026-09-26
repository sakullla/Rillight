import 'dart:math';

import 'matroska_cache_index.dart';

/// Timestamps must come from verified demuxed segment boundaries, not EXTINF.
/// [timelineEpoch] is shared by selected video and audio renditions and must
/// change across a discontinuity or representation reset.
class HlsVerifiedSegmentTime {
  const HlsVerifiedSegmentTime({
    required this.start,
    required this.end,
    required this.timelineEpoch,
    required this.decodeStartVerified,
    this.requiresInitialization = false,
  });

  final Duration start;
  final Duration end;
  final int timelineEpoch;
  final bool decodeStartVerified;
  final bool requiresInitialization;
}

/// Availability is scoped to the current transport session and generation.
/// The caller must supply only bytes that can still be read successfully.
class HlsCachedResource {
  const HlsCachedResource({required this.length, required this.ranges});

  final int length;
  final List<CachedByteRange> ranges;

  bool contains(CachedByteRange? requiredRange) {
    if (length <= 0) return false;
    final needed = requiredRange ?? CachedByteRange(0, length);
    if (needed.start < 0 || needed.end > length || needed.end <= needed.start) {
      return false;
    }
    final ordered =
        ranges.where((r) => r.start >= 0 && r.end > r.start).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    var cursor = needed.start;
    for (final range in ordered) {
      if (range.start > cursor) break;
      cursor = max(cursor, range.end);
      if (cursor >= needed.end) return true;
    }
    return false;
  }
}

class HlsCacheIndex {
  HlsCacheIndex._(
    List<HlsIndexedSegment> segments,
    this.mediaSequence,
    this.isLive,
  ) : segments = List.unmodifiable(segments);

  final List<HlsIndexedSegment> segments;
  final int mediaSequence;
  final bool isLive;

  /// Parses one selected media playlist. A master playlist, unsupported key
  /// method, ambiguous byte range, or malformed dependency yields null.
  /// Missing verified times are retained as unknown segments, never inferred
  /// from EXTINF or playlist position.
  static HlsCacheIndex? parseMediaPlaylist({
    required String text,
    required Uri playlistUri,
    required Map<int, HlsVerifiedSegmentTime> verifiedTimes,
  }) {
    if (text.length > 2 * 1024 * 1024) return null;
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') return null;
    var sequence = 0;
    var discontinuity = 0;
    var hasSegment = false;
    var hasDuration = false;
    var isLive = true;
    Uri? mapUri;
    CachedByteRange? mapRange;
    Uri? keyUri;
    CachedByteRange? pendingRange;
    int? pendingLength;
    int? previousRangeEnd;
    Uri? previousRangeUri;
    final segments = <HlsIndexedSegment>[];
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF:') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        return null;
      }
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        if (hasSegment) return null;
        sequence = int.tryParse(line.substring(22)) ?? -1;
        if (sequence < 0) return null;
        continue;
      }
      if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        if (hasSegment) return null;
        discontinuity = int.tryParse(line.substring(30)) ?? -1;
        if (discontinuity < 0) return null;
        continue;
      }
      if (line == '#EXT-X-DISCONTINUITY') {
        if (hasDuration || pendingLength != null) return null;
        discontinuity++;
        previousRangeEnd = null;
        previousRangeUri = null;
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        final attributes = _attributes(line.substring(11));
        final path = attributes?['URI'];
        if (path == null || path.isEmpty) return null;
        mapUri = playlistUri.resolve(path);
        final rawRange = attributes?['BYTERANGE'];
        mapRange = rawRange == null ? null : _parseRange(rawRange);
        if (rawRange != null && mapRange == null) return null;
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final attributes = _attributes(line.substring(11));
        final method = attributes?['METHOD'];
        if (method == 'NONE') {
          keyUri = null;
        } else if (method == 'AES-128') {
          final path = attributes?['URI'];
          if (path == null ||
              path.isEmpty ||
              attributes?['KEYFORMAT'] != null &&
                  attributes!['KEYFORMAT'] != 'identity') {
            return null;
          }
          keyUri = playlistUri.resolve(path);
        } else {
          return null;
        }
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        if (pendingLength != null) return null;
        final match = RegExp(
          r'^(\d+)(?:@(\d+))?$',
        ).firstMatch(line.substring(17));
        if (match == null) return null;
        pendingLength = int.tryParse(match.group(1)!);
        if (pendingLength == null || pendingLength <= 0) return null;
        pendingRange = match.group(2) == null
            ? null
            : _parseRange('${match.group(1)}@${match.group(2)}');
        if (match.group(2) != null && pendingRange == null) return null;
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        if (hasDuration) return null;
        final seconds = double.tryParse(line.substring(8).split(',').first);
        if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
        hasDuration = true;
        continue;
      }
      if (line == '#EXT-X-ENDLIST') {
        isLive = false;
        continue;
      }
      if (line.startsWith('#')) continue;
      if (!hasDuration) return null;
      final uri = playlistUri.resolve(line);
      CachedByteRange? range;
      if (pendingLength != null) {
        if (pendingRange != null) {
          range = pendingRange;
        } else {
          if (previousRangeUri != uri || previousRangeEnd == null) return null;
          range = CachedByteRange(
            previousRangeEnd,
            previousRangeEnd + pendingLength,
          );
        }
      }
      previousRangeUri = range == null ? null : uri;
      previousRangeEnd = range?.end;
      final timing = verifiedTimes[sequence];
      if (timing != null &&
          (timing.start < Duration.zero || timing.end <= timing.start)) {
        return null;
      }
      segments.add(
        HlsIndexedSegment(
          sequence: sequence,
          discontinuitySequence: discontinuity,
          uri: uri,
          byteRange: range,
          mapUri: mapUri,
          mapRange: mapRange,
          keyUri: keyUri,
          verifiedTime: timing,
        ),
      );
      hasSegment = true;
      hasDuration = false;
      pendingLength = null;
      pendingRange = null;
      sequence++;
      if (segments.length > 100000) return null;
    }
    if (hasDuration || pendingLength != null || segments.isEmpty) return null;
    final first = segments.first.sequence;
    for (var i = 1; i < segments.length; i++) {
      final before = segments[i - 1];
      final after = segments[i];
      if (after.sequence != before.sequence + 1 ||
          after.discontinuitySequence < before.discontinuitySequence) {
        return null;
      }
      final previousTime = before.verifiedTime;
      final nextTime = after.verifiedTime;
      if (previousTime != null &&
          nextTime != null &&
          nextTime.start < previousTime.end) {
        return null;
      }
      if (previousTime != null && nextTime != null) {
        final changedDiscontinuity =
            after.discontinuitySequence != before.discontinuitySequence;
        final changedEpoch =
            nextTime.timelineEpoch != previousTime.timelineEpoch;
        if (changedDiscontinuity != changedEpoch) return null;
      }
    }
    return HlsCacheIndex._(segments, first, isLive);
  }

  /// Only selected segments whose payload, init map and session key all exist
  /// are included. A selected alternate audio playlist is intersected by its
  /// verified epoch and media time, not by segment number or EXTINF duration.
  List<CachedTimeRange> ranges({
    required Map<Uri, HlsCachedResource> resources,
    required Set<Uri> usableSessionKeys,
    HlsCacheIndex? selectedAudio,
  }) {
    final primary = _available(resources, usableSessionKeys);
    if (selectedAudio == null) return _asRanges(primary);
    final audio = selectedAudio._available(resources, usableSessionKeys);
    final shared = <_Coverage>[];
    for (final video in primary) {
      for (final sound in audio) {
        if (video.epoch != sound.epoch) continue;
        final start = max(video.start, sound.start);
        final end = min(video.end, sound.end);
        if (start < end) shared.add(_Coverage(start, end, video.epoch));
      }
    }
    return _asRanges(shared);
  }

  List<_Coverage> _available(
    Map<Uri, HlsCachedResource> resources,
    Set<Uri> usableSessionKeys,
  ) {
    final result = <_Coverage>[];
    for (final segment in segments) {
      final timing = segment.verifiedTime;
      if (timing == null || !timing.decodeStartVerified) continue;
      if (timing.requiresInitialization && segment.mapUri == null) continue;
      if (resources[segment.uri]?.contains(segment.byteRange) != true) {
        continue;
      }
      if (segment.mapUri != null &&
          resources[segment.mapUri]?.contains(segment.mapRange) != true) {
        continue;
      }
      if (segment.keyUri != null &&
          !usableSessionKeys.contains(segment.keyUri)) {
        continue;
      }
      result.add(
        _Coverage(
          timing.start.inMicroseconds,
          timing.end.inMicroseconds,
          timing.timelineEpoch,
        ),
      );
    }
    return result;
  }
}

class HlsIndexedSegment {
  const HlsIndexedSegment({
    required this.sequence,
    required this.discontinuitySequence,
    required this.uri,
    required this.byteRange,
    required this.mapUri,
    required this.mapRange,
    required this.keyUri,
    required this.verifiedTime,
  });

  final int sequence;
  final int discontinuitySequence;
  final Uri uri;
  final CachedByteRange? byteRange;
  final Uri? mapUri;
  final CachedByteRange? mapRange;
  final Uri? keyUri;
  final HlsVerifiedSegmentTime? verifiedTime;
}

class _Coverage {
  const _Coverage(this.start, this.end, this.epoch);
  final int start;
  final int end;
  final int epoch;
}

List<CachedTimeRange> _asRanges(List<_Coverage> coverage) {
  final ordered = coverage.toList()
    ..sort((a, b) {
      final time = a.start.compareTo(b.start);
      return time != 0 ? time : a.end.compareTo(b.end);
    });
  final result = <CachedTimeRange>[];
  int? lastEpoch;
  for (final item in ordered) {
    if (item.start < 0 || item.end <= item.start) continue;
    final start = Duration(microseconds: item.start);
    final end = Duration(microseconds: item.end);
    if (result.isNotEmpty &&
        lastEpoch == item.epoch &&
        result.last.end >= start) {
      final previous = result.removeLast();
      result.add(
        CachedTimeRange(previous.start, maxDuration(previous.end, end)),
      );
    } else {
      result.add(CachedTimeRange(start, end));
    }
    lastEpoch = item.epoch;
  }
  return result;
}

Duration maxDuration(Duration first, Duration second) =>
    first >= second ? first : second;

CachedByteRange? _parseRange(String value) {
  final match = RegExp(r'^(\d+)@(\d+)$').firstMatch(value);
  if (match == null) return null;
  final length = int.tryParse(match.group(1)!);
  final start = int.tryParse(match.group(2)!);
  if (length == null || start == null || length <= 0 || start < 0) return null;
  return CachedByteRange(start, start + length);
}

Map<String, String>? _attributes(String value) {
  final result = <String, String>{};
  var offset = 0;
  while (offset < value.length) {
    final equal = value.indexOf('=', offset);
    if (equal < 0) return null;
    final key = value.substring(offset, equal).trim();
    if (key.isEmpty || result.containsKey(key)) return null;
    var end = equal + 1;
    String item;
    if (end < value.length && value[end] == '"') {
      final close = value.indexOf('"', end + 1);
      if (close < 0) return null;
      item = value.substring(end + 1, close);
      end = close + 1;
      if (end < value.length && value[end] != ',') return null;
    } else {
      final comma = value.indexOf(',', end);
      if (comma < 0) {
        item = value.substring(end).trim();
        end = value.length;
      } else {
        item = value.substring(end, comma).trim();
        end = comma;
      }
    }
    result[key] = item;
    offset = end + 1;
  }
  return result;
}
