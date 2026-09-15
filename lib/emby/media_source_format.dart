/// 片源菜单展示:第一行是分辨率/HDR/编码/音轨,第二行是来源组、体积与码率。
///
/// Emby 的 MediaSource.Name 在多版本库里经常是场景文件名
/// (`2160p.BILI.WD.265.AAC-SonyHD`),单独展示几乎无法比较。Infuse / Jellyfin
/// DisplayTitle / Plex Versions 都把技术规格拆开,文件名只保留区分用的组名。
class MediaSourceView {
  const MediaSourceView({
    required this.headline,
    this.detail,
    required this.compact,
  });

  /// 选择时最先看的规格,如 `4K HDR · H.265 · AAC`。
  final String headline;

  /// 来源组、体积、码率等补充,如 `BILI · WEB-DL · SonyHD · 12.4 GB`。
  final String? detail;

  /// 按钮/溢出菜单回显,短标签。
  final String compact;
}

MediaSourceView formatMediaSource({
  String? name,
  String? container,
  int? sizeBytes,
  int? bitrate,
  int? width,
  int? height,
  String? videoCodec,
  String? videoRange,
  String? videoRangeType,
  String? audioCodec,
  int? audioChannels,
  String? audioTitle,
}) {
  final rawName = name?.trim() ?? '';
  final parsed = _parseReleaseName(rawName);
  final resolution =
      _resolutionLabel(height: height, width: width) ?? parsed.resolution;
  final hdr =
      _hdrLabel(range: videoRange, rangeType: videoRangeType) ?? parsed.hdr;
  final video = _videoCodecLabel(videoCodec) ?? parsed.videoCodec;
  final audio =
      _audioLabel(
        codec: audioCodec,
        channels: audioChannels,
        title: audioTitle,
      ) ??
      parsed.audio;
  final quality = [?resolution, ?hdr].join(' ');
  final headlineParts = <String>[
    if (quality.isNotEmpty) quality,
    ?video,
    ?audio,
  ];
  final headline = headlineParts.isEmpty
      ? (rawName.isEmpty ? '—' : rawName)
      : headlineParts.join(' · ');

  final edition = _editionLabel(rawName, parsed.leftover);
  final stats = <String>[
    ?edition,
    if (edition == null && container != null && container.trim().isNotEmpty)
      container.trim().toUpperCase(),
    ?_sizeLabel(sizeBytes),
    ?_bitrateLabel(bitrate),
  ];
  final detail = stats.isEmpty ? null : stats.join(' · ');
  final uniqueDetail = detail == headline ? null : detail;
  final compact = _compactLabel(
    name: rawName,
    resolution: resolution,
    hdr: hdr,
    video: video,
    headline: headline,
  );
  return MediaSourceView(
    headline: headline,
    detail: uniqueDetail,
    compact: compact,
  );
}

String _compactLabel({
  required String name,
  required String? resolution,
  required String? hdr,
  required String? video,
  required String headline,
}) {
  if (name.isNotEmpty &&
      name.length <= 12 &&
      _cjk.hasMatch(name) &&
      !name.contains('.')) {
    return name;
  }
  final short = <String>[?resolution, ?hdr, if (hdr == null) ?video];
  if (short.isNotEmpty) {
    return short.join(' ');
  }
  if (name.isNotEmpty && name.length <= 12) {
    return name;
  }
  return headline;
}

String? _editionLabel(String name, List<String> leftover) {
  if (name.isEmpty) {
    return null;
  }
  if (_cjk.hasMatch(name) && !name.contains('.')) {
    return name;
  }
  if (leftover.isEmpty) {
    return null;
  }
  return leftover.join(' · ');
}

String? _resolutionLabel({int? height, int? width}) {
  final h = height ?? 0;
  final w = width ?? 0;
  if (h >= 2160 || w >= 3840) {
    return '4K';
  }
  if (h >= 1440 || w >= 2560) {
    return '1440p';
  }
  if (h >= 1080 || w >= 1920) {
    return '1080p';
  }
  if (h >= 720 || w >= 1280) {
    return '720p';
  }
  return null;
}

String? _hdrLabel({String? range, String? rangeType}) {
  final blob = '${rangeType ?? ''} ${range ?? ''}'.toLowerCase();
  if (blob.contains('dolby') || blob.contains('dovi')) {
    return '杜比视界';
  }
  if (blob.contains('hdr10+') || blob.contains('hdr10plus')) {
    return 'HDR10+';
  }
  if (blob.contains('hdr')) {
    return 'HDR';
  }
  return null;
}

String? _videoCodecLabel(String? codec) {
  final value = codec?.trim().toLowerCase();
  if (value == null || value.isEmpty) {
    return null;
  }
  if (value.contains('hevc') ||
      value.contains('h265') ||
      value.contains('h.265') ||
      value == 'x265') {
    return 'H.265';
  }
  if (value.contains('av1')) {
    return 'AV1';
  }
  if (value.contains('vp9')) {
    return 'VP9';
  }
  if (value.contains('avc') ||
      value.contains('h264') ||
      value.contains('h.264') ||
      value == 'x264') {
    return 'H.264';
  }
  if (value.contains('mpeg2')) {
    return 'MPEG-2';
  }
  return codec!.toUpperCase();
}

String? _audioLabel({String? codec, int? channels, String? title}) {
  final blob = '${codec ?? ''} ${title ?? ''}'.toLowerCase();
  if (blob.trim().isEmpty) {
    return null;
  }
  String? name;
  if (blob.contains('atmos')) {
    name = 'Atmos';
  } else if (blob.contains('truehd')) {
    name = 'TrueHD';
  } else if (blob.contains('dts')) {
    name = 'DTS';
  } else if (blob.contains('eac3') ||
      blob.contains('ec-3') ||
      blob.contains('ddp') ||
      blob.contains('dd+')) {
    name = 'E-AC3';
  } else if (blob.contains('ac3') || blob.contains('ac-3') || blob == 'dd') {
    name = 'AC3';
  } else if (blob.contains('flac')) {
    name = 'FLAC';
  } else if (blob.contains('aac') || blob.contains('mp4a')) {
    name = 'AAC';
  } else if (blob.contains('opus')) {
    name = 'Opus';
  } else if (blob.contains('pcm')) {
    name = 'PCM';
  } else if (codec != null && codec.trim().isNotEmpty) {
    name = codec.trim().toUpperCase();
  }
  if (name == null) {
    return null;
  }
  if (name == 'Atmos') {
    return name;
  }
  final layout = _channelLayout(channels);
  if (layout == null) {
    return name;
  }
  return '$name $layout';
}

String? _channelLayout(int? channels) {
  if (channels == null || channels <= 0) {
    return null;
  }
  if (channels >= 8) {
    return '7.1';
  }
  if (channels >= 6) {
    return '5.1';
  }
  if (channels == 2) {
    return '2.0';
  }
  return null;
}

String? _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return null;
  }
  const gb = 1000 * 1000 * 1000;
  const mb = 1000 * 1000;
  if (bytes >= gb) {
    final value = bytes / gb;
    final digits = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} GB';
  }
  if (bytes >= mb) {
    return '${(bytes / mb).round()} MB';
  }
  return null;
}

String? _bitrateLabel(int? bitrate) {
  if (bitrate == null || bitrate <= 0) {
    return null;
  }
  final mbps = bitrate / 1000000;
  if (mbps >= 1) {
    final digits = mbps >= 10 ? 0 : 1;
    return '${mbps.toStringAsFixed(digits)} Mbps';
  }
  return '${(bitrate / 1000).round()} kbps';
}

final _cjk = RegExp(r'[\u4e00-\u9fff]');

class _ParsedRelease {
  const _ParsedRelease({
    this.resolution,
    this.hdr,
    this.videoCodec,
    this.audio,
    this.leftover = const [],
  });

  final String? resolution;
  final String? hdr;
  final String? videoCodec;
  final String? audio;
  final List<String> leftover;
}

_ParsedRelease _parseReleaseName(String name) {
  if (name.isEmpty) {
    return const _ParsedRelease();
  }
  final tokens = name
      .split(RegExp(r'[.\s_\-]+'))
      .map((token) => token.trim())
      .where((token) => token.isNotEmpty)
      .toList();
  String? resolution;
  String? hdr;
  String? video;
  String? audio;
  final leftover = <String>[];
  for (final token in tokens) {
    final mappedRes = _tokenResolution(token);
    if (mappedRes != null) {
      resolution ??= mappedRes;
      continue;
    }
    final mappedHdr = _tokenHdr(token);
    if (mappedHdr != null) {
      if (mappedHdr.isEmpty) {
        continue;
      }
      hdr ??= mappedHdr;
      continue;
    }
    final mappedVideo = _tokenVideo(token);
    if (mappedVideo != null) {
      video ??= mappedVideo;
      continue;
    }
    final mappedAudio = _tokenAudio(token);
    if (mappedAudio != null) {
      audio ??= mappedAudio;
      continue;
    }
    leftover.add(_prettyGroup(token));
  }
  return _ParsedRelease(
    resolution: resolution,
    hdr: hdr,
    videoCodec: video,
    audio: audio,
    leftover: leftover,
  );
}

String? _tokenResolution(String token) {
  final value = token.toLowerCase();
  if (value == '2160p' || value == '2160' || value == '4k' || value == 'uhd') {
    return '4K';
  }
  if (value == '1440p' || value == '1440') {
    return '1440p';
  }
  if (value == '1080p' || value == '1080' || value == 'fhd') {
    return '1080p';
  }
  if (value == '720p' || value == '720') {
    return '720p';
  }
  return null;
}

/// 空字符串表示识别到但应丢弃(SDR),不进入 leftover。
String? _tokenHdr(String token) {
  final value = token.toLowerCase();
  if (value == 'sdr') {
    return '';
  }
  if (value == 'dovi' || value == 'dv' || value == 'dolbyvision') {
    return '杜比视界';
  }
  if (value == 'hdr10+' || value == 'hdr10plus') {
    return 'HDR10+';
  }
  if (value == 'hdr' || value == 'hdr10' || value == 'hlg') {
    return 'HDR';
  }
  return null;
}

String? _tokenVideo(String token) {
  final value = token.toLowerCase();
  if (value == '265' ||
      value == 'h265' ||
      value == 'hevc' ||
      value == 'x265' ||
      value == 'h.265') {
    return 'H.265';
  }
  if (value == '264' ||
      value == 'h264' ||
      value == 'avc' ||
      value == 'x264' ||
      value == 'h.264') {
    return 'H.264';
  }
  if (value == 'av1') {
    return 'AV1';
  }
  if (value == 'vp9') {
    return 'VP9';
  }
  return null;
}

String? _tokenAudio(String token) {
  final value = token.toLowerCase();
  if (value == 'aac') {
    return 'AAC';
  }
  if (value == 'flac') {
    return 'FLAC';
  }
  if (value == 'atmos') {
    return 'Atmos';
  }
  if (value == 'truehd' || value == 'true-hd') {
    return 'TrueHD';
  }
  if (value == 'dts' || value == 'dtsma' || value == 'dts-hd') {
    return 'DTS';
  }
  if (value == 'eac3' || value == 'ddp' || value == 'dd+' || value == 'ec3') {
    return 'E-AC3';
  }
  if (value == 'ac3' || value == 'dd') {
    return 'AC3';
  }
  return null;
}

String _prettyGroup(String token) {
  final value = token.toUpperCase();
  if (value == 'WD' ||
      value == 'WEB' ||
      value == 'WEBDL' ||
      value == 'WEB-DL') {
    return 'WEB-DL';
  }
  if (value == 'WEBRip' || value == 'WEBRIP') {
    return 'WEBRip';
  }
  if (value == 'BLURAY' || value == 'BLU-RAY' || value == 'BD') {
    return 'BluRay';
  }
  if (value == 'REMUX') {
    return 'REMUX';
  }
  return token;
}
