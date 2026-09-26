import 'dart:math';
import 'dart:typed_data';

import 'matroska_cache_index.dart';

/// A deliberately bounded ISO BMFF index. Only files whose selected tracks
/// have complete, non-reordered sample tables are accepted. A missing table,
/// edit list, encryption, external data reference, or unsupported fragment
/// leaves the cache timeline unknown instead of estimating it from bitrate.
class Mp4CacheIndex {
  Mp4CacheIndex._(this._units, this.total);

  final List<_PlayableUnit> _units;
  final int total;

  static Future<Mp4CacheIndex?> load({
    required int total,
    required Future<Uint8List?> Function(int offset, int length) read,
    int? selectedVideoTrackId,
    int? selectedAudioTrackId,
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
        );
      }
      if (top.any((box) => box.type == 'moof')) return null;
      final tracks = <_Track>[];
      for (final box in children.where((box) => box.type == 'trak')) {
        final track = _track(data, box, mdats);
        if (track == null) return null;
        if (track.kind == 'vide' || track.kind == 'soun') tracks.add(track);
      }
      final video = _selected(tracks, 'vide', selectedVideoTrackId);
      final audio = _selected(tracks, 'soun', selectedAudioTrackId);
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
      final primary = video ?? audio!;
      final starts = <int>[
        for (var i = 0; i < primary.samples.length; i++)
          if (primary.samples[i].sync) i,
      ];
      if (starts.isEmpty || starts.first != 0) return null;
      final metadata = <CachedByteRange>[
        CachedByteRange(moov.start, moov.end),
        for (final box in top.where((box) => box.type == 'ftyp'))
          CachedByteRange(box.start, box.end),
        for (final box in mdats) CachedByteRange(box.start, box.data),
      ];
      final units = <_PlayableUnit>[];
      for (var group = 0; group < starts.length; group++) {
        final from = starts[group];
        final to = group + 1 < starts.length
            ? starts[group + 1]
            : primary.samples.length;
        final segment = primary.samples.sublist(from, to);
        if (!_continuous(segment)) continue;
        final begin = segment.first.startUs;
        final end = segment.last.endUs;
        final required = <CachedByteRange>[
          ...metadata,
          for (final sample in segment)
            CachedByteRange(sample.byteStart, sample.byteEnd),
        ];
        if (video != null && audio != null) {
          final matching = audio.samples
              .where((sample) => sample.endUs > begin && sample.startUs < end)
              .toList();
          if (matching.isEmpty ||
              matching.first.startUs > begin ||
              matching.last.endUs < end ||
              !_continuous(matching)) {
            continue;
          }
          required.addAll([
            for (final sample in matching)
              CachedByteRange(sample.byteStart, sample.byteEnd),
          ]);
        }
        units.add(_PlayableUnit(begin, end, required));
      }
      if (units.isEmpty) return null;
      return Mp4CacheIndex._(units, total);
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
      final start = Duration(microseconds: unit.startUs);
      final end = Duration(microseconds: unit.endUs);
      if (result.isNotEmpty && result.last.end == start) {
        final previous = result.removeLast();
        result.add(CachedTimeRange(previous.start, end));
      } else {
        result.add(CachedTimeRange(start, end));
      }
    }
    return result;
  }
}

class _PlayableUnit {
  const _PlayableUnit(this.startUs, this.endUs, this.required);
  final int startUs;
  final int endUs;
  final List<CachedByteRange> required;
}

class _Sample {
  const _Sample(
    this.startUs,
    this.endUs,
    this.byteStart,
    this.byteEnd,
    this.sync,
  );
  final int startUs;
  final int endUs;
  final int byteStart;
  final int byteEnd;
  final bool sync;
}

class _Track {
  const _Track(this.id, this.kind, this.samples);
  final int id;
  final String kind;
  final List<_Sample> samples;
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
  for (final moof in top.where((box) => box.type == 'moof')) {
    if (moof.end - moof.start > 8 * 1024 * 1024) return null;
    final bytes = await read(moof.start, moof.end - moof.start);
    if (bytes == null || bytes.length != moof.end - moof.start) return null;
    final root = _box(bytes, 0, limit: bytes.length);
    if (root == null || root.end != bytes.length) return null;
    for (final traf in _children(
      bytes,
      root,
    ).where((box) => box.type == 'traf')) {
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
      fragments.add(parsed);
    }
  }
  if (fragments.isEmpty) return null;
  final primaryId = (video ?? audio!).id;
  final primary = fragments.where((fragment) => fragment.trackId == primaryId);
  final audioFragments = audio == null
      ? <_FragmentSamples>[]
      : fragments.where((fragment) => fragment.trackId == audio.id).toList();
  final init = <CachedByteRange>[
    CachedByteRange(moov.start, moov.end),
    for (final box in top.where((box) => box.type == 'ftyp'))
      CachedByteRange(box.start, box.end),
  ];
  final units = <_PlayableUnit>[];
  for (final fragment in primary) {
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
      final matchingFragments = audioFragments
          .where(
            (part) =>
                part.samples.isNotEmpty &&
                part.samples.last.endUs > begin &&
                part.samples.first.startUs < end,
          )
          .toList();
      final matching = [
        for (final part in matchingFragments)
          ...part.samples.where(
            (sample) => sample.endUs > begin && sample.startUs < end,
          ),
      ]..sort((a, b) => a.startUs.compareTo(b.startUs));
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
    }
    units.add(_PlayableUnit(begin, end, required));
  }
  units.sort((a, b) => a.startUs.compareTo(b.startUs));
  for (var i = 1; i < units.length; i++) {
    if (units[i].startUs < units[i - 1].endUs) return null;
  }
  if (units.isEmpty) return null;
  return Mp4CacheIndex._(units, total);
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
  if (count == 0 || count > 200000) return null;
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
    final containing = mdats.where(
      (mdat) => byteOffset >= mdat.data && endByte <= mdat.end,
    );
    if (containing.length != 1) return null;
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
  final headers = <CachedByteRange>[
    CachedByteRange(moof.start, moof.end),
    for (final mdat in mdats.where(
      (mdat) => samples.any(
        (sample) => sample.byteStart >= mdat.data && sample.byteEnd <= mdat.end,
      ),
    ))
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

bool _contains(List<CachedByteRange> available, CachedByteRange need) =>
    available.any(
      (range) => range.start <= need.start && range.end >= need.end,
    );

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
    if (result.length > 65536) throw const FormatException('Too many boxes');
  }
  return result;
}

_Box? _child(Uint8List bytes, _Box parent, String type) {
  for (final box in _children(bytes, parent)) {
    if (box.type == type) return box;
  }
  return null;
}

_Track? _track(Uint8List bytes, _Box box, List<_Box> mdats) {
  if (_child(bytes, box, 'edts') != null) return null;
  final tkhd = _child(bytes, box, 'tkhd');
  final mdia = _child(bytes, box, 'mdia');
  if (tkhd == null || mdia == null) return null;
  final version = bytes[tkhd.data];
  if (version != 0 && version != 1) return null;
  final idOffset = tkhd.data + (version == 1 ? 20 : 12);
  if (idOffset + 4 > tkhd.end) return null;
  final id = _u32(bytes, idOffset);
  final hdlr = _child(bytes, mdia, 'hdlr');
  final mdhd = _child(bytes, mdia, 'mdhd');
  final minf = _child(bytes, mdia, 'minf');
  if (hdlr == null || mdhd == null || minf == null) return null;
  if (hdlr.data + 12 > hdlr.end) return null;
  final kind = _type(bytes, hdlr.data + 8);
  if (kind != 'vide' && kind != 'soun') return _Track(id, kind, const []);
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
  if (tables.any((b) => {'ctts', 'senc', 'saiz', 'saio'}.contains(b.type))) {
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
  final durations = _durations(bytes, stts);
  final sizes = _sizes(bytes, stsz);
  final chunks = _chunks(bytes, offsets);
  final layout = _layout(bytes, stsc);
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
      : _sync(bytes, syncBox);
  if (kind == 'vide' && (sync == null || sync.isEmpty)) return null;
  final samples = <_Sample>[];
  var sample = 0;
  var ticks = 0;
  for (var chunk = 0; chunk < chunks.length; chunk++) {
    final entry = layout.lastWhere(
      (item) => item.$1 <= chunk + 1,
      orElse: () => (0, 0),
    );
    if (entry.$1 == 0) return null;
    var cursor = chunks[chunk];
    for (var n = 0; n < entry.$2; n++) {
      if (sample >= sizes.length) return null;
      final size = sizes[sample];
      final endByte = cursor + size;
      if (!mdats.any((m) => cursor >= m.data && endByte <= m.end)) {
        return null;
      }
      final endTicks = ticks + durations[sample];
      final startUs = ticks * 1000000 ~/ scale;
      final endUs = endTicks * 1000000 ~/ scale;
      if (endUs <= startUs) return null;
      samples.add(
        _Sample(
          startUs,
          endUs,
          cursor,
          endByte,
          kind == 'soun' || sync!.contains(sample + 1),
        ),
      );
      cursor = endByte;
      ticks = endTicks;
      sample++;
    }
  }
  if (sample != sizes.length) return null;
  return _Track(id, kind, samples);
}

List<int>? _durations(Uint8List bytes, _Box box) {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  if (count > 200000 || box.data + 8 + count * 8 != box.end) return null;
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    final amount = _u32(bytes, box.data + 8 + i * 8);
    final duration = _u32(bytes, box.data + 12 + i * 8);
    if (duration == 0 || amount > 200000 - result.length) return null;
    result.addAll(List.filled(amount, duration));
  }
  return result;
}

List<int>? _sizes(Uint8List bytes, _Box box) {
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
  }
  return result;
}

List<int>? _chunks(Uint8List bytes, _Box box) {
  if (box.data + 8 > box.end) return null;
  final count = _u32(bytes, box.data + 4);
  final width = box.type == 'co64' ? 8 : 4;
  if (count > 200000 || box.data + 8 + count * width != box.end) return null;
  return [
    for (var i = 0; i < count; i++)
      box.type == 'co64'
          ? _u64(bytes, box.data + 8 + i * width)
          : _u32(bytes, box.data + 8 + i * width),
  ];
}

List<(int, int)>? _layout(Uint8List bytes, _Box box) {
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
  }
  return result;
}

Set<int>? _sync(Uint8List bytes, _Box box) {
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
  }
  return result;
}
