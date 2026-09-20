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
  MatroskaCacheIndex._(this.points, this.total);
  final List<(int, Duration)> points;
  final int total;

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
      for (final track in _children(tracks, _element(tracks, 0))) {
        if (track.id != 0xae) continue;
        int? number;
        int? type;
        for (final child in _children(tracks, track)) {
          if (child.id == 0xd7) number = _uint(tracks, child);
          if (child.id == 0x83) type = _uint(tracks, child);
          // Nonstandard per-track timestamp scales need an explicit mapping.
          if (child.id == 0x23314f) return null;
        }
        if (type == 1 && videoTrack == null) videoTrack = number;
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
      return MatroskaCacheIndex._([
        for (final point in ordered)
          (point.key, Duration(microseconds: point.value * scale ~/ 1000)),
      ], total);
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  List<CachedTimeRange> ranges(List<CachedByteRange> bytes, Duration duration) {
    final result = <CachedTimeRange>[];
    var rangeIndex = 0;
    for (var i = 0; i < points.length; i++) {
      final start = points[i];
      final endByte = i + 1 < points.length ? points[i + 1].$1 : total;
      final endTime = i + 1 < points.length ? points[i + 1].$2 : duration;
      while (rangeIndex < bytes.length && bytes[rangeIndex].end <= start.$1) {
        rangeIndex++;
      }
      if (rangeIndex == bytes.length) break;
      if (bytes[rangeIndex].start > start.$1 ||
          bytes[rangeIndex].end < endByte ||
          start.$2 >= endTime ||
          endTime > duration) {
        continue;
      }
      if (result.isNotEmpty && result.last.end == start.$2) {
        final previous = result.removeLast();
        result.add(CachedTimeRange(previous.start, endTime));
      } else {
        result.add(CachedTimeRange(start.$2, endTime));
      }
    }
    return result;
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
