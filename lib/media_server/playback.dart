import 'resources.dart';

import 'package:rillight/media_server/media_source_format.dart';

enum PlayMethod {
  directPlay,
  directStream,
  transcode;

  bool get isDirect => this != PlayMethod.transcode;
}

enum SubtitleRenderKind { text, bitmap }

class MediaStreamInfo {
  const MediaStreamInfo({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.displayTitle,
    this.isDefault = false,
    this.isExternal = false,
    this.isTextSubtitleStream,
    this.deliveryMethod,
    this.deliveryUrl,
    this.playbackIndex,
    this.channels,
    this.width,
    this.height,
    this.bitRate,
    this.videoRange,
    this.videoRangeType,
  });

  final int index;
  final String type;
  final String? codec;
  final String? language;
  final String? displayTitle;
  final bool isDefault;

  /// 服务器标记的外挂字幕文件。缺省按容器内嵌处理。
  final bool isExternal;
  final bool? isTextSubtitleStream;

  /// PlaybackInfo's selected subtitle delivery, independent of container origin.
  final String? deliveryMethod;
  final String? deliveryUrl;

  /// Output-container index, distinct from the remote selection ID.
  final int? playbackIndex;
  final int? channels;
  final int? width;
  final int? height;
  final int? bitRate;
  final String? videoRange;
  final String? videoRangeType;

  bool get isAudio => type == 'Audio';
  bool get isSubtitle => type == 'Subtitle';
  bool get isVideo => type == 'Video';

  String get label {
    final title = displayTitle?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }
    final lang = language?.trim();
    if (lang != null && lang.isNotEmpty) {
      return lang;
    }
    return codec ?? '#$index';
  }

  SubtitleRenderKind get subtitleKind {
    if (!isSubtitle) {
      return SubtitleRenderKind.text;
    }
    if (isTextSubtitleStream == true) {
      return SubtitleRenderKind.text;
    }
    if (isTextSubtitleStream == false) {
      return SubtitleRenderKind.bitmap;
    }
    final codecName = (codec ?? '').toLowerCase();
    const textCodecs = {
      'srt',
      'subrip',
      'vtt',
      'webvtt',
      'ass',
      'ssa',
      'sub',
      'microdvd',
      'smi',
      'sami',
      'txt',
    };
    if (textCodecs.contains(codecName)) {
      return SubtitleRenderKind.text;
    }
    return SubtitleRenderKind.bitmap;
  }

  bool get isTextSubtitle =>
      isSubtitle && subtitleKind == SubtitleRenderKind.text;

  bool get isBitmapSubtitle =>
      isSubtitle && subtitleKind == SubtitleRenderKind.bitmap;

  String get externalSubtitleFormat {
    final codecName = (codec ?? '').toLowerCase();
    if (codecName == 'ass' || codecName == 'ssa') {
      return 'ass';
    }
    if (codecName == 'vtt' || codecName == 'webvtt') {
      return 'vtt';
    }
    return 'srt';
  }
}

class PlaybackMediaSource {
  const PlaybackMediaSource({
    required this.id,
    this.name,
    this.container,
    this.protocol,
    this.path,
    this.supportsDirectPlay = false,
    this.supportsDirectStream = false,
    this.supportsTranscoding = false,
    this.isRemote = false,
    this.isInfiniteStream = false,
    this.directStreamUrl,
    this.transcodingUrl,
    this.transcodingOutputBitrate,
    this.runtime,
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
    this.size,
    this.bitrate,
    this.width,
    this.height,
    this.mediaStreams = const [],
  });

  final String id;
  final String? name;
  final String? container;

  /// 传输协议(如 File/Http);strm 指向远端时为 Http。
  final String? protocol;

  /// 媒体路径;strm 条目直连时可能直接是远端 http(s) URL。
  final String? path;
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final bool supportsTranscoding;
  final bool isRemote;
  final bool isInfiniteStream;
  final String? directStreamUrl;
  final String? transcodingUrl;

  /// Server-selected output bps decoded from PlaybackInfo, never a requested cap.
  final int? transcodingOutputBitrate;
  final Duration? runtime;
  final int? defaultAudioStreamIndex;
  final int? defaultSubtitleStreamIndex;
  final int? size;
  final int? bitrate;
  final int? width;
  final int? height;
  final List<MediaStreamInfo> mediaStreams;

  String get label {
    final title = name?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }
    return id;
  }

  /// 直连时可直接打开的远端地址(strm 等场景,服务端不提供 DirectStreamUrl)。
  bool get isRemoteHttpPath {
    final value = path?.trim().toLowerCase() ?? '';
    return value.startsWith('http://') || value.startsWith('https://');
  }

  List<MediaStreamInfo> get audioStreams =>
      mediaStreams.where((stream) => stream.isAudio).toList();

  List<MediaStreamInfo> get subtitleStreams =>
      mediaStreams.where((stream) => stream.isSubtitle).toList();

  MediaSourceView get presentation {
    MediaStreamInfo? video;
    MediaStreamInfo? audio;
    for (final stream in mediaStreams) {
      if (video == null && stream.isVideo) {
        video = stream;
      }
      if (audio == null && stream.isAudio) {
        audio = stream;
      }
    }
    return formatMediaSource(
      name: name,
      container: container,
      sizeBytes: size,
      bitrate: bitrate ?? video?.bitRate,
      width: width ?? video?.width,
      height: height ?? video?.height,
      videoCodec: video?.codec,
      videoRange: video?.videoRange,
      videoRangeType: video?.videoRangeType,
      audioCodec: audio?.codec,
      audioChannels: audio?.channels,
      audioTitle: audio?.displayTitle,
    );
  }

  MediaStreamInfo? streamByIndex(int index) {
    for (final stream in mediaStreams) {
      if (stream.index == index) {
        return stream;
      }
    }
    return null;
  }
}

class PlaybackInfo {
  const PlaybackInfo({
    required this.playSessionId,
    required this.mediaSources,
    this.resources,
  });

  final String playSessionId;
  final List<PlaybackMediaSource> mediaSources;
  final PlaybackResourceLease? resources;

  PlaybackMediaSource? get primarySource =>
      mediaSources.isEmpty ? null : mediaSources.first;

  /// 按 id 查找媒体源(播放中换源时使用);不存在时返回 null。
  PlaybackMediaSource? sourceById(String id) {
    for (final source in mediaSources) {
      if (source.id == id) {
        return source;
      }
    }
    return null;
  }
}

class PlaybackReport {
  const PlaybackReport({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.playMethod,
    required this.position,
    this.isPaused = false,
    this.volumeLevel = 100,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.eventName,
    this.canSeek = true,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final PlayMethod playMethod;
  final Duration position;
  final bool isPaused;
  final int volumeLevel;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final String? eventName;
  final bool canSeek;

  PlaybackReport copyWith({
    Duration? position,
    bool? isPaused,
    int? volumeLevel,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? eventName,
    bool clearEventName = false,
    bool clearSubtitle = false,
  }) {
    return PlaybackReport(
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      playMethod: playMethod,
      position: position ?? this.position,
      isPaused: isPaused ?? this.isPaused,
      volumeLevel: volumeLevel ?? this.volumeLevel,
      audioStreamIndex: audioStreamIndex ?? this.audioStreamIndex,
      subtitleStreamIndex: clearSubtitle
          ? null
          : (subtitleStreamIndex ?? this.subtitleStreamIndex),
      eventName: clearEventName ? null : (eventName ?? this.eventName),
      canSeek: canSeek,
    );
  }
}

class ResolvedPlayback {
  const ResolvedPlayback({
    required this.playMethod,
    required this.streamUrl,
    required this.playSessionId,
    required this.mediaSource,
    required this.itemId,
    this.requiresStrmExpansion = false,
    this.timeline,
    this.filmTimeline,
    this.partIndex = 0,
    this.partStartPosition = Duration.zero,
    this.streamStartsAtRequestedPosition,
    this.authorization,
    this.resources,
    this.canRenewUrlInPlace = true,
    this.outputBitrate,
  });

  /// Negotiated output bitrate in bits/s, from the server response (not request).
  /// Null means unconfirmed; callers must not infer it from their requested cap.
  final int? outputBitrate;
  final bool canRenewUrlInPlace;
  final MediaTimeline? timeline;

  /// Ordered film parts. A stream may cover only [partIndex].
  final MediaTimeline? filmTimeline;
  final int partIndex;
  final Duration partStartPosition;

  /// Null preserves the legacy transcode convention; false means a full Part.
  final bool? streamStartsAtRequestedPosition;
  bool get startsAtRequestedPosition =>
      streamStartsAtRequestedPosition ?? isTranscode;
  Duration? get partOffset {
    final film = filmTimeline;
    if (film == null) return Duration.zero;
    if (partIndex < 0 || partIndex >= film.parts.length) return null;
    var offset = Duration.zero;
    for (var i = 0; i < partIndex; i++) {
      final value = film.parts[i].duration;
      if (value == null || value < Duration.zero) return null;
      offset += value;
    }
    return offset;
  }

  Duration? get streamOrigin => partOffset == null
      ? null
      : partOffset! +
            (startsAtRequestedPosition ? partStartPosition : Duration.zero);

  final ResourceAuthorization? authorization;
  final PlaybackResourceLease? resources;
  final PlayMethod playMethod;
  final Uri streamUrl;
  final String playSessionId;
  final PlaybackMediaSource mediaSource;
  final String itemId;

  /// [streamUrl] is the strm pointer, not a media file. The caller reads it
  /// and opens the first http(s) target inside.
  final bool requiresStrmExpansion;

  bool get isTranscode => playMethod == PlayMethod.transcode;
}

const int kCoreMaxStreamingBitrate = 140000000;

class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.h264 = false,
    this.aac = false,
    this.hevc = false,
    this.ac3 = false,
    this.eac3 = false,
    this.truehd = false,
    this.dts = false,
    this.pgs = false,
    this.ass = false,
    this.ssa = false,
    this.maxStreamingBitrate = kCoreMaxStreamingBitrate,
  });
  final bool h264, aac, hevc, ac3, eac3, truehd, dts, pgs, ass, ssa;
  final int maxStreamingBitrate;
}

const List<int> kTranscodeBitrates = [
  kCoreMaxStreamingBitrate,
  20000000,
  8000000,
  4000000,
  2000000,
  1000000,
];

/// A provider whose selected stream addresses one film Part.
abstract interface class PartPlaybackProvider {
  Future<PlaybackInfo> preparePart({
    required String itemId,
    required PlaybackMediaSource previous,
    required Duration position,
    required int? audioIndex,
    required int? subtitleIndex,
    required int maxStreamingBitrate,
    PlaybackCapabilities? capabilities,
  });
}

/// Part languages differ or are ambiguous; expose real target choices.
class PartTrackSelectionRequired implements Exception {
  const PartTrackSelectionRequired(this.target);
  final PlaybackMediaSource target;
  @override
  String toString() => 'Part language requires explicit selection';
}
