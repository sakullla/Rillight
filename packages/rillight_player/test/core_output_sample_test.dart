import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/src/core_player.dart';

void main() {
  CoreOutputSample sample({
    int videoOutputKind = 3,
    int audioDelivery = 4,
    int effectiveInterpolation = 2,
    int reasonInterpolation = 1,
  }) {
    return CoreOutputSample.fromSnapshot(
      dolbyVisionProfile: 7,
      dolbyVisionCompatibility: 6,
      videoOutputKind: videoOutputKind,
      doviReconstruction: 2,
      audioDelivery: audioDelivery,
      audioChannels: 8,
      audioLayout: 0,
      audioAtmos: 1,
      audioCodecId: 0,
      requestedInterpolation: 2,
      effectiveInterpolation: effectiveInterpolation,
      requestedAnime4k: 0,
      effectiveAnime4k: 0,
      requestedSuperResolution: 0,
      effectiveSuperResolution: 0,
      requestedDenoise: 0,
      effectiveDenoise: 0,
      requestedSharpen: 0,
      effectiveSharpen: 0,
      enhancement: {'reasonInterpolation': reasonInterpolation},
    );
  }

  test('snapshot equality ignores playback position', () {
    final first = sample();
    final again = sample();
    expect(first, again);
    expect(first.toMap()['videoOutputKind'], 3);
    expect(first.toMap().containsKey('position'), isFalse);
    expect(first.reasonInterpolation, 1);
  });

  test('kind, delivery, effective tier and reason are different samples', () {
    final first = sample();
    expect(first == sample(videoOutputKind: 1), isFalse);
    expect(first == sample(audioDelivery: 3), isFalse);
    expect(first == sample(effectiveInterpolation: 0), isFalse);
    expect(first == sample(reasonInterpolation: 4), isFalse);
  });

  test('enhancement status overrides the snapshot tier', () {
    final resolved = CoreOutputSample.fromSnapshot(
      dolbyVisionProfile: 0,
      dolbyVisionCompatibility: -1,
      videoOutputKind: 1,
      doviReconstruction: 0,
      audioDelivery: 1,
      audioChannels: 2,
      audioLayout: 0,
      audioAtmos: 0,
      audioCodecId: 0,
      requestedInterpolation: 2,
      effectiveInterpolation: 2,
      requestedAnime4k: 0,
      effectiveAnime4k: 0,
      requestedSuperResolution: 0,
      effectiveSuperResolution: 0,
      requestedDenoise: 0,
      effectiveDenoise: 0,
      requestedSharpen: 0,
      effectiveSharpen: 0,
      enhancement: {'effectiveInterpolation': 0, 'reasonInterpolation': 4},
    );
    expect(resolved.effectiveInterpolation, 0);
    expect(resolved.requestedInterpolation, 2);
    expect(resolved.reasonInterpolation, 4);
    expect(resolved.outputFrameRate, 0);
  });

  test('published sample keeps a positive target frame rate', () {
    final resolved = CoreOutputSample.fromSnapshot(
      dolbyVisionProfile: 0,
      dolbyVisionCompatibility: -1,
      videoOutputKind: 1,
      doviReconstruction: 0,
      audioDelivery: 1,
      audioChannels: 2,
      audioLayout: 0,
      audioAtmos: 0,
      audioCodecId: 0,
      requestedInterpolation: 2,
      effectiveInterpolation: 2,
      requestedAnime4k: 0,
      effectiveAnime4k: 0,
      requestedSuperResolution: 0,
      effectiveSuperResolution: 0,
      requestedDenoise: 0,
      effectiveDenoise: 0,
      requestedSharpen: 0,
      effectiveSharpen: 0,
      enhancement: {'outputFrameRate': 47.952},
    );
    expect(resolved.outputFrameRate, 47.952);
    expect(resolved.toMap()['outputFrameRate'], 47.952);
    final again = CoreOutputSample.fromSnapshot(
      dolbyVisionProfile: 0,
      dolbyVisionCompatibility: -1,
      videoOutputKind: 1,
      doviReconstruction: 0,
      audioDelivery: 1,
      audioChannels: 2,
      audioLayout: 0,
      audioAtmos: 0,
      audioCodecId: 0,
      requestedInterpolation: 2,
      effectiveInterpolation: 2,
      requestedAnime4k: 0,
      effectiveAnime4k: 0,
      requestedSuperResolution: 0,
      effectiveSuperResolution: 0,
      requestedDenoise: 0,
      effectiveDenoise: 0,
      requestedSharpen: 0,
      effectiveSharpen: 0,
      enhancement: {'outputFrameRate': 0},
    );
    expect(again.outputFrameRate, 0);
    expect(resolved == again, isFalse);
  });
}
