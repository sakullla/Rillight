import 'package:rillight/media_server/playback.dart';
export 'package:rillight/media_server/playback.dart'
    show kCoreMaxStreamingBitrate, kTranscodeBitrates;

/// Codecs are advertised only when the caller has probed the owned core.
/// Direct play is not limited to 8-bit, 1080p, or two audio channels.
Map<String, dynamic> androidDeviceProfile({
  required bool h264,
  required bool aac,
  bool hevc = false,
  bool ac3 = false,
  bool eac3 = false,
  bool truehd = false,
  bool dts = false,
  bool pgs = false,
  bool ass = false,
  bool ssa = false,
  int maxStreamingBitrate = 20000000,
}) {
  final video = [if (h264) 'h264', if (hevc) 'hevc'];
  final audio = [
    if (aac) 'aac',
    if (ac3) 'ac3',
    if (eac3) 'eac3',
    if (truehd) 'truehd',
    if (dts) 'dts',
  ];
  return {
    'Name': 'Rillight Android owned FFmpeg core',
    'MaxStreamingBitrate': maxStreamingBitrate,
    'MaxStaticBitrate': maxStreamingBitrate,
    'DirectPlayProfiles': [
      if (video.isNotEmpty && audio.isNotEmpty)
        {
          // hls/ts are opened by the owned core. Without them the server
          // transcodes an HLS source into another HLS playlist.
          'Container': 'mp4,m4v,mkv,hls,m3u8,ts,mpegts',
          'Type': 'Video',
          'VideoCodec': video.join(','),
          'AudioCodec': audio.join(','),
        },
    ],
    'TranscodingProfiles': [
      if (h264 && aac)
        {
          'Container': 'ts',
          'Type': 'Video',
          'VideoCodec': 'h264',
          'AudioCodec': 'aac',
          'Protocol': 'hls',
          'Context': 'Streaming',
          'MaxAudioChannels': '2',
          'ManifestSubtitles': 'vtt',
          'MinSegments': '1',
        },
    ],
    'SubtitleProfiles': [
      for (final format in ['srt', 'subrip', 'vtt', 'webvtt'])
        {'Format': format, 'Method': 'External'},
      // The owned core renders these locally with libass. Advertising Encode
      // for a verified decoder forces otherwise direct MKV playback through
      // server-side video transcoding merely because an ASS track is selected.
      // External ASS/SSA is downloaded separately and loaded into the same
      // renderer. Embed alone does not cover a server-selected sidecar track.
      if (ass) {'Format': 'ass', 'Method': 'External'},
      if (ssa) {'Format': 'ssa', 'Method': 'External'},
      {'Format': 'ass', 'Method': ass ? 'Embed' : 'Encode'},
      {'Format': 'ssa', 'Method': ssa ? 'Embed' : 'Encode'},
      // The owned core composites decoded PGS bitmaps locally. Keep burn-in
      // only when that decoder is absent from the loaded native library.
      for (final format in ['pgs', 'pgssub'])
        {'Format': format, 'Method': pgs ? 'Embed' : 'Encode'},
      for (final format in ['dvdsub', 'dvbsub'])
        {'Format': format, 'Method': 'Encode'},
    ],
  };
}

/// Conservative profile shared by the owned core on desktop and Android.
/// A platform advertises this baseline only when its required decoders exist.
Map<String, dynamic> ownedCoreDeviceProfile({
  required bool h264,
  required bool aac,
  bool hevc = false,
  bool ac3 = false,
  bool eac3 = false,
  bool truehd = false,
  bool dts = false,
  bool pgs = false,
  bool ass = false,
  bool ssa = false,
  int maxStreamingBitrate = kCoreMaxStreamingBitrate,
}) => {
  ...androidDeviceProfile(
    h264: h264,
    aac: aac,
    hevc: hevc,
    ac3: ac3,
    eac3: eac3,
    truehd: truehd,
    dts: dts,
    pgs: pgs,
    ass: ass,
    ssa: ssa,
    maxStreamingBitrate: maxStreamingBitrate,
  ),
  'Name': 'Rillight owned FFmpeg core',
};

Map<String, dynamic> encodeEmbyDeviceProfile(
  PlaybackCapabilities capabilities,
) => ownedCoreDeviceProfile(
  h264: capabilities.h264,
  aac: capabilities.aac,
  hevc: capabilities.hevc,
  ac3: capabilities.ac3,
  eac3: capabilities.eac3,
  truehd: capabilities.truehd,
  dts: capabilities.dts,
  pgs: capabilities.pgs,
  ass: capabilities.ass,
  ssa: capabilities.ssa,
  maxStreamingBitrate: capabilities.maxStreamingBitrate,
);
