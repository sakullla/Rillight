import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_switch_preflight.dart';

void main() {
  const original = PlaybackMediaSource(
    id: 'old',
    runTimeTicks: 1000,
    mediaStreams: [
      MediaStreamInfo(index: 1, type: 'Audio', language: 'jpn'),
      MediaStreamInfo(index: 2, type: 'Subtitle', language: 'zho'),
    ],
  );
  PlaybackSwitchPlan inspect(
    PlaybackMediaSource target, {
    int position = 100,
  }) => PlaybackSwitchPlan.inspect(
    original: original,
    target: target,
    positionTicks: position,
    paused: true,
    maxStreamingBitrate: 80000000,
    audioIndex: 1,
    subtitleIndex: 2,
  );

  test('version switch matches language, never the old numeric index', () {
    final plan = inspect(
      const PlaybackMediaSource(
        id: 'target',
        runTimeTicks: 1000,
        mediaStreams: [
          MediaStreamInfo(index: 1, type: 'Audio', language: 'eng'),
          MediaStreamInfo(index: 8, type: 'Audio', language: 'jpn'),
          MediaStreamInfo(index: 2, type: 'Subtitle', language: 'eng'),
          MediaStreamInfo(index: 9, type: 'Subtitle', language: 'zho'),
        ],
      ),
    );
    expect(plan.audioIndex, 8);
    expect(plan.subtitleIndex, 9);
    expect(plan.audioNeedsChoice, false);
    expect(plan.subtitleNeedsChoice, false);
    expect(plan.paused, true);
    expect(plan.maxStreamingBitrate, 80000000);
    expect(plan.timelineConfirmed, false);
    expect(plan.needsConfirmation, true);
    expect(plan.canTryCurrentPosition, true);
  });

  test('same naked version id does not prove cross-service track identity', () {
    final plan = inspect(
      const PlaybackMediaSource(
        id: 'old',
        runTimeTicks: 1000,
        mediaStreams: [
          MediaStreamInfo(index: 1, type: 'Audio', language: 'eng'),
        ],
      ),
    );
    expect(plan.timelineConfirmed, isFalse);
    expect(plan.audioNeedsChoice, isTrue);
    expect(plan.audioIndex, isNull);
  });

  test('missing languages remain visible and require a choice', () {
    final plan = inspect(
      const PlaybackMediaSource(
        id: 'target',
        runTimeTicks: 1000,
        mediaStreams: [
          MediaStreamInfo(index: 1, type: 'Audio', language: 'eng'),
          MediaStreamInfo(index: 2, type: 'Subtitle', language: 'eng'),
        ],
      ),
    );
    expect(plan.audioIndex, isNull);
    expect(plan.subtitleIndex, isNull);
    expect(plan.audioNeedsChoice, true);
    expect(plan.subtitleNeedsChoice, true);
  });

  test(
    'end boundary and unknown runtime forbid attempting current position',
    () {
      final atEnd = inspect(
        const PlaybackMediaSource(id: 'target', runTimeTicks: 100),
      );
      expect(atEnd.positionTicks, 100);
      expect(atEnd.canTryCurrentPosition, false);
      expect(atEnd.needsConfirmation, true);
      expect(
        inspect(const PlaybackMediaSource(id: 'unknown')).canTryCurrentPosition,
        false,
      );
    },
  );

  test('ambiguous tracks require understandable label disambiguation', () {
    final plan = inspect(
      const PlaybackMediaSource(
        id: 'target',
        runTimeTicks: 1000,
        mediaStreams: [
          MediaStreamInfo(
            index: 7,
            type: 'Audio',
            language: 'jpn',
            displayTitle: 'Original',
          ),
          MediaStreamInfo(
            index: 8,
            type: 'Audio',
            language: 'jpn',
            displayTitle: 'Commentary',
          ),
        ],
      ),
    );
    expect(plan.audioNeedsChoice, true);
    expect(plan.audioIndex, isNull);
  });
}
