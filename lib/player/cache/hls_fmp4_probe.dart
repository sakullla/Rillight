import 'dart:typed_data';

import 'matroska_cache_index.dart';
import 'mp4_cache_index.dart';

/// Demux-verified timing and track presence for one complete fMP4 HLS segment.
/// A segment with ambiguous fragments, composition offsets, missing sync
/// flags, or incomplete selected audio has no result.
class HlsFmp4ProbeResult {
  const HlsFmp4ProbeResult({
    required this.start,
    required this.end,
    required this.hasVideo,
    required this.hasAudio,
  });

  final Duration start;
  final Duration end;
  final bool hasVideo;
  final bool hasAudio;
}

Future<HlsFmp4ProbeResult?> probeHlsFmp4Segment({
  required int initializationLength,
  required int segmentLength,
  required Future<Uint8List?> Function(int offset, int length)
  readInitialization,
  required Future<Uint8List?> Function(int offset, int length) readSegment,
}) async {
  if (initializationLength <= 0 ||
      segmentLength <= 0 ||
      initializationLength > 8 * 1024 * 1024 ||
      segmentLength > 16 * 1024 * 1024) {
    return null;
  }
  final total = initializationLength + segmentLength;
  Future<Uint8List?> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > total) return null;
    if (offset + length <= initializationLength) {
      return readInitialization(offset, length);
    }
    if (offset >= initializationLength) {
      final local = offset - initializationLength;
      return readSegment(local, length);
    }
    final first = initializationLength - offset;
    final initial = await readInitialization(offset, first);
    final media = await readSegment(0, length - first);
    if (initial == null ||
        media == null ||
        initial.length != first ||
        media.length != length - first) {
      return null;
    }
    return Uint8List.fromList([...initial, ...media]);
  }

  final index = await Mp4CacheIndex.load(total: total, read: read);
  if (index == null) return null;
  final ranges = index.ranges([
    CachedByteRange(0, total),
  ], const Duration(days: 36500));
  if (ranges.length != 1) return null;
  return HlsFmp4ProbeResult(
    start: ranges.single.start,
    end: ranges.single.end,
    hasVideo: index.hasVideo,
    hasAudio: index.hasAudio,
  );
}
