import 'playback_models.dart';

/// A switch carries intent, not native indices from a different edition.
enum SwitchResumeChoice { currentPosition, beginning, cancel }

class PlaybackSwitchPlan {
  const PlaybackSwitchPlan({
    required this.sourceId,
    required this.positionTicks,
    required this.paused,
    required this.maxStreamingBitrate,
    required this.targetRuntimeTicks,
    required this.timelineConfirmed,
    required this.audioIndex,
    required this.subtitleIndex,
    required this.audioNeedsChoice,
    required this.subtitleNeedsChoice,
    required this.audioChoices,
    required this.subtitleChoices,
  });

  final String sourceId;
  final int positionTicks;
  final bool paused;
  final int maxStreamingBitrate;
  final int? targetRuntimeTicks;
  final bool timelineConfirmed;
  final int? audioIndex;
  final int? subtitleIndex;
  final bool audioNeedsChoice;
  final bool subtitleNeedsChoice;
  final List<MediaStreamInfo> audioChoices;
  final List<MediaStreamInfo> subtitleChoices;

  // Unknown duration is not evidence that the requested position is in range.
  bool get canTryCurrentPosition =>
      positionTicks == 0 ||
      (targetRuntimeTicks != null && positionTicks < targetRuntimeTicks!);
  bool get needsConfirmation =>
      (!timelineConfirmed && positionTicks > 0) ||
      !canTryCurrentPosition ||
      audioNeedsChoice ||
      subtitleNeedsChoice;

  static PlaybackSwitchPlan inspect({
    required PlaybackMediaSource original,
    required PlaybackMediaSource target,
    required int positionTicks,
    required bool paused,
    required int maxStreamingBitrate,
    required int? audioIndex,
    required int? subtitleIndex,
    bool timelineConfirmed = false,
    // Set only after account/item/version and line ServerId verification.
    // Equal naked ids from two services are not the same version.
    bool sameVersion = false,
  }) {
    int? match(List<MediaStreamInfo> tracks, MediaStreamInfo? old) {
      if (old == null) return null;
      if (sameVersion) {
        for (final stream in tracks) {
          if (stream.index == old.index) return stream.index;
        }
        return null;
      }
      final language = old.language?.trim().toLowerCase();
      final title = old.displayTitle?.trim().toLowerCase();
      if (language == null || language.isEmpty || language == 'und') {
        // A codec or numeric fallback label is not understandable identity.
        if (title == null || title.isEmpty) return null;
        final matches = tracks.where(
          (s) => s.displayTitle?.trim().toLowerCase() == title,
        );
        return matches.length == 1 ? matches.single.index : null;
      }
      final matches = tracks
          .where((s) => s.language?.trim().toLowerCase() == language)
          .toList();
      if (matches.length == 1) return matches.single.index;
      final titled = matches.where(
        (s) => title != null && s.displayTitle?.trim().toLowerCase() == title,
      );
      return titled.length == 1 ? titled.single.index : null;
    }

    final oldAudio = audioIndex == null
        ? null
        : original.streamByIndex(audioIndex);
    final oldSubtitle = subtitleIndex == null
        ? null
        : original.streamByIndex(subtitleIndex);
    final audio = match(target.audioStreams, oldAudio);
    final subtitle = match(target.subtitleStreams, oldSubtitle);
    return PlaybackSwitchPlan(
      sourceId: target.id,
      positionTicks: positionTicks,
      paused: paused,
      maxStreamingBitrate: maxStreamingBitrate,
      targetRuntimeTicks: target.runTimeTicks,
      // Equal durations/names do not prove identical editing.
      timelineConfirmed: sameVersion || timelineConfirmed,
      audioIndex: audio,
      subtitleIndex: subtitle,
      audioNeedsChoice: audioIndex != null && audio == null,
      subtitleNeedsChoice: subtitleIndex != null && subtitle == null,
      audioChoices: List.unmodifiable(target.audioStreams),
      subtitleChoices: List.unmodifiable(target.subtitleStreams),
    );
  }
}
