import 'dart:convert';
import 'dart:typed_data';

/// A tiny valid BMFF sample table with two 2-second video GOPs and a selected
/// audio track. Byte layout: ftyp [0,20), mdat header [20,28), video [28,36),
/// audio [36,44), moov [44,end). It contains no encoded media and must only
/// be used for cache-index/proxy tests, not actual decode tests.
Uint8List progressiveMp4Fixture() {
  final ftyp = _box('ftyp', [
    ...ascii.encode('isom'),
    ..._u32(0),
    ...ascii.encode('isom'),
  ]);
  final mdat = _box('mdat', List.generate(16, (i) => i));

  List<int> track(int id, String kind, int chunkOffset) {
    final tkhd = _box('tkhd', [...List.filled(12, 0), ..._u32(id)]);
    final mdhd = _box('mdhd', [...List.filled(12, 0), ..._u32(1000)]);
    final hdlr = _box('hdlr', [...List.filled(8, 0), ...ascii.encode(kind)]);
    final dinf = _dataReference();
    final stsd = _sampleDescription(kind);
    final stts = _box('stts', [
      ...List.filled(4, 0),
      ..._u32(1),
      ..._u32(4),
      ..._u32(1000),
    ]);
    final stsc = _box('stsc', [
      ...List.filled(4, 0),
      ..._u32(1),
      ..._u32(1),
      ..._u32(4),
      ..._u32(1),
    ]);
    final stsz = _box('stsz', [...List.filled(4, 0), ..._u32(2), ..._u32(4)]);
    final stco = _box('stco', [
      ...List.filled(4, 0),
      ..._u32(1),
      ..._u32(chunkOffset),
    ]);
    final stss = kind == 'vide'
        ? _box('stss', [
            ...List.filled(4, 0),
            ..._u32(2),
            ..._u32(1),
            ..._u32(3),
          ])
        : <int>[];
    final stbl = _box('stbl', [
      ...stsd,
      ...stts,
      ...stsc,
      ...stsz,
      ...stco,
      ...stss,
    ]);
    final minf = _box('minf', [...dinf, ...stbl]);
    return _box('trak', [
      ...tkhd,
      ..._box('mdia', [...mdhd, ...hdlr, ...minf]),
    ]);
  }

  final moov = _box('moov', [...track(1, 'vide', 28), ...track(2, 'soun', 36)]);
  return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
}

class FragmentedMp4Fixture {
  const FragmentedMp4Fixture({
    required this.bytes,
    required this.firstMoofStart,
    required this.firstMdatStart,
    required this.firstFragmentEnd,
  });

  final Uint8List bytes;
  final int firstMoofStart;
  final int firstMdatStart;
  final int firstFragmentEnd;
}

FragmentedMp4Fixture fragmentedMp4Fixture({
  bool videoStartsWithSync = true,
  bool includeVideo = true,
  bool includeAudio = true,
}) {
  if (!includeVideo && !includeAudio) {
    throw ArgumentError('At least one track is required');
  }
  final ftyp = _box('ftyp', [
    ...ascii.encode('iso6'),
    ..._u32(0),
    ...ascii.encode('iso6'),
  ]);
  List<int> track(int id, String kind) {
    final tkhd = _box('tkhd', [...List.filled(12, 0), ..._u32(id)]);
    final mdhd = _box('mdhd', [...List.filled(12, 0), ..._u32(1000)]);
    final hdlr = _box('hdlr', [...List.filled(8, 0), ...ascii.encode(kind)]);
    final stbl = _box('stbl', _sampleDescription(kind));
    final minf = _box('minf', [..._dataReference(), ...stbl]);
    return _box('trak', [
      ...tkhd,
      ..._box('mdia', [...mdhd, ...hdlr, ...minf]),
    ]);
  }

  List<int> trex(int id) => _box('trex', [
    ...List.filled(4, 0),
    ..._u32(id),
    ..._u32(1),
    ..._u32(1000),
    ..._u32(2),
    ..._u32(0x01010000),
  ]);
  final moov = _box('moov', [
    if (includeVideo) ...track(1, 'vide'),
    if (includeAudio) ...track(2, 'soun'),
    ..._box('mvex', [
      if (includeVideo) ...trex(1),
      if (includeAudio) ...trex(2),
    ]),
  ]);

  List<int> fragment(int baseTime) {
    List<int> traf(int id, int dataOffset) {
      final tfhd = _box('tfhd', [..._u32(0x020000), ..._u32(id)]);
      final tfdt = _box('tfdt', [..._u32(0), ..._u32(baseTime)]);
      final trun = _box('trun', [
        ..._u32(0x701),
        ..._u32(2),
        ..._u32(dataOffset),
        ..._u32(1000),
        ..._u32(2),
        ..._u32(id == 1 && videoStartsWithSync ? 0x02000000 : 0x01010000),
        ..._u32(1000),
        ..._u32(2),
        ..._u32(id == 1 ? 0x01010000 : 0),
      ]);
      return _box('traf', [...tfhd, ...tfdt, ...trun]);
    }

    List<int> moof(int videoOffset, int audioOffset) => _box('moof', [
      if (includeVideo) ...traf(1, videoOffset),
      if (includeAudio) ...traf(2, audioOffset),
    ]);
    final provisional = moof(0, 0);
    final actualMoof = moof(
      provisional.length + 8,
      provisional.length + 8 + (includeVideo ? 4 : 0),
    );
    final mdat = _box(
      'mdat',
      List.generate(
        (includeVideo ? 4 : 0) + (includeAudio ? 4 : 0),
        (i) => i + baseTime,
      ),
    );
    return [...actualMoof, ...mdat];
  }

  final first = fragment(0);
  final second = fragment(2000);
  final firstMoofStart = ftyp.length + moov.length;
  final firstMdatStart =
      firstMoofStart +
      first.length -
      (includeVideo ? 4 : 0) -
      (includeAudio ? 4 : 0) -
      8;
  final firstFragmentEnd = firstMoofStart + first.length;
  return FragmentedMp4Fixture(
    bytes: Uint8List.fromList([...ftyp, ...moov, ...first, ...second]),
    firstMoofStart: firstMoofStart,
    firstMdatStart: firstMdatStart,
    firstFragmentEnd: firstFragmentEnd,
  );
}

List<int> _sampleDescription(String kind) {
  final entry = _box(kind == 'vide' ? 'avc1' : 'mp4a', [
    ...List.filled(6, 0),
    0,
    1,
  ]);
  return _box('stsd', [...List.filled(4, 0), ..._u32(1), ...entry]);
}

List<int> _dataReference() {
  final dref = _box('dref', [
    ...List.filled(4, 0),
    ..._u32(1),
    ..._box('url ', [0, 0, 0, 1]),
  ]);
  return _box('dinf', dref);
}

List<int> _box(String type, List<int> payload) => [
  ..._u32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
];

List<int> _u32(int value) => [
  (value >> 24) & 255,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];
