const int kCoreMaxStreamingBitrate = 140000000;

/// Codecs are advertised only when the caller has probed the owned core.
/// Direct play is not limited to 8-bit, 1080p, or two audio channels.
Map<String, dynamic> androidDeviceProfile({
  required bool h264,
  required bool aac,
  bool hevc = false,
  bool ac3 = false,
  bool eac3 = false,
  bool truehd = false,
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
  ];
  return {
    'Name': 'Rillight Android owned FFmpeg core',
    'MaxStreamingBitrate': maxStreamingBitrate,
    'MaxStaticBitrate': maxStreamingBitrate,
    'DirectPlayProfiles': [
      if (video.isNotEmpty && audio.isNotEmpty)
        {
          'Container': 'mp4,m4v,mkv',
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
      {'Format': 'ass', 'Method': ass ? 'Embed' : 'Encode'},
      {'Format': 'ssa', 'Method': ssa ? 'Embed' : 'Encode'},
      for (final format in ['pgs', 'pgssub', 'dvdsub', 'dvbsub'])
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
    ass: ass,
    ssa: ssa,
    maxStreamingBitrate: maxStreamingBitrate,
  ),
  'Name': 'Rillight owned FFmpeg core',
};

const List<int> kTranscodeBitrates = [
  kCoreMaxStreamingBitrate,
  20000000,
  8000000,
  4000000,
  2000000,
  1000000,
];
