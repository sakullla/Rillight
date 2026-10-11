import 'models.dart';
import 'playback.dart';

/// Discovers versions and track identities before applying saved preferences.
/// This must only read catalog metadata: it must not select server tracks,
/// negotiate playback, allocate sessions, or create cleanup obligations.
abstract interface class PlaybackMetadataProvider {
  /// Tracks describe the Part at [position] in each version's whole-film time.
  /// An unlocatable position leaves that version's tracks/defaults unknown;
  /// another version must still be discoverable even if the first is unplayable.
  Future<List<PlaybackMediaSource>> getPlaybackSources({
    required String itemId,
    Duration position = Duration.zero,
  });
}

/// Converts the single-file catalog models used by Emby/Jellyfin into selection
/// metadata. No transport URLs or negotiated playback capabilities are inferred.
List<PlaybackMediaSource> playbackSourcesFromItem(MediaItem item) => [
  for (final source in item.mediaSources)
    PlaybackMediaSource(
      id: source.id,
      name: source.name,
      container: source.container,
      size: source.size,
      bitrate: source.bitrate,
      width: source.width,
      height: source.height,
      runtime: source.runtime ?? item.runtime,
      defaultAudioStreamIndex: source.streams
          .where((stream) => stream.isAudio && stream.isDefault == true)
          .firstOrNull
          ?.index,
      defaultSubtitleStreamIndex: source.streams
          .where((stream) => stream.isSubtitle && stream.isDefault == true)
          .firstOrNull
          ?.index,
      mediaStreams: [
        for (final stream in source.streams)
          MediaStreamInfo(
            index: stream.index,
            type: stream.type,
            codec: stream.codec,
            language: stream.language,
            displayTitle: stream.label,
            isDefault: stream.isDefault == true,
            isExternal: stream.isExternal == true,
            channels: stream.channels,
            width: stream.width,
            height: stream.height,
            bitRate: stream.bitRate,
            videoRange: stream.videoRange,
            videoRangeType: stream.videoRangeType,
          ),
      ],
    ),
];
