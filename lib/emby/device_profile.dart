const int kMpvMaxStreamingBitrate = 140000000;

/// Only the verified baseline is advertised, gated by native decoder discovery.
Map<String, dynamic> androidDeviceProfile({
  required bool h264,
  required bool aac,
  int maxStreamingBitrate = 20000000,
}) => {
  'Name': 'Rillight Android Media3',
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

/// Honest libmpv/ffmpeg capabilities. Do not claim Web/HTML5-only formats.
Map<String, dynamic> mpvDeviceProfile({
  int maxStreamingBitrate = kMpvMaxStreamingBitrate,
}) {
  return {
    'MaxStreamingBitrate': maxStreamingBitrate,
    'MaxStaticBitrate': maxStreamingBitrate,
    'MusicStreamingTranscodingBitrate': 192000,
    'DirectPlayProfiles': const [
      {
        'Container': 'mp4,m4v,mov,mkv,webm,ts',
        'Type': 'Video',
        'VideoCodec': 'h264,hevc,av1,vp9',
        'AudioCodec': 'aac,mp3,ac3,eac3,flac,opus,dts',
      },
      {'Container': 'mp3,aac,flac,opus,wav,ogg', 'Type': 'Audio'},
    ],
    'TranscodingProfiles': const [
      {
        'Container': 'ts',
        'Type': 'Video',
        'AudioCodec': 'aac',
        'VideoCodec': 'h264',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'MaxAudioChannels': '6',
        'MinSegments': '1',
        'BreakOnNonKeyFrames': true,
        'ManifestSubtitles': 'vtt',
      },
    ],
    'ContainerProfiles': <Map<String, dynamic>>[],
    'CodecProfiles': <Map<String, dynamic>>[],
    'SubtitleProfiles': const [
      {'Format': 'srt', 'Method': 'External'},
      {'Format': 'subrip', 'Method': 'External'},
      {'Format': 'vtt', 'Method': 'External'},
      {'Format': 'webvtt', 'Method': 'External'},
      {'Format': 'ass', 'Method': 'External'},
      {'Format': 'ssa', 'Method': 'External'},
      // mpv 可直接渲染容器内嵌 PGS 位图轨道:按文档枚举值声明 Embed
      // (SubtitleDeliveryMethod: External/Embed/Encode),直连场景服务端
      // 不强制烧录;转码时服务端仍按能力烧录。
      {'Format': 'pgs', 'Method': 'Embed'},
      {'Format': 'pgssub', 'Method': 'Embed'},
      {'Format': 'dvdsub', 'Method': 'Encode'},
      {'Format': 'dvbsub', 'Method': 'Encode'},
    ],
  };
}

const List<int> kTranscodeBitrates = [
  kMpvMaxStreamingBitrate,
  20000000,
  8000000,
  4000000,
  2000000,
  1000000,
];
