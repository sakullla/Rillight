import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class CachedByteRange {
  const CachedByteRange(this.start, this.end);
  final int start;

  /// Exclusive end.
  final int end;
}

class CachedTimeRange {
  const CachedTimeRange(this.start, this.end);
  final Duration start;
  final Duration end;
}

/// A bounded Matroska Cues reader. No bitrate/byte-percentage estimates: only
/// complete indexed Cluster intervals are translated into media timestamps.
class MatroskaCacheIndex {
  MatroskaCacheIndex._(
    this.points,
    this.total,
    this._metadataEnd,
    this._cuesOffset,
    this._cuesLength,
    this._videoTrack,
    this._audioTracks,
    this._timecodeScale,
  );
  final List<(int, Duration)> points;
  final int total;
  final int _metadataEnd;
  final int _cuesOffset;
  final int _cuesLength;
  final int _videoTrack;
  final Set<int> _audioTracks;
  final int _timecodeScale;
  final Set<int> _verifiedClusters = {};

  static Future<MatroskaCacheIndex?> load({
    required int total,
    required Future<Uint8List?> Function(int offset, int length) read,
  }) async {
    try {
      final prefix = await read(0, min(64 * 1024, total));
      if (prefix == null) return null;
      final ebml = _element(prefix, 0);
      if (ebml.id != 0x1a45dfa3) return null;
      final segment = _element(prefix, ebml.end);
      if (segment.id != 0x18538067) return null;
      final segmentStart = segment.data;
      final locations = <int, int>{};
      final heads = <int>[];
      var cursor = segmentStart;
      while (cursor < prefix.length) {
        final element = _element(prefix, cursor);
        locations.putIfAbsent(element.id, () => cursor);
        if (element.id == 0x114d9b74) heads.add(cursor);
        if (element.end > prefix.length || element.end <= cursor) break;
        cursor = element.end;
      }
      Future<Uint8List?> elementAt(int offset, int limit) async {
        if (offset < 0 || offset >= total) return null;
        final header = await read(offset, min(16, total - offset));
        if (header == null) return null;
        final element = _element(header, 0);
        if (element.end > limit || element.end > total - offset) return null;
        return read(offset, element.end);
      }

      // SeekHead may point to a second SeekHead near EOF. Do not chase cycles
      // or allocate arbitrary metadata supplied by an untrusted media server.
      final visited = <int>{};
      while (heads.isNotEmpty && visited.length < 4) {
        final offset = heads.removeAt(0);
        if (!visited.add(offset)) continue;
        final data = await elementAt(offset, 64 * 1024);
        if (data == null) continue;
        final root = _element(data, 0);
        for (final seek in _children(data, root)) {
          if (seek.id != 0x4dbb) continue;
          int? id;
          int? position;
          for (final child in _children(data, seek)) {
            if (child.id == 0x53ab) id = _uint(data, child);
            if (child.id == 0x53ac) position = _uint(data, child);
          }
          if (id != null &&
              position != null &&
              position < total - segmentStart) {
            final absolute = segmentStart + position;
            locations[id] = absolute;
            if (id == 0x114d9b74) heads.add(absolute);
          }
        }
      }
      final cuesOffset = locations[0x1c53bb6b];
      final tracksOffset = locations[0x1654ae6b];
      final infoOffset = locations[0x1549a966];
      if (cuesOffset == null || tracksOffset == null || infoOffset == null) {
        return null;
      }
      final info = await elementAt(infoOffset, 64 * 1024);
      final tracks = await elementAt(tracksOffset, 64 * 1024);
      final cues = await elementAt(cuesOffset, 512 * 1024);
      if (info == null || tracks == null || cues == null) return null;
      var scale = 1000000;
      for (final child in _children(info, _element(info, 0))) {
        if (child.id == 0x2ad7b1) scale = _uint(info, child);
      }
      if (scale <= 0 || scale > 1000000000) return null;
      int? videoTrack;
      final audioTracks = <int>{};
      for (final track in _children(tracks, _element(tracks, 0))) {
        if (track.id != 0xae) continue;
        int? number;
        int? type;
        String? codec;
        for (final child in _children(tracks, track)) {
          if (child.id == 0xd7) number = _uint(tracks, child);
          if (child.id == 0x83) type = _uint(tracks, child);
          if (child.id == 0x86) {
            codec = ascii.decode(tracks.sublist(child.data, child.end));
          }
          // Nonstandard per-track timestamp scales need an explicit mapping.
          if (child.id == 0x23314f) return null;
        }
        if (type == 1) {
          // The selected video track is not supplied to this index. Multiple
          // video tracks cannot be mapped without that identity.
          if (videoTrack != null || number == null) return null;
          videoTrack = number;
        }
        if (type == 2) {
          if (number == null ||
              !const {
                'A_AAC',
                'A_AC3',
                'A_EAC3',
                'A_MPEG/L3',
              }.contains(codec)) {
            return null;
          }
          audioTracks.add(number);
        }
      }
      if (videoTrack == null) return null;
      final points = <int, int>{};
      for (final point in _children(cues, _element(cues, 0))) {
        if (point.id != 0xbb) continue;
        int? time;
        final positions = <int>[];
        for (final child in _children(cues, point)) {
          if (child.id == 0xb3) time = _uint(cues, child);
          if (child.id != 0xb7) continue;
          int? track;
          int? position;
          for (final field in _children(cues, child)) {
            if (field.id == 0xf7) track = _uint(cues, field);
            if (field.id == 0xf1) position = _uint(cues, field);
          }
          if (track == videoTrack && position != null) positions.add(position);
        }
        if (time == null) continue;
        if (time < 0 || time > (1 << 52) ~/ scale) return null;
        for (final position in positions) {
          final absolute = segmentStart + position;
          if (position < 0 || absolute >= total) return null;
          points[absolute] = min(points[absolute] ?? time, time);
        }
        if (points.length > 8192) return null;
      }
      final ordered = points.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      if (ordered.length < 2) return null;
      for (var i = 1; i < ordered.length; i++) {
        if (ordered[i].value < ordered[i - 1].value) return null;
      }
      return MatroskaCacheIndex._(
        [
          for (final point in ordered)
            (point.key, Duration(microseconds: point.value * scale ~/ 1000)),
        ],
        total,
        ordered.first.key,
        cuesOffset,
        cues.length,
        videoTrack,
        audioTracks,
        scale,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Reports only complete clusters with still-cached initialization, Cues,
  /// an independently decodable video block and every declared audio track.
  /// Requiring all audio tracks is conservative when the selected track is
  /// unknown; unsupported BlockGroup or lacing layouts remain unknown.
  Future<List<CachedTimeRange>> ranges(
    List<CachedByteRange> bytes,
    Duration duration, {
    required Future<Uint8List?> Function(int offset, int length) read,
  }) async {
    final result = <CachedTimeRange>[];
    if (!_covers(bytes, 0, _metadataEnd) ||
        !_covers(bytes, _cuesOffset, _cuesOffset + _cuesLength)) {
      return result;
    }
    for (var i = 0; i < points.length; i++) {
      final start = points[i];
      final endByte = i + 1 < points.length ? points[i + 1].$1 : total;
      final endTime = i + 1 < points.length ? points[i + 1].$2 : duration;
      if (!_covers(bytes, start.$1, endByte) ||
          start.$2 >= endTime ||
          endTime > duration ||
          !(_verifiedClusters.contains(start.$1) ||
              await _verifyCluster(start.$1, endByte, start.$2, read))) {
        continue;
      }
      _verifiedClusters.add(start.$1);
      if (result.isNotEmpty && result.last.end == start.$2) {
        final previous = result.removeLast();
        result.add(CachedTimeRange(previous.start, endTime));
      } else {
        result.add(CachedTimeRange(start.$2, endTime));
      }
    }
    return result;
  }

  bool _covers(List<CachedByteRange> bytes, int start, int end) {
    if (start < 0 || end <= start || end > total) return false;
    var cursor = start;
    final ordered = bytes.toList()..sort((a, b) => a.start.compareTo(b.start));
    for (final range in ordered) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) return false;
      cursor = max(cursor, range.end);
      if (cursor >= end) return true;
    }
    return false;
  }

  Future<bool> _verifyCluster(
    int offset,
    int limit,
    Duration cueTime,
    Future<Uint8List?> Function(int offset, int length) read,
  ) async {
    try {
      final header = await read(offset, min(16, total - offset));
      if (header == null) return false;
      final cluster = _element(header, 0);
      if (cluster.id != 0x1f43b675 || offset + cluster.end > limit) {
        return false;
      }
      int? clusterTime;
      var keyframe = false;
      final audioSeen = <int>{};
      var cursor = offset + cluster.data;
      var elements = 0;
      while (cursor < offset + cluster.end && elements++ < 8192) {
        final bytes = await read(cursor, min(16, total - cursor));
        if (bytes == null) return false;
        final child = _element(bytes, 0);
        if (child.end <= child.data ||
            cursor + child.end > offset + cluster.end) {
          return false;
        }
        if (child.id == 0xe7) {
          final value = await read(cursor + child.data, child.end - child.data);
          if (value == null || value.length > 8 || value.isEmpty) return false;
          clusterTime = 0;
          for (final byte in value) {
            clusterTime = (clusterTime! << 8) | byte;
          }
        } else if (child.id == 0xa3) {
          final block = await read(
            cursor + child.data,
            min(16, child.end - child.data),
          );
          if (block == null) return false;
          final (track, trackLength) = _vint(block, 0);
          if (trackLength + 3 > block.length) return false;
          final rawTime = (block[trackLength] << 8) | block[trackLength + 1];
          final relativeTime = rawTime >= 0x8000 ? rawTime - 0x10000 : rawTime;
          final flags = block[trackLength + 2];
          if (track == _videoTrack &&
              clusterTime != null &&
              flags & 0x80 != 0 &&
              flags & 0x06 == 0) {
            final timestamp =
                (clusterTime + relativeTime) * _timecodeScale ~/ 1000;
            keyframe |= timestamp == cueTime.inMicroseconds;
          }
          if (_audioTracks.contains(track)) audioSeen.add(track);
        }
        if (keyframe && audioSeen.containsAll(_audioTracks)) return true;
        cursor += child.end;
      }
      return false;
    } on FormatException {
      return false;
    } on RangeError {
      return false;
    }
  }
}

class _Element {
  const _Element(this.id, this.data, this.end);
  final int id;
  final int data;
  final int end;
}

(int, int) _vint(Uint8List bytes, int offset, {bool id = false}) {
  if (offset >= bytes.length || bytes[offset] == 0) {
    throw const FormatException('Invalid EBML integer');
  }
  var mask = 0x80;
  var length = 1;
  while ((bytes[offset] & mask) == 0) {
    mask >>= 1;
    length++;
  }
  if (length > (id ? 4 : 8) || offset + length > bytes.length) {
    throw const FormatException('Truncated EBML integer');
  }
  var value = id ? bytes[offset] : bytes[offset] & (mask - 1);
  for (var i = 1; i < length; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return (value, length);
}

_Element _element(Uint8List bytes, int offset) {
  final id = _vint(bytes, offset, id: true);
  final size = _vint(bytes, offset + id.$2);
  final data = offset + id.$2 + size.$2;
  return _Element(id.$1, data, data + size.$1);
}

Iterable<_Element> _children(Uint8List bytes, _Element parent) sync* {
  if (parent.end > bytes.length) {
    throw const FormatException('Truncated EBML element');
  }
  var offset = parent.data;
  while (offset < parent.end) {
    final child = _element(bytes, offset);
    if (child.end > parent.end || child.end <= offset) {
      throw const FormatException('Invalid EBML child');
    }
    yield child;
    offset = child.end;
  }
}

int _uint(Uint8List bytes, _Element element) {
  if (element.end - element.data > 8 || element.end > bytes.length) {
    throw const FormatException('Invalid EBML uint');
  }
  var value = 0;
  for (var i = element.data; i < element.end; i++) {
    value = (value << 8) | bytes[i];
  }
  return value;
}
