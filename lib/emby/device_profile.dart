const int kMpvMaxStreamingBitrate = 140000000;

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
