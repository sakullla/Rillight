import 'dart:collection';

/// A media-time interval that is available for this playback session.
/// [end] is exclusive. A range is only valid when its media dependencies are
/// present; downloaded bytes alone do not establish a playable interval.
class BufferedRange {
  const BufferedRange(this.start, this.end);

  final Duration start;
  final Duration end;

  bool get isValid => start >= Duration.zero && end > start;

  @override
  bool operator ==(Object other) =>
      other is BufferedRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Downloaded byte offsets in one progressive media representation. These
/// offsets do not establish playable time or seekability.
class BufferedByteRange {
  const BufferedByteRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is BufferedByteRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

class BufferedByteCoverage {
  BufferedByteCoverage({
    required this.totalBytes,
    required Iterable<BufferedByteRange> ranges,
  }) : assert(totalBytes > 0),
       ranges = UnmodifiableListView(_normalize(ranges, totalBytes));

  final int totalBytes;
  final List<BufferedByteRange> ranges;

  static List<BufferedByteRange> _normalize(
    Iterable<BufferedByteRange> source,
    int total,
  ) {
    final values = <BufferedByteRange>[
      for (final range in source)
        if (range.start >= 0 && range.end > range.start && range.start < total)
          BufferedByteRange(range.start, range.end.clamp(0, total)),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <BufferedByteRange>[];
    for (final current in values) {
      if (merged.isNotEmpty && current.start <= merged.last.end) {
        final previous = merged.removeLast();
        merged.add(
          BufferedByteRange(
            previous.start,
            current.end > previous.end ? current.end : previous.end,
          ),
        );
      } else {
        merged.add(current);
      }
    }
    return merged;
  }
}

/// The one authoritative cache-timeline observation for a backend session.
/// An empty [ranges] list with [unknownReason] means coverage cannot be
/// established; it must not be replaced by a bitrate or byte-ratio estimate.
class BufferSnapshot {
  BufferSnapshot({
    required this.sessionId,
    required this.resourceId,
    required this.representationVersion,
    required this.trackVersion,
    required this.sequence,
    required Iterable<BufferedRange> ranges,
    this.unknownReason,
    this.byteCoverage,
    Duration? duration,
  }) : ranges = UnmodifiableListView(_normalize(ranges, duration: duration));

  factory BufferSnapshot.empty({
    required int sessionId,
    String resourceId = '',
    String representationVersion = '',
    int trackVersion = 0,
    int sequence = 0,
    String? unknownReason,
  }) => BufferSnapshot(
    sessionId: sessionId,
    resourceId: resourceId,
    representationVersion: representationVersion,
    trackVersion: trackVersion,
    sequence: sequence,
    ranges: const [],
    unknownReason: unknownReason,
  );

  final int sessionId;
  final String resourceId;
  final String representationVersion;
  final int trackVersion;
  final int sequence;
  final List<BufferedRange> ranges;
  final String? unknownReason;
  final BufferedByteCoverage? byteCoverage;

  bool get isKnown => unknownReason == null;

  /// Reject late cache updates after a media, representation, or track switch.
  /// A changed identity is accepted only after the controller establishes its
  /// new expected identity; this method does not guess ordering across them.
  bool isNewerThan(BufferSnapshot previous) =>
      sessionId == previous.sessionId &&
      resourceId == previous.resourceId &&
      representationVersion == previous.representationVersion &&
      trackVersion == previous.trackVersion &&
      sequence > previous.sequence;

  static List<BufferedRange> _normalize(
    Iterable<BufferedRange> source, {
    Duration? duration,
  }) {
    final limit = duration != null && duration > Duration.zero
        ? duration
        : null;
    final values = <BufferedRange>[];
    for (final range in source) {
      if (!range.isValid) continue;
      if (limit != null && range.start >= limit) continue;
      final end = limit != null && range.end > limit ? limit : range.end;
      if (end > range.start) values.add(BufferedRange(range.start, end));
    }
    values.sort((a, b) {
      final order = a.start.compareTo(b.start);
      return order != 0 ? order : a.end.compareTo(b.end);
    });
    final merged = <BufferedRange>[];
    for (final current in values) {
      if (merged.isNotEmpty && current.start <= merged.last.end) {
        final previous = merged.removeLast();
        merged.add(
          BufferedRange(
            previous.start,
            current.end > previous.end ? current.end : previous.end,
          ),
        );
      } else {
        merged.add(current);
      }
    }
    return merged;
  }
}
