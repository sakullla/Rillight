const int kCoreMaxStreamingBitrate = 140000000;

/// Only the verified baseline is advertised, gated by native decoder discovery.
Map<String, dynamic> androidDeviceProfile({
  required bool h264,
  required bool aac,
  int maxStreamingBitrate = 20000000,
}) => {
  'Name': 'Rillight Android owned FFmpeg core',
  'MaxStreamingBitrate': maxStreamingBitrate,
  'MaxStaticBitrate': maxStreamingBitrate,
  'DirectPlayProfiles': [
    if (h264 && aac)
      {
        'Container': 'mp4,m4v,mkv',
        'Type': 'Video',
        'VideoCodec': 'h264',
        'AudioCodec': 'aac',
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
  'CodecProfiles': [
    {
      'Type': 'Video',
      'Codec': 'h264',
      'Conditions': [
        {
          'Condition': 'LessThanEqual',
          'Property': 'VideoBitDepth',
          'Value': '8',
          'IsRequired': true,
        },
        {
          'Condition': 'LessThanEqual',
          'Property': 'Width',
          'Value': '1920',
          'IsRequired': true,
        },
        {
          'Condition': 'LessThanEqual',
          'Property': 'Height',
          'Value': '1080',
          'IsRequired': true,
        },
      ],
    },
    {
      'Type': 'VideoAudio',
      'Codec': 'aac',
      'Conditions': [
        {
          'Condition': 'LessThanEqual',
          'Property': 'AudioChannels',
          'Value': '2',
          'IsRequired': true,
        },
      ],
    },
  ],
  'SubtitleProfiles': [
    for (final format in ['srt', 'subrip', 'vtt', 'webvtt'])
      {'Format': format, 'Method': 'External'},
    for (final format in ['ass', 'ssa', 'pgs', 'pgssub', 'dvdsub', 'dvbsub'])
      {'Format': format, 'Method': 'Encode'},
  ],
};

/// Conservative profile shared by the owned core on desktop and Android.
/// A platform advertises this baseline only when its required decoders exist.
Map<String, dynamic> ownedCoreDeviceProfile({
  required bool h264,
  required bool aac,
  int maxStreamingBitrate = kCoreMaxStreamingBitrate,
}) => {
  ...androidDeviceProfile(
    h264: h264,
    aac: aac,
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
