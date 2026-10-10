import 'dart:math';
import 'dart:typed_data';

import 'matroska_cache_index.dart';

/// A deliberately bounded ISO BMFF index. Only files whose selected tracks
/// have complete, verifiable sample tables are accepted. A missing table,
/// complex edit list, encryption, external data reference, or unsupported fragment
/// leaves the cache timeline unknown instead of estimating it from bitrate.
class Mp4CacheIndex {
  Mp4CacheIndex._(
    this._units,
    this.total, {
    required this.hasVideo,
    required this.hasAudio,
  });

  final List<_PlayableUnit> _units;

  final int total;
  final bool hasVideo;
  final bool hasAudio;

  static Future<Mp4CacheIndex?> load({
    required int total,
    required Future<Uint8List?> Function(int offset, int length) read,
    int? selectedVideoTrackId,
    int? selectedAudioTrackId,
    Future<void> Function()? checkpoint,
  }) async {
    if (total < 16) return null;
    try {
      final top = <_Box>[];
      var offset = 0;
      while (offset < total && top.length < 1024) {
        var header = await read(offset, min(8, total - offset));
        if (header == null || header.length < 8) return null;
        if (_u32(header, 0) == 1) {
          header = await read(offset, min(16, total - offset));
          if (header == null || header.length < 16) return null;
        }
        final box = _box(header, 0, absoluteStart: offset, limit: total);
        if (box == null || box.end <= offset) return null;
        top.add(box);
        offset = box.end;
      }
      if (offset != total) return null;
      final moovs = top.where((box) => box.type == 'moov').toList();
      final mdats = top.where((box) => box.type == 'mdat').toList();
      if (moovs.length != 1 || mdats.isEmpty) return null;
      final moov = moovs.single;
      if (moov.end - moov.start > 8 * 1024 * 1024) return null;
      final data = await read(moov.start, moov.end - moov.start);
      if (data == null || data.length != moov.end - moov.start) return null;
      final root = _box(data, 0, limit: data.length);
      if (root == null || root.end != data.length) return null;
      final children = _children(data, root);
      final fragmented = children.any((box) => box.type == 'mvex');
      if (fragmented) {
        return await _loadFragmented(
          total: total,
          read: read,
          top: top,
          moov: moov,
          moovData: data,
          children: children,
          mdats: mdats,
          selectedVideoTrackId: selectedVideoTrackId,
          selectedAudioTrackId: selectedAudioTrackId,
          checkpoint: checkpoint,
        );
      }
      if (top.any((box) => box.type == 'moof')) return null;
      final movieHeader = _child(data, root, 'mvhd');
      final movieScale = movieHeader == null
          ? null
          : _movieScale(data, movieHeader);
      // Resolve identities before expanding sample tables. A multi-audio movie
      // can contain hundreds of thousands of samples per unused track; those
      // allocations cannot contribute to the selected playback timeline.
      final tracks = <_Track>[];
      final trackBoxes = <int, _Box>{};
      for (final box in children.where((box) => box.type == 'trak')) {
        if (checkpoint != null) await checkpoint();
        final track = _trackIdentity(data, box);
        if (track == null) return null;
        if (trackBoxes.containsKey(track.id)) return null;
        trackBoxes[track.id] = box;
        if (track.kind == 'vide' || track.kind == 'soun') tracks.add(track);
      }
      var video = _selected(tracks, 'vide', selectedVideoTrackId);
      var audio = _selected(tracks, 'soun', selectedAudioTrackId);
      if (video == null && audio == null) return null;
      if (tracks.where((track) => track.kind == 'vide').length > 1 &&
          selectedVideoTrackId == null) {
        return null;
      }
      if (tracks.where((track) => track.kind == 'soun').length > 1 &&
          selectedAudioTrackId == null) {
        return null;
      }
      if (selectedVideoTrackId != null && video == null) return null;
      if (selectedAudioTrackId != null && audio == null) return null;
      if (video != null) {
        video = await _track(
          data,
          trackBoxes[video.id]!,
          mdats,
          movieScale,
          checkpoint,
        );
        if (video == null) return null;
      }
      if (audio != null) {
        audio = await _track(
          data,
          trackBoxes[audio.id]!,
          mdats,
          movieScale,
          checkpoint,
        );
        if (audio == null) return null;
      }
      if (audio != null) {
        for (var i = 1; i < audio.samples.length; i++) {
          if (audio.samples[i].startUs < audio.samples[i - 1].startUs) {
            return null;
          }
          if (checkpoint != null && i % 256 == 0) await checkpoint();
        }
      }
      final primary = video ?? audio!;
      final starts = <int>[
        for (var i = 0; i < primary.samples.length; i++)
          if (primary.samples[i].sync) i,
      ];
      if (starts.isEmpty || starts.first != 0) return null;
      // A stream with every frame marked random access still needs a bounded
      // number of time units. Coalescing adjacent decode groups is conservative.
      const maxUnits = 8192;
      final stride = (starts.length + maxUnits - 1) ~/ maxUnits;
      final groupStarts = [
        for (var i = 0; i < starts.length; i += stride) starts[i],
      ];
      final metadata = <CachedByteRange>[
        CachedByteRange(moov.start, moov.end),
        for (final box in top.where((box) => box.type == 'ftyp'))
          CachedByteRange(box.start, box.end),
        for (final box in mdats) CachedByteRange(box.start, box.data),
      ];
      final units = <_PlayableUnit>[];
      var audioCursor = 0;
      var totalDependencies = 0;
      var lastBegin = -1;
      for (var group = 0; group < groupStarts.length; group++) {
        if (checkpoint != null && group % 32 == 0) await checkpoint();
        final from = groupStarts[group];
        final to = group + 1 < groupStarts.length
            ? groupStarts[group + 1]
            : primary.samples.length;
        if (to - from > 8192) return null;
        final segment = primary.samples.sublist(from, to);
        final timing = _presentationRange(segment);
        if (timing == null) continue;
        final (begin, end) = timing;
        if (begin < lastBegin) return null;
        lastBegin = begin;
        final required = <CachedByteRange>[
          ...metadata,
          if (group == 0 && audio != null) ...audio.leadingBytes,
          for (final sample in segment)
            CachedByteRange(sample.byteStart, sample.byteEnd),
        ];
        if (video != null && audio != null) {
          final audioSamples = audio.samples;
          while (audioCursor < audioSamples.length &&
              audioSamples[audioCursor].endUs <= begin) {
            audioCursor++;
            if (checkpoint != null && audioCursor % 256 == 0) {
              await checkpoint();
            }
          }
          var cursor = audioCursor;
          var covered = begin;
          while (cursor < audioSamples.length &&
              audioSamples[cursor].startUs < end) {
            final sample = audioSamples[cursor];
            if (sample.startUs > covered + sample.toleranceUs) break;
            if (sample.endUs > covered) covered = sample.endUs;
            required.add(CachedByteRange(sample.byteStart, sample.byteEnd));
            cursor++;
            if (required.length > 16384) return null;
            if (checkpoint != null && cursor % 256 == 0) await checkpoint();
          }
          if (covered + segment.last.toleranceUs < end) continue;
        }
        totalDependencies += required.length;
        if (totalDependencies > 500000) return null;
        units.add(
          _PlayableUnit(
            begin,
            end,
            _mergeBytes(required),
            toleranceUs: segment.first.toleranceUs,
          ),
        );
      }
      for (var i = 1; i < units.length; i++) {
        if (units[i].startUs < units[i - 1].endUs - units[i].toleranceUs) {
          return null;
        }
      }
      if (units.isEmpty) return null;
      return Mp4CacheIndex._(
        units,
        total,
        hasVideo: video != null,
        hasAudio: audio != null,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Returns only independently decodable groups with *all* selected audio,
  /// video and initialization bytes still available. End is exclusive.
  List<CachedTimeRange> ranges(
    List<CachedByteRange> available,
    Duration duration,
  ) {
    if (duration <= Duration.zero) return const [];
    final bytes = _mergeBytes(available);
    final result = <CachedTimeRange>[];
    for (final unit in _units) {
      if (unit.startUs >= unit.endUs ||
          unit.startUs < 0 ||
          unit.endUs > duration.inMicroseconds ||
          !unit.required.every((need) => _contains(bytes, need))) {
        continue;
      }
      _appendTime(result, unit);
    }
    return result;
  }

  /// Production timeline projection yields between bounded dependency batches.
  /// The caller owns the wall-clock deadline and may cancel after any batch.
  Future<List<CachedTimeRange>> rangesWithBudget(
    List<CachedByteRange> available,
    Duration duration, {
    required Future<void> Function() checkpoint,
  }) async {
    if (duration <= Duration.zero) return const [];
    final bytes = _mergeBytes(available);
    final result = <CachedTimeRange>[];
    for (var i = 0; i < _units.length; i++) {
      if (i % 32 == 0) await checkpoint();
      final unit = _units[i];
      if (unit.startUs >= unit.endUs ||
          unit.startUs < 0 ||
          unit.endUs > duration.inMicroseconds) {
        continue;
      }
      var complete = true;
      for (var j = 0; j < unit.required.length; j++) {
        if (j % 256 == 0) await checkpoint();
        if (!_contains(bytes, unit.required[j])) {
          complete = false;
          break;
        }
      }
      if (complete) _appendTime(result, unit);
    }
    return result;
  }
}

void _appendTime(List<CachedTimeRange> result, _PlayableUnit unit) {
  final start = Duration(microseconds: unit.startUs);
  final end = Duration(microseconds: unit.endUs);
  if (result.isNotEmpty &&
      start.inMicroseconds <=
          result.last.end.inMicroseconds + unit.toleranceUs) {
    final previous = result.removeLast();
    result.add(
      CachedTimeRange(previous.start, end > previous.end ? end : previous.end),
    );
  } else {
    result.add(CachedTimeRange(start, end));
  }
}

class _PlayableUnit {
  const _PlayableUnit(
    this.startUs,
    this.endUs,
    this.required, {
    this.toleranceUs = 0,
  });
  final int startUs;
  final int endUs;
  final List<CachedByteRange> required;
  final int toleranceUs;
}

class _Sample {
  const _Sample(
    this.startUs,
    this.endUs,
    this.byteStart,
    this.byteEnd,
    this.sync, {
    this.toleranceUs = 0,
  });
  final int startUs;
  final int endUs;
  final int byteStart;
  final int byteEnd;
  final bool sync;
  // Container timestamps can quantize a continuous frame boundary by one tick.
  // This is a time-scale allowance, never a missing-byte or missing-frame estimate.
  final int toleranceUs;
}

class _Track {
  const _Track(
    this.id,
    this.kind,
    this.samples, {
    this.leadingBytes = const [],
  });
  final int id;
  final String kind;
  final List<_Sample> samples;
  final List<CachedByteRange> leadingBytes;
}

class _FragmentTrack {
  const _FragmentTrack(this.id, this.kind, this.scale);
  final int id;
  final String kind;
  final int scale;
}

class _TrackDefaults {
  const _TrackDefaults(this.duration, this.size, this.flags);
  final int duration;
  final int size;
  final int flags;
}

class _FragmentSamples {
  const _FragmentSamples(this.trackId, this.samples, this.headers);
  final int trackId;
  final List<_Sample> samples;
  final List<CachedByteRange> headers;
}

Future<Mp4CacheIndex?> _loadFragmented({
  required int total,
  required Future<Uint8List?> Function(int offset, int length) read,
  required List<_Box> top,
  required _Box moov,
  required Uint8List moovData,
  required List<_Box> children,
  required List<_Box> mdats,
  required int? selectedVideoTrackId,
  required int? selectedAudioTrackId,
  required Future<void> Function()? checkpoint,
}) async {
  final mvexes = children.where((b) => b.type == 'mvex').toList();
  if (mvexes.length != 1) return null;
  final mvex = mvexes.single;
  final metadata = <_FragmentTrack>[];
  for (final box in children.where((box) => box.type == 'trak')) {
    final track = _fragmentTrack(moovData, box);
    if (track == null) return null;
    if (metadata.any((previous) => previous.id == track.id)) return null;
    if (track.kind == 'vide' || track.kind == 'soun') metadata.add(track);
  }
  _FragmentTrack? selected(String kind, int? id) {
    final matches = metadata.where((track) => track.kind == kind).toList();
    if (id != null) {
      for (final match in matches) {
        if (match.id == id) return match;
      }
      return null;
    }
    return matches.length == 1 ? matches.single : null;
  }

  final video = selected('vide', selectedVideoTrackId);
  final audio = selected('soun', selectedAudioTrackId);
  if (video == null && audio == null ||
      selectedVideoTrackId != null && video == null ||
      selectedAudioTrackId != null && audio == null ||
      metadata.where((track) => track.kind == 'vide').length > 1 &&
          selectedVideoTrackId == null ||
      metadata.where((track) => track.kind == 'soun').length > 1 &&
          selectedAudioTrackId == null) {
    return null;
  }
  final defaults = <int, _TrackDefaults>{};
  for (final trex in _children(
    moovData,
    mvex,
  ).where((box) => box.type == 'trex')) {
    if (trex.data + 24 > trex.end) return null;
    final id = _u32(moovData, trex.data + 4);
    if (_u32(moovData, trex.data + 8) != 1 || defaults.containsKey(id)) {
      return null;
    }
    defaults[id] = _TrackDefaults(
      _u32(moovData, trex.data + 12),
      _u32(moovData, trex.data + 16),
      _u32(moovData, trex.data + 20),
    );
  }
  final selectedIds = {video?.id, audio?.id}..remove(null);
  if (!selectedIds.every(defaults.containsKey)) return null;
  final fragments = <_FragmentSamples>[];
  var totalSamples = 0;
  for (final moof in top.where((box) => box.type == 'moof')) {
    if (checkpoint != null) await checkpoint();
    if (moof.end - moof.start > 8 * 1024 * 1024) return null;
    final bytes = await read(moof.start, moof.end - moof.start);
    if (bytes == null || bytes.length != moof.end - moof.start) return null;
    final root = _box(bytes, 0, limit: bytes.length);
    if (root == null || root.end != bytes.length) return null;
    for (final traf in _children(
      bytes,
      root,
    ).where((box) => box.type == 'traf')) {
      if (checkpoint != null) await checkpoint();
      final tfhd = _child(bytes, traf, 'tfhd');
      if (tfhd == null || tfhd.data + 8 > tfhd.end) return null;
      final id = _u32(bytes, tfhd.data + 4);
      if (!selectedIds.contains(id)) continue;
      final track = metadata.singleWhere((track) => track.id == id);
      final parsed = _parseFragmentTrack(
        bytes: bytes,
        traf: traf,
        moof: moof,
        mdats: mdats,
        track: track,
        defaults: defaults[id]!,
      );
      if (parsed == null) return null;
      totalSamples += parsed.samples.length;
      if (totalSamples > 200000) return null;
      fragments.add(parsed);
    }
  }
  if (fragments.isEmpty) return null;
  final primaryId = (video ?? audio!).id;
  final primary =
      fragments.where((fragment) => fragment.trackId == primaryId).toList()
        ..sort(
          (a, b) => a.samples.first.startUs.compareTo(b.samples.first.startUs),
        );
  final audioFragments = audio == null
      ? <_FragmentSamples>[]
      : (fragments
            .where(
              (fragment) =>
                  fragment.trackId == audio.id && fragment.samples.isNotEmpty,
            )
            .toList()
          ..sort(
            (a, b) =>
                a.samples.first.startUs.compareTo(b.samples.first.startUs),
          ));
  final init = <CachedByteRange>[
    CachedByteRange(moov.start, moov.end),
    for (final box in top.where((box) => box.type == 'ftyp'))
      CachedByteRange(box.start, box.end),
  ];
  final units = <_PlayableUnit>[];
  var audioFragmentCursor = 0;
  var totalDependencies = 0;
  for (final fragment in primary) {
    if (checkpoint != null) await checkpoint();
    final samples = fragment.samples;
    if (samples.isEmpty || !samples.first.sync || !_continuous(samples)) {
      continue;
    }
    final begin = samples.first.startUs;
    final end = samples.last.endUs;
    final required = <CachedByteRange>[
      ...init,
      ...fragment.headers,
      for (final sample in samples)
        CachedByteRange(sample.byteStart, sample.byteEnd),
    ];
    if (video != null && audio != null) {
      while (audioFragmentCursor < audioFragments.length &&
          (audioFragments[audioFragmentCursor].samples.isEmpty ||
              audioFragments[audioFragmentCursor].samples.last.endUs <=
                  begin)) {
        audioFragmentCursor++;
      }
      final matchingFragments = <_FragmentSamples>[];
      for (
        var cursor = audioFragmentCursor;
        cursor < audioFragments.length &&
            audioFragments[cursor].samples.first.startUs < end;
        cursor++
      ) {
        matchingFragments.add(audioFragments[cursor]);
        if (matchingFragments.length > 256) return null;
        if (checkpoint != null && cursor % 32 == 0) await checkpoint();
      }
      final matching = <_Sample>[];
      for (final part in matchingFragments) {
        for (final sample in part.samples) {
          if (sample.endUs > begin && sample.startUs < end) {
            matching.add(sample);
            if (matching.length > 16384) return null;
          }
        }
        if (checkpoint != null) await checkpoint();
      }
      matching.sort((a, b) => a.startUs.compareTo(b.startUs));
      if (matching.isEmpty ||
          matching.first.startUs > begin ||
          matching.last.endUs < end ||
          !_continuous(matching)) {
        continue;
      }
      for (final part in matchingFragments) {
        required.addAll(part.headers);
      }
      required.addAll([
        for (final sample in matching)
          CachedByteRange(sample.byteStart, sample.byteEnd),
      ]);
      if (required.length > 16384) return null;
    }
    totalDependencies += required.length;
    if (units.length >= 8192 || totalDependencies > 500000) return null;
    units.add(_PlayableUnit(begin, end, required));
  }
  units.sort((a, b) => a.startUs.compareTo(b.startUs));
  for (var i = 1; i < units.length; i++) {
    if (units[i].startUs < units[i - 1].endUs) return null;
  }
  if (units.isEmpty) return null;
  return Mp4CacheIndex._(
    units,
    total,
    hasVideo: video != null,
    hasAudio: audio != null,
  );
}

_FragmentTrack? _fragmentTrack(Uint8List bytes, _Box box) {
  if (_child(bytes, box, 'edts') != null) return null;
  final tkhd = _child(bytes, box, 'tkhd');
  final mdia = _child(bytes, box, 'mdia');
  if (tkhd == null || mdia == null || tkhd.data + 16 > tkhd.end) return null;
  final tkhdVersion = bytes[tkhd.data];
  if (tkhdVersion != 0 && tkhdVersion != 1) return null;
  final idOffset = tkhd.data + (tkhdVersion == 1 ? 20 : 12);
  if (idOffset + 4 > tkhd.end) return null;
  final id = _u32(bytes, idOffset);
  if (id == 0) return null;
  final hdlr = _child(bytes, mdia, 'hdlr');
  final mdhd = _child(bytes, mdia, 'mdhd');
  final minf = _child(bytes, mdia, 'minf');
  if (hdlr == null ||
      mdhd == null ||
      minf == null ||
      hdlr.data + 12 > hdlr.end) {
    return null;
  }
  final kind = _type(bytes, hdlr.data + 8);
  if (kind != 'vide' && kind != 'soun') return _FragmentTrack(id, kind, 1);
  final mdhdVersion = bytes[mdhd.data];
  if (mdhdVersion != 0 && mdhdVersion != 1) return null;
  final scaleOffset = mdhd.data + (mdhdVersion == 1 ? 20 : 12);
  if (scaleOffset + 4 > mdhd.end) return null;
  final scale = _u32(bytes, scaleOffset);
  if (scale == 0) return null;
  final stbl = _child(bytes, minf, 'stbl');
  if (stbl == null) return null;
  final tables = _children(bytes, stbl);
  if (tables.any((b) => {'ctts', 'senc', 'saiz', 'saio'}.contains(b.type))) {
    return null;
  }
  final stsd = _child(bytes, stbl, 'stsd');
  if (stsd == null ||
      stsd.data + 24 > stsd.end ||
      _u32(bytes, stsd.data + 4) != 1 ||
      ByteData.sublistView(bytes).getUint16(stsd.data + 22) != 1) {
    return null;
  }
  final entry = _box(bytes, stsd.data + 8, limit: stsd.end);
  if (entry == null ||
      entry.end != stsd.end ||
      {'encv', 'enca'}.contains(entry.type)) {
    return null;
  }
  final dinf = _child(bytes, minf, 'dinf');
  final dref = dinf == null ? null : _child(bytes, dinf, 'dref');
  if (dref == null ||
      dref.data + 8 > dref.end ||
      _u32(bytes, dref.data + 4) != 1) {
    return null;
  }
  final references = _children(
    bytes,
    _Box('dref', dref.start, dref.data + 8, dref.end),
  );
  if (references.length != 1 ||
      references.single.type != 'url ' ||
      references.single.data + 4 > references.single.end ||
      _u32(bytes, references.single.data) & 1 == 0) {
    return null;
  }
  return _FragmentTrack(id, kind, scale);
}

_FragmentSamples? _parseFragmentTrack({
  required Uint8List bytes,
  required _Box traf,
  required _Box moof,
  required List<_Box> mdats,
  required _FragmentTrack track,
  required _TrackDefaults defaults,
}) {
  final tfhd = _child(bytes, traf, 'tfhd');
  final tfdt = _child(bytes, traf, 'tfdt');
  final trafChildren = _children(bytes, traf);
  final truns = trafChildren.where((b) => b.type == 'trun').toList();
  if (tfhd == null ||
      tfdt == null ||
      trafChildren.where((b) => b.type == 'tfhd').length != 1 ||
      trafChildren.where((b) => b.type == 'tfdt').length != 1 ||
      truns.length != 1 ||
      tfhd.data + 8 > tfhd.end ||
      tfdt.data + 8 > tfdt.end) {
    return null;
  }
  final headerFlags = _u32(bytes, tfhd.data) & 0xffffff;
  if (headerFlags & 0x020000 == 0 ||
      headerFlags & ~0x020038 != 0 ||
      headerFlags & 0x000003 != 0 ||
      headerFlags & 0x010000 != 0) {
    return null;
  }
  var headerCursor = tfhd.data + 8;
  var duration = defaults.duration;
  var size = defaults.size;
  var flags = defaults.flags;
  if (headerFlags & 0x000008 != 0) {
    if (headerCursor + 4 > tfhd.end) return null;
    duration = _u32(bytes, headerCursor);
    headerCursor += 4;
  }
  if (headerFlags & 0x000010 != 0) {
    if (headerCursor + 4 > tfhd.end) return null;
    size = _u32(bytes, headerCursor);
    headerCursor += 4;
  }
  if (headerFlags & 0x000020 != 0) {
    if (headerCursor + 4 > tfhd.end) return null;
    flags = _u32(bytes, headerCursor);
    headerCursor += 4;
  }
  if (headerCursor != tfhd.end) return null;
  final timeVersion = bytes[tfdt.data];
  if (timeVersion != 0 && timeVersion != 1) return null;
  final timeWidth = timeVersion == 0 ? 4 : 8;
  if (tfdt.data + 4 + timeWidth != tfdt.end) return null;
  var ticks = timeVersion == 0
      ? _u32(bytes, tfdt.data + 4)
      : _u64(bytes, tfdt.data + 4);
  final trun = truns.single;
  if (trun.data + 12 > trun.end) return null;
  final runFlags = _u32(bytes, trun.data) & 0xffffff;
  if (runFlags & 1 == 0 || runFlags & ~0x000705 != 0) return null;
  final count = _u32(bytes, trun.data + 4);
  if (count == 0 || count > 8192) return null;
  var cursor = trun.data + 8;
  var dataOffset = _u32(bytes, cursor);
  if (dataOffset > 0x7fffffff) dataOffset -= 0x100000000;
  cursor += 4;
  final firstFlags = runFlags & 0x000004 != 0 ? _u32(bytes, cursor) : flags;
  if (runFlags & 0x000004 != 0) cursor += 4;
  var byteOffset = moof.start + dataOffset;
  final samples = <_Sample>[];
  for (var i = 0; i < count; i++) {
    var sampleDuration = duration;
    var sampleSize = size;
    var sampleFlags = i == 0 ? firstFlags : flags;
    if (runFlags & 0x000100 != 0) {
      if (cursor + 4 > trun.end) return null;
      sampleDuration = _u32(bytes, cursor);
      cursor += 4;
    }
    if (runFlags & 0x000200 != 0) {
      if (cursor + 4 > trun.end) return null;
      sampleSize = _u32(bytes, cursor);
      cursor += 4;
    }
    if (runFlags & 0x000400 != 0) {
      if (cursor + 4 > trun.end) return null;
      sampleFlags = _u32(bytes, cursor);
      cursor += 4;
    }
    if (sampleDuration <= 0 || sampleSize <= 0) return null;
    final endByte = byteOffset + sampleSize;
    if (_mdatContaining(mdats, byteOffset, endByte) == null) return null;
    final nextTicks = ticks + sampleDuration;
    final startUs = ticks * 1000000 ~/ track.scale;
    final endUs = nextTicks * 1000000 ~/ track.scale;
    if (endUs <= startUs) return null;
    samples.add(
      _Sample(
        startUs,
        endUs,
        byteOffset,
        endByte,
        track.kind == 'soun' ||
            (sampleFlags & 0x00010000 == 0 && ((sampleFlags >> 24) & 3) == 2),
      ),
    );
    ticks = nextTicks;
    byteOffset = endByte;
  }
  if (cursor != trun.end) return null;
  final mdat = _mdatContaining(
    mdats,
    samples.first.byteStart,
    samples.last.byteEnd,
  );
  if (mdat == null) return null;
  final headers = <CachedByteRange>[
    CachedByteRange(moof.start, moof.end),
    CachedByteRange(mdat.start, mdat.data),
  ];
  return _FragmentSamples(track.id, samples, headers);
}

_Track? _selected(List<_Track> tracks, String kind, int? id) {
  final candidates = tracks.where((track) => track.kind == kind);
  if (id != null) {
    for (final track in candidates) {
      if (track.id == id) return track;
    }
    return null;
  }
  return candidates.length == 1 ? candidates.single : null;
}

bool _continuous(List<_Sample> samples) {
  if (samples.isEmpty) return false;
  for (var i = 1; i < samples.length; i++) {
    if (samples[i - 1].endUs != samples[i].startUs) return false;
  }
  return true;
}

_Box? _mdatContaining(List<_Box> mdats, int start, int end) {
  var low = 0;
  var high = mdats.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (mdats[middle].data <= start) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (low == 0) return null;
  final mdat = mdats[low - 1];
  return end <= mdat.end ? mdat : null;
}

/// A complete decode group may have B-frame presentation order different from
/// sample order. Only publish its interval when presentation covers every tick.
(int, int)? _presentationRange(List<_Sample> samples) {
  if (samples.isEmpty) return null;
  final ordered = samples.toList()
    ..sort((a, b) => a.startUs.compareTo(b.startUs));
  if (ordered.first.startUs < 0) return null;
  var end = ordered.first.endUs;
  for (final sample in ordered.skip(1)) {
    if (sample.startUs > end + sample.toleranceUs ||
        sample.endUs <= sample.startUs) {
      return null;
    }
    if (sample.endUs > end) end = sample.endUs;
  }
  return (ordered.first.startUs, end);
}

List<CachedByteRange> _mergeBytes(List<CachedByteRange> ranges) {
  final ordered = ranges.where((r) => r.start >= 0 && r.end > r.start).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <CachedByteRange>[];
  for (final range in ordered) {
    if (merged.isNotEmpty && merged.last.end >= range.start) {
      final prior = merged.removeLast();
      merged.add(CachedByteRange(prior.start, max(prior.end, range.end)));
    } else {
      merged.add(range);
    }
  }
  return merged;
}

bool _contains(List<CachedByteRange> available, CachedByteRange need) {
  var low = 0;
  var high = available.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (available[middle].start <= need.start) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low > 0 && available[low - 1].end >= need.end;
}

class _Box {
  const _Box(this.type, this.start, this.data, this.end);
  final String type;
  final int start;
  final int data;
  final int end;
}

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset);

int _u64(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset);

String _type(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

_Box? _box(
  Uint8List bytes,
  int offset, {
  int absoluteStart = 0,
  required int limit,
}) {
  if (offset < 0 || offset + 8 > bytes.length) return null;
  final size32 = _u32(bytes, offset);
  final header = size32 == 1 ? 16 : 8;
  if (offset + header > bytes.length) return null;
  final size = size32 == 0
      ? limit - absoluteStart - offset
      : size32 == 1
      ? _u64(bytes, offset + 8)
      : size32;
  final start = absoluteStart + offset;
  if (size < header || size > limit - start) return null;
  return _Box(_type(bytes, offset + 4), start, start + header, start + size);
}

List<_Box> _children(Uint8List bytes, _Box parent) {
  final result = <_Box>[];
  var offset = parent.data;
  while (offset < parent.end) {
    final box = _box(bytes, offset, limit: parent.end);
    if (box == null || box.end <= offset) {
      throw const FormatException('Invalid BMFF child');
    }
    result.add(box);
    offset = box.end;
    if (result.length > 8192) throw const FormatException('Too many boxes');
  }
  return result;
}

_Box? _child(Uint8List bytes, _Box parent, String type) {
  for (final box in _children(bytes, parent)) {
    if (box.type == type) return box;
  }
  return null;
}

_Track? _trackIdentity(Uint8List bytes, _Box box) {
  final tkhd = _child(bytes, box, 'tkhd');
  final mdia = _child(bytes, box, 'mdia');
  if (tkhd == null || mdia == null || tkhd.data >= tkhd.end) return null;
  final version = bytes[tkhd.data];
  if (version != 0 && version != 1) return null;
  final idOffset = tkhd.data + (version == 1 ? 20 : 12);
  if (idOffset + 4 > tkhd.end) return null;
  final id = _u32(bytes, idOffset);
  if (id == 0) return null;
  final hdlr = _child(bytes, mdia, 'hdlr');
  if (hdlr == null || hdlr.data + 12 > hdlr.end) return null;
  return _Track(id, _type(bytes, hdlr.data + 8), const []);
}

Future<_Track?> _track(
  Uint8List bytes,
  _Box box,
  List<_Box> mdats,
  int? movieScale,
  Future<void> Function()? checkpoint,
) async {
  final identity = _trackIdentity(bytes, box);
  if (identity == null) return null;
  final id = identity.id;
  final kind = identity.kind;
  if (kind != 'vide' && kind != 'soun') return identity;
  final edts = _child(bytes, box, 'edts');
  final mdia = _child(bytes, box, 'mdia')!;
  final mdhd = _child(bytes, mdia, 'mdhd');
  final minf = _child(bytes, mdia, 'minf');
  if (mdhd == null || minf == null || mdhd.data >= mdhd.end) return null;
  final mdhdVersion = bytes[mdhd.data];
  if (mdhdVersion != 0 && mdhdVersion != 1) return null;
  final scaleOffset = mdhd.data + (mdhdVersion == 1 ? 20 : 12);
  if (scaleOffset + 4 > mdhd.end) return null;
  final scale = _u32(bytes, scaleOffset);
  if (scale == 0) return null;
  final stbl = _child(bytes, minf, 'stbl');
  if (stbl == null) return null;
  final dinf = _child(bytes, minf, 'dinf');
  final dref = dinf == null ? null : _child(bytes, dinf, 'dref');
  if (dref == null || dref.data + 8 > dref.end) return null;
  if (_u32(bytes, dref.data + 4) != 1) return null;
  final references = _children(
    bytes,
    _Box('dref', dref.start, dref.data + 8, dref.end),
  );
  if (references.length != 1 ||
      references.single.type != 'url ' ||
      references.single.data + 4 > references.single.end ||
      _u32(bytes, references.single.data) & 1 == 0) {
    return null;
  }
  final tables = _children(bytes, stbl);
  if (tables.any((b) => {'senc', 'saiz', 'saio'}.contains(b.type))) {
    return null;
  }
  _Box? table(String name) {
    final found = tables.where((b) => b.type == name).toList();
    return found.length == 1 ? found.single : null;
  }

  final stsd = table('stsd');
  final stts = table('stts');
  final stsc = table('stsc');
  final stsz = table('stsz');
  final offsets = table('stco') ?? table('co64');
  if (stsd == null ||
      stts == null ||
      stsc == null ||
      stsz == null ||
      offsets == null) {
    return null;
  }
  if (stsd.data + 16 > stsd.end || _u32(bytes, stsd.data + 4) != 1) {
    return null;
  }
  if (stsd.data + 24 > stsd.end ||
      ByteData.sublistView(bytes).getUint16(stsd.data + 22) != 1) {
    return null;
  }
  final entry = _box(bytes, stsd.data + 8, limit: stsd.end);
  if (entry == null || entry.end != stsd.end) return null;
  final entryType = entry.type;
  if (entryType == 'encv' || entryType == 'enca') return null;
  final durations = await _durations(bytes, stts, checkpoint);
  final sizes = await _sizes(bytes, stsz, checkpoint);
  final composition = table('ctts') == null
      ? null
      : await _compositionOffsets(
          bytes,
          table('ctts')!,
          sizes?.length ?? 0,
          checkpoint,
        );
  if (table('ctts') != null && composition == null) return null;
  final edit = edts == null
      ? null
      : _simpleEdit(bytes, edts, movieScale, scale);
  if (edts != null && edit == null) return null;
  final chunks = await _chunks(bytes, offsets, checkpoint);
  final layout = await _layout(bytes, stsc, checkpoint);
  if (durations == null ||
      sizes == null ||
      chunks == null ||
      layout == null ||
      durations.length != sizes.length ||
      sizes.isEmpty) {
    return null;
  }
  final syncBox = table('stss');
  final sync = syncBox == null
      ? (kind == 'soun' ? null : <int>{})
      : await _sync(bytes, syncBox, checkpoint);
  if (kind == 'vide' && (sync == null || sync.isEmpty)) return null;
  // Remuxing can preserve millisecond-rounded DTS/PTS in a higher-timescale
  // track (for example 16 kHz). Infer that grid from the actual sample tables;
  // the declared clock tick alone is too small. Never bridge a missing frame:
  // rounding tolerance is capped at one millisecond.
  var gridTicks = durations.first;
  for (var i = 0; i < durations.length; i++) {
    // The final duration may be clipped to an arbitrary movie end tick.
    if (i + 1 < durations.length) gridTicks = gridTicks.gcd(durations[i]);
    if (composition != null) gridTicks = gridTicks.gcd(composition[i].abs());
    if (checkpoint != null && i % 256 == 0) await checkpoint();
  }
  final toleranceUs = min(1000, (gridTicks * 1000000 + scale - 1) ~/ scale);
  final samples = <_Sample>[];
  final leadingBytes = <CachedByteRange>[];
  var sample = 0;
  var ticks = 0;
  var layoutIndex = 0;
  for (var chunk = 0; chunk < chunks.length; chunk++) {
    while (layoutIndex + 1 < layout.length &&
        layout[layoutIndex + 1].$1 <= chunk + 1) {
      layoutIndex++;
    }
    final entry = layout[layoutIndex];
    if (checkpoint != null && chunk % 256 == 0) await checkpoint();
    if (entry.$1 > chunk + 1) return null;
    var cursor = chunks[chunk];
    for (var n = 0; n < entry.$2; n++) {
      if (sample >= sizes.length) return null;
      final size = sizes[sample];
      final endByte = cursor + size;
      if (_mdatContaining(mdats, cursor, endByte) == null) {
        return null;
      }
      if (checkpoint != null && sample % 256 == 0) await checkpoint();
      final endTicks = ticks + durations[sample];
      final startTicks = ticks + (composition?[sample] ?? 0);
      final endPresentationTicks = endTicks + (composition?[sample] ?? 0);
      var startUs =
          (startTicks - (edit?.mediaStart ?? 0)) * 1000000 ~/ scale +
          (edit?.timelineOffsetUs ?? 0);
      var endUs =
          (endPresentationTicks - (edit?.mediaStart ?? 0)) * 1000000 ~/ scale +
          (edit?.timelineOffsetUs ?? 0);
      if (edit != null) {
        final editStart = edit.timelineOffsetUs;
        final editEnd = editStart + edit.durationUs;
        if (kind == 'soun') {
          // AAC encoder priming is stored before the edit's audible start.
          // It must be present for the first playable group, but contributes
          // no audible time. Encoder padding after the edit contributes none.
          if (endUs <= editStart || startUs >= editEnd) {
            if (endUs <= editStart) {
              if (leadingBytes.length >= 64 || editStart - startUs > 1000000) {
                return null;
              }
              leadingBytes.add(CachedByteRange(cursor, endByte));
            }
            cursor = endByte;
            ticks = endTicks;
            sample++;
            continue;
          }
          startUs = max(startUs, editStart);
          endUs = min(endUs, editEnd);
        } else if (startUs < editStart || endUs > editEnd) {
          return null;
        }
      }
      if (endUs <= startUs) return null;
      samples.add(
        _Sample(
          startUs,
          endUs,
          cursor,
          endByte,
          kind == 'soun' || sync!.contains(sample + 1),
          toleranceUs: toleranceUs,
        ),
      );
      cursor = endByte;
      ticks = endTicks;
      sample++;
    }
  }
  if (sample != sizes.length) return null;
  return _Track(id, kind, samples, leadingBytes: leadingBytes);
}

Future<List<int>?> _durations(
  Uint8List bytes,
  _Box box,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  if (count > 200000 || box.data + 8 + count * 8 != box.end) return null;
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    final amount = _u32(bytes, box.data + 8 + i * 8);
    final duration = _u32(bytes, box.data + 12 + i * 8);
    if (duration == 0 || amount > 200000 - result.length) return null;
    for (var j = 0; j < amount; j++) {
      result.add(duration);
      if (checkpoint != null && result.length % 256 == 0) {
        await checkpoint();
      }
    }
  }
  return result;
}

Future<List<int>?> _compositionOffsets(
  Uint8List bytes,
  _Box box,
  int samples,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 8 > box.end) return null;
  final version = bytes[box.data];
  if (version != 0 && version != 1) return null;
  final count = _u32(bytes, box.data + 4);
  if (count > 200000 || box.data + 8 + count * 8 != box.end) return null;
  final result = <int>[];
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    final at = box.data + 8 + i * 8;
    final amount = _u32(bytes, at);
    final offset = version == 0 ? _u32(bytes, at + 4) : data.getInt32(at + 4);
    if (amount == 0 || amount > samples - result.length) return null;
    for (var j = 0; j < amount; j++) {
      result.add(offset);
      if (checkpoint != null && result.length % 256 == 0) {
        await checkpoint();
      }
    }
  }
  return result.length == samples ? result : null;
}

int? _movieScale(Uint8List bytes, _Box box) {
  if (box.data + 4 > box.end) return null;
  final version = bytes[box.data];
  if (version != 0 && version != 1) return null;
  final offset = box.data + (version == 1 ? 20 : 12);
  if (offset + 4 > box.end) return null;
  final scale = _u32(bytes, offset);
  return scale > 0 ? scale : null;
}

class _SimpleEdit {
  const _SimpleEdit(this.mediaStart, this.durationUs, this.timelineOffsetUs);
  final int mediaStart;
  final int durationUs;
  final int timelineOffsetUs;
}

/// Accept one ordinary edit, optionally preceded by one empty dwell. Other
/// edit sequences can repeat, crop, or reorder media and remain unknown.
_SimpleEdit? _simpleEdit(
  Uint8List bytes,
  _Box edts,
  int? movieScale,
  int mediaScale,
) {
  if (movieScale == null || mediaScale <= 0) return null;
  final edits = _children(bytes, edts);
  if (edits.length != 1 || edits.single.type != 'elst') return null;
  final box = edits.single;
  if (box.data + 8 > box.end) return null;
  final version = bytes[box.data];
  if (version != 0 && version != 1) return null;
  final count = _u32(bytes, box.data + 4);
  final width = version == 0 ? 12 : 20;
  if (count < 1 || count > 2 || box.data + 8 + count * width != box.end) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  var offsetUs = 0;
  for (var i = 0; i < count; i++) {
    final at = box.data + 8 + i * width;
    final duration = version == 0 ? _u32(bytes, at) : _u64(bytes, at);
    final mediaStart = version == 0
        ? data.getInt32(at + 4)
        : data.getInt64(at + 8);
    final rateAt = at + (version == 0 ? 8 : 16);
    if (duration == 0 ||
        data.getInt16(rateAt) != 1 ||
        data.getInt16(rateAt + 2) != 0) {
      return null;
    }
    final durationUs = duration * 1000000 ~/ movieScale;
    if (durationUs <= 0) return null;
    if (i == 0 && count == 2) {
      if (mediaStart != -1) return null;
      offsetUs = durationUs;
      continue;
    }
    if (mediaStart < 0) return null;
    return _SimpleEdit(mediaStart, durationUs, offsetUs);
  }
  return null;
}

Future<List<int>?> _sizes(
  Uint8List bytes,
  _Box box,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 12 > box.end) return null;
  final fixed = _u32(bytes, box.data + 4);
  final count = _u32(bytes, box.data + 8);
  if (count > 200000 ||
      (fixed == 0 && box.data + 12 + count * 4 != box.end) ||
      (fixed != 0 && box.data + 12 != box.end)) {
    return null;
  }
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    final value = fixed == 0 ? _u32(bytes, box.data + 12 + i * 4) : fixed;
    if (value == 0) return null;
    result.add(value);
    if (checkpoint != null && i % 256 == 0) await checkpoint();
  }
  return result;
}

Future<List<int>?> _chunks(
  Uint8List bytes,
  _Box box,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  final width = box.type == 'co64' ? 8 : 4;
  if (count > 200000 || box.data + 8 + count * width != box.end) return null;
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    result.add(
      box.type == 'co64'
          ? _u64(bytes, box.data + 8 + i * width)
          : _u32(bytes, box.data + 8 + i * width),
    );
    if (checkpoint != null && i % 256 == 0) await checkpoint();
  }
  return result;
}

Future<List<(int, int)>?> _layout(
  Uint8List bytes,
  _Box box,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  if (count == 0 || count > 200000 || box.data + 8 + count * 12 != box.end) {
    return null;
  }
  final result = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    final at = box.data + 8 + i * 12;
    final first = _u32(bytes, at);
    final amount = _u32(bytes, at + 4);
    final description = _u32(bytes, at + 8);
    if (first == 0 ||
        amount == 0 ||
        description != 1 ||
        (result.isNotEmpty && result.last.$1 >= first)) {
      return null;
    }
    result.add((first, amount));
    if (checkpoint != null && i % 256 == 0) await checkpoint();
  }
  return result;
}

Future<Set<int>?> _sync(
  Uint8List bytes,
  _Box box,
  Future<void> Function()? checkpoint,
) async {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  if (count > 200000 || box.data + 8 + count * 4 != box.end) return null;
  final result = <int>{};
  for (var i = 0; i < count; i++) {
    final number = _u32(bytes, box.data + 8 + i * 4);
    if (number == 0 || (result.isNotEmpty && result.last >= number)) {
      return null;
    }
    result.add(number);
    if (checkpoint != null && i % 256 == 0) await checkpoint();
  }
  return result;
}
