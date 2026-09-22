import 'package:rillight/emby/media_source_format.dart';

enum PlayMethod {
  directPlay('DirectPlay'),
  directStream('DirectStream'),
  transcode('Transcode');

  const PlayMethod(this.wireName);
  final String wireName;

  bool get isDirect => this != PlayMethod.transcode;
}

const int kEmbyTicksPerSecond = 10000000;

Duration durationFromTicks(int ticks) {
  if (ticks <= 0) {
    return Duration.zero;
  }
  return Duration(microseconds: ticks ~/ 10);
}

int ticksFromDuration(Duration duration) {
  if (duration <= Duration.zero) {
    return 0;
  }
  return duration.inMicroseconds * 10;
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

  factory MediaStreamInfo.fromJson(Map<String, dynamic> json) {
    return MediaStreamInfo(
      index: _asInt(json['Index']) ?? 0,
      type: json['Type']?.toString() ?? '',
      codec: json['Codec']?.toString(),
      language: json['Language']?.toString(),
      displayTitle: json['DisplayTitle']?.toString(),
      isDefault: json['IsDefault'] == true,
      isExternal: json['IsExternal'] == true,
      deliveryMethod: json['DeliveryMethod']?.toString(),
      deliveryUrl: json['DeliveryUrl']?.toString(),
      isTextSubtitleStream: json['IsTextSubtitleStream'] is bool
          ? json['IsTextSubtitleStream'] as bool
          : null,
      channels: _asInt(json['Channels']),
      width: _asInt(json['Width']),
      height: _asInt(json['Height']),
      bitRate: _asInt(json['BitRate']),
      videoRange: json['VideoRange']?.toString(),
      videoRangeType: json['VideoRangeType']?.toString(),
    );
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
    this.isInfiniteStream = false,
    this.directStreamUrl,
    this.transcodingUrl,
    this.runTimeTicks,
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
  final bool isInfiniteStream;
  final String? directStreamUrl;
  final String? transcodingUrl;
  final int? runTimeTicks;
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
    final value = path?.trim() ?? '';
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

  factory PlaybackMediaSource.fromJson(Map<String, dynamic> json) {
    final streams = <MediaStreamInfo>[];
    final raw = json['MediaStreams'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          streams.add(
            MediaStreamInfo.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return PlaybackMediaSource(
      id: json['Id']?.toString() ?? '',
      name: json['Name']?.toString(),
      container: json['Container']?.toString(),
      protocol: json['Protocol']?.toString(),
      path: json['Path']?.toString(),
      supportsDirectPlay: json['SupportsDirectPlay'] == true,
      supportsDirectStream: json['SupportsDirectStream'] == true,
      supportsTranscoding: json['SupportsTranscoding'] == true,
      isInfiniteStream: json['IsInfiniteStream'] == true,
      directStreamUrl: json['DirectStreamUrl']?.toString(),
      transcodingUrl: json['TranscodingUrl']?.toString(),
      runTimeTicks: _asInt(json['RunTimeTicks']),
      defaultAudioStreamIndex: _asInt(json['DefaultAudioStreamIndex']),
      defaultSubtitleStreamIndex: _asInt(json['DefaultSubtitleStreamIndex']),
      size: _asInt(json['Size']),
      bitrate: _asInt(json['Bitrate']),
      width: _asInt(json['Width']),
      height: _asInt(json['Height']),
      mediaStreams: streams,
    );
  }
}

class PlaybackInfo {
  const PlaybackInfo({required this.playSessionId, required this.mediaSources});

  final String playSessionId;
  final List<PlaybackMediaSource> mediaSources;

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

  factory PlaybackInfo.fromJson(Map<String, dynamic> json) {
    final sources = <PlaybackMediaSource>[];
    final raw = json['MediaSources'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          sources.add(
            PlaybackMediaSource.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return PlaybackInfo(
      playSessionId: json['PlaySessionId']?.toString() ?? '',
      mediaSources: sources,
    );
  }
}

class PlaybackReport {
  const PlaybackReport({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.playMethod,
    required this.positionTicks,
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
  final int positionTicks;
  final bool isPaused;
  final int volumeLevel;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final String? eventName;
  final bool canSeek;

  PlaybackReport copyWith({
    int? positionTicks,
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
      positionTicks: positionTicks ?? this.positionTicks,
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

  /// 由播放进程留下的会话快照构造宿主代发的 Stopped 载荷。
  ///
  /// 进程已终止,只保留会话标识与最后位置;暂停态记为已暂停,
  /// 音量/轨道等仅播放进程知道的字段取默认值。
  factory PlaybackReport.fromSnapshot(PlaybackSessionSnapshot snapshot) {
    return PlaybackReport(
      itemId: snapshot.itemId,
      mediaSourceId: snapshot.mediaSourceId,
      playSessionId: snapshot.playSessionId,
      playMethod: snapshot.playMethod,
      positionTicks: snapshot.positionTicks,
      isPaused: true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ItemId': itemId,
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'PlayMethod': playMethod.wireName,
      'PositionTicks': positionTicks,
      'IsPaused': isPaused,
      'IsMuted': volumeLevel <= 0,
      'VolumeLevel': volumeLevel,
      'CanSeek': canSeek,
      'RepeatMode': 'RepeatNone',
      if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
      if (subtitleStreamIndex != null)
        'SubtitleStreamIndex': subtitleStreamIndex,
      if (eventName != null) 'EventName': eventName,
    };
  }
}

/// 播放进程持续落盘的会话快照:宿主在播放进程被终止或意外退出后,
/// 据此用主进程会话代发 Stopped(见 `PlaybackSessionSnapshotStore`)。
///
/// 字段与 [PlaybackReport.toJson] 的会话标识一致;[baseUrl]/[userId]
/// 供宿主校验快照归属,避免串服务器代发。
class PlaybackSessionSnapshot {
  const PlaybackSessionSnapshot({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.positionTicks,
    required this.baseUrl,
    required this.userId,
    required this.timestamp,
    this.playMethod = PlayMethod.directStream,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final int positionTicks;
  final String baseUrl;
  final String userId;
  final DateTime timestamp;
  final PlayMethod playMethod;

  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'mediaSourceId': mediaSourceId,
      'playSessionId': playSessionId,
      'playMethod': playMethod.wireName,
      'positionTicks': positionTicks,
      'baseUrl': baseUrl,
      'userId': userId,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }

  /// 缺少任一会话标识字段时返回 null(视为无效快照)。
  static PlaybackSessionSnapshot? fromJson(Map<String, dynamic> json) {
    final itemId = json['itemId']?.toString();
    final mediaSourceId = json['mediaSourceId']?.toString();
    final playSessionId = json['playSessionId']?.toString();
    final baseUrl = json['baseUrl']?.toString();
    final userId = json['userId']?.toString();
    if (itemId == null ||
        itemId.isEmpty ||
        mediaSourceId == null ||
        playSessionId == null ||
        baseUrl == null ||
        baseUrl.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return null;
    }
    final wire = json['playMethod']?.toString();
    var playMethod = PlayMethod.directStream;
    for (final value in PlayMethod.values) {
      if (value.wireName == wire) {
        playMethod = value;
        break;
      }
    }
    final timestamp =
        DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return PlaybackSessionSnapshot(
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      playSessionId: playSessionId,
      playMethod: playMethod,
      positionTicks: _asInt(json['positionTicks']) ?? 0,
      baseUrl: baseUrl,
      userId: userId,
      timestamp: timestamp,
    );
  }
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}
