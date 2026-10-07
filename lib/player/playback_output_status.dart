import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_settings.dart';

/// Observed picture and sound after reconstruction. Catalog tags are not
/// fields here: a Dolby Vision or Atmos name never becomes [videoOutputKind]
/// or [audioDelivery].
class PlaybackOutputStatus {
  const PlaybackOutputStatus({
    this.sampled = false,
    this.dolbyVisionProfile = -1,
    this.dolbyVisionCompatibility = -1,
    this.videoOutputKind = 0,
    this.doviReconstruction = 0,
    this.audioDelivery = 0,
    this.audioChannels = 0,
    this.audioAtmos = false,
    this.hdrDisplayActive,
    this.outputColorSpace,
    this.hdrOutput,
    this.requestedInterpolation = 0,
    this.effectiveInterpolation = 0,
    this.reasonInterpolation = 0,
    this.requestedAnime4k = 0,
    this.effectiveAnime4k = 0,
    this.reasonAnime4k = 0,
    this.requestedSuperResolution = 0,
    this.effectiveSuperResolution = 0,
    this.reasonSuperResolution = 0,
    this.requestedDenoise = 0,
    this.effectiveDenoise = 0,
    this.reasonDenoise = 0,
    this.requestedSharpen = 0,
    this.effectiveSharpen = 0,
    this.reasonSharpen = 0,
    this.outputFrameRate = 0,
  });

  static const unknown = PlaybackOutputStatus();

  /// False until a core snapshot exists. Unknown stays unknown.
  final bool sampled;
  final int dolbyVisionProfile;
  final int dolbyVisionCompatibility;
  final int videoOutputKind;
  final int doviReconstruction;
  final int audioDelivery;
  final int audioChannels;

  /// Core sets this only while a passthrough frame is actually produced and
  /// the sink reported Atmos. Stereo PCM must not copy it into the label.
  final bool audioAtmos;
  final bool? hdrDisplayActive;
  final String? outputColorSpace;
  final bool? hdrOutput;
  final int requestedInterpolation;
  final int effectiveInterpolation;
  final int reasonInterpolation;
  final int requestedAnime4k;
  final int effectiveAnime4k;
  final int reasonAnime4k;
  final int requestedSuperResolution;
  final int effectiveSuperResolution;
  final int reasonSuperResolution;
  final int requestedDenoise;
  final int effectiveDenoise;
  final int reasonDenoise;
  final int requestedSharpen;
  final int effectiveSharpen;
  final int reasonSharpen;

  /// Target display rate from the core. Zero means the sample did not report one.
  final double outputFrameRate;

  static int _int(Object? value, int fallback) =>
      value is num ? value.toInt() : fallback;

  static double _rate(Object? value) {
    if (value is! num) return 0;
    final rate = value.toDouble();
    if (!rate.isFinite || rate <= 0) return 0;
    return rate;
  }

  static bool? _flag(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }

  /// Reads a core command or surface sample. String labels in [raw] are ignored.
  factory PlaybackOutputStatus.fromCoreMap(Map<String, dynamic> raw) {
    final hasPicture =
        raw['videoOutputKind'] is num || raw['dolbyVisionProfile'] is num;
    final hasAudio =
        raw['audioDelivery'] is num || raw['reasonInterpolation'] is num;
    if (!hasPicture || !hasAudio) return unknown;
    return PlaybackOutputStatus(
      sampled: true,
      dolbyVisionProfile: _int(raw['dolbyVisionProfile'], -1),
      dolbyVisionCompatibility: _int(raw['dolbyVisionCompatibility'], -1),
      videoOutputKind: _int(raw['videoOutputKind'], 0),
      doviReconstruction: _int(raw['doviReconstruction'], 0),
      audioDelivery: _int(raw['audioDelivery'], 0),
      audioChannels: _int(raw['audioChannels'], 0),
      audioAtmos: raw['audioAtmos'] == true || raw['audioAtmos'] == 1,
      hdrDisplayActive: _flag(raw['hdrDisplayActive']),
      outputColorSpace: raw['outputColorSpace'] is String
          ? raw['outputColorSpace'] as String
          : null,
      hdrOutput: _flag(raw['hdrOutput']),
      requestedInterpolation: _int(raw['requestedInterpolation'], 0),
      effectiveInterpolation: _int(raw['effectiveInterpolation'], 0),
      reasonInterpolation: _int(raw['reasonInterpolation'], 0),
      requestedAnime4k: _int(raw['requestedAnime4k'], 0),
      effectiveAnime4k: _int(raw['effectiveAnime4k'], 0),
      reasonAnime4k: _int(raw['reasonAnime4k'], 0),
      requestedSuperResolution: _int(raw['requestedSuperResolution'], 0),
      effectiveSuperResolution: _int(raw['effectiveSuperResolution'], 0),
      reasonSuperResolution: _int(raw['reasonSuperResolution'], 0),
      requestedDenoise: _int(raw['requestedDenoise'], 0),
      effectiveDenoise: _int(raw['effectiveDenoise'], 0),
      reasonDenoise: _int(raw['reasonDenoise'], 0),
      requestedSharpen: _int(raw['requestedSharpen'], 0),
      effectiveSharpen: _int(raw['effectiveSharpen'], 0),
      reasonSharpen: _int(raw['reasonSharpen'], 0),
      outputFrameRate: _rate(raw['outputFrameRate']),
    );
  }

  /// Saved choice becomes the request. Effective tiers and reasons stay on the
  /// last core sample until a later frame publishes them.
  PlaybackOutputStatus applying(VideoEnhancementSelection selection) {
    final args = selection.toCoreArgs();
    return PlaybackOutputStatus(
      sampled: sampled,
      dolbyVisionProfile: dolbyVisionProfile,
      dolbyVisionCompatibility: dolbyVisionCompatibility,
      videoOutputKind: videoOutputKind,
      doviReconstruction: doviReconstruction,
      audioDelivery: audioDelivery,
      audioChannels: audioChannels,
      audioAtmos: audioAtmos,
      hdrDisplayActive: hdrDisplayActive,
      outputColorSpace: outputColorSpace,
      hdrOutput: hdrOutput,
      requestedInterpolation: _int(args['interpolation'], 0),
      effectiveInterpolation: effectiveInterpolation,
      reasonInterpolation: reasonInterpolation,
      requestedAnime4k: _int(args['anime4k'], 0),
      effectiveAnime4k: effectiveAnime4k,
      reasonAnime4k: reasonAnime4k,
      requestedSuperResolution: _int(args['superResolution'], 0),
      effectiveSuperResolution: effectiveSuperResolution,
      reasonSuperResolution: reasonSuperResolution,
      requestedDenoise: _int(args['denoise'], 0),
      effectiveDenoise: effectiveDenoise,
      reasonDenoise: reasonDenoise,
      requestedSharpen: _int(args['sharpen'], 0),
      effectiveSharpen: effectiveSharpen,
      reasonSharpen: reasonSharpen,
      outputFrameRate: outputFrameRate,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlaybackOutputStatus &&
        other.sampled == sampled &&
        other.dolbyVisionProfile == dolbyVisionProfile &&
        other.dolbyVisionCompatibility == dolbyVisionCompatibility &&
        other.videoOutputKind == videoOutputKind &&
        other.doviReconstruction == doviReconstruction &&
        other.audioDelivery == audioDelivery &&
        other.audioChannels == audioChannels &&
        other.audioAtmos == audioAtmos &&
        other.hdrDisplayActive == hdrDisplayActive &&
        other.outputColorSpace == outputColorSpace &&
        other.hdrOutput == hdrOutput &&
        other.requestedInterpolation == requestedInterpolation &&
        other.effectiveInterpolation == effectiveInterpolation &&
        other.reasonInterpolation == reasonInterpolation &&
        other.requestedAnime4k == requestedAnime4k &&
        other.effectiveAnime4k == effectiveAnime4k &&
        other.reasonAnime4k == reasonAnime4k &&
        other.requestedSuperResolution == requestedSuperResolution &&
        other.effectiveSuperResolution == effectiveSuperResolution &&
        other.reasonSuperResolution == reasonSuperResolution &&
        other.requestedDenoise == requestedDenoise &&
        other.effectiveDenoise == effectiveDenoise &&
        other.reasonDenoise == reasonDenoise &&
        other.requestedSharpen == requestedSharpen &&
        other.effectiveSharpen == effectiveSharpen &&
        other.reasonSharpen == reasonSharpen &&
        other.outputFrameRate == outputFrameRate;
  }

  @override
  int get hashCode => Object.hashAll([
    sampled,
    dolbyVisionProfile,
    dolbyVisionCompatibility,
    videoOutputKind,
    doviReconstruction,
    audioDelivery,
    audioChannels,
    audioAtmos,
    hdrDisplayActive,
    outputColorSpace,
    hdrOutput,
    requestedInterpolation,
    effectiveInterpolation,
    reasonInterpolation,
    requestedAnime4k,
    effectiveAnime4k,
    reasonAnime4k,
    requestedSuperResolution,
    effectiveSuperResolution,
    reasonSuperResolution,
    requestedDenoise,
    effectiveDenoise,
    reasonDenoise,
    requestedSharpen,
    effectiveSharpen,
    reasonSharpen,
    outputFrameRate,
  ]);
}

/// Native Dolby is kind 3. scRGB is HDR presentation, not native Dolby.
bool playbackOutputIsNativeDolby(PlaybackOutputStatus status) {
  if (!status.sampled || status.outputColorSpace == 'scRGB') return false;
  return status.videoOutputKind == 3;
}

/// Empty when the core did not report a positive finite rate.
String playbackFrameRateText(double rate) {
  if (!rate.isFinite || rate <= 0) return '';
  final nearest = rate.roundToDouble();
  if ((rate - nearest).abs() < 0.05) return nearest.toInt().toString();
  return rate.toStringAsFixed(2);
}

/// Actual video path. scRGB, EDR and SDR tone maps are never native Dolby.
String playbackVideoOutputLabel(
  AppLocalizations l10n,
  PlaybackOutputStatus status,
) {
  if (!status.sampled) return l10n.playbackOutputUnknown;
  // Windows scRGB is HDR presentation, even if a stale kind says otherwise.
  if (status.outputColorSpace == 'scRGB') return l10n.playbackOutputHdrScRgb;
  switch (status.videoOutputKind) {
    case 3:
      return l10n.playbackOutputNativeDolby;
    case 2:
      if (status.hdrOutput == true) return l10n.playbackOutputHdrEdr;
      if (status.outputColorSpace == 'BT.2020 PQ') {
        return l10n.playbackOutputHdrPq;
      }
      return l10n.playbackOutputHdr;
    case 1:
      return l10n.playbackOutputSdr;
    default:
      if (status.hdrOutput == true) return l10n.playbackOutputHdrEdr;
      return l10n.playbackOutputUnknown;
  }
}

/// Actual audio path. Atmos is only passthrough that the sink reported.
String playbackAudioOutputLabel(
  AppLocalizations l10n,
  PlaybackOutputStatus status,
) {
  if (!status.sampled) return l10n.playbackOutputUnknown;
  switch (status.audioDelivery) {
    case 4:
      return status.audioAtmos
          ? l10n.playbackOutputAudioAtmos
          : l10n.playbackOutputAudioPassthrough;
    case 3:
      return status.audioChannels > 0
          ? l10n.playbackOutputAudioChannels(status.audioChannels)
          : l10n.playbackOutputUnknown;
    case 2:
      return l10n.playbackOutputAudioDownmix;
    case 1:
      return l10n.playbackOutputAudioStereo;
    default:
      return l10n.playbackOutputUnknown;
  }
}

String playbackSourceLabel(AppLocalizations l10n, PlaybackOutputStatus status) {
  if (!status.sampled || status.dolbyVisionProfile < 0) {
    return l10n.playbackOutputUnknown;
  }
  if (status.dolbyVisionProfile == 0) return l10n.playbackOutputNotDolby;
  final layer = switch (status.dolbyVisionCompatibility) {
    1 || 6 => l10n.playbackOutputBaseHdr10,
    2 => l10n.playbackOutputBaseSdr,
    4 => l10n.playbackOutputBaseHlg,
    0 => l10n.playbackOutputNone,
    _ => l10n.playbackOutputUnknown,
  };
  final recon = switch (status.doviReconstruction) {
    1 => l10n.playbackOutputReconRpu,
    2 => l10n.playbackOutputReconFel,
    3 => l10n.playbackOutputReconBase,
    _ => '',
  };
  final source =
      '${l10n.playbackOutputProfile(status.dolbyVisionProfile)} · '
      '${l10n.playbackOutputBaseLayer(layer)}';
  return recon.isEmpty ? source : '$source · $recon';
}

String playbackEnhanceLevel(
  AppLocalizations l10n,
  String kind,
  int value, {
  required bool known,
}) {
  if (!known) return l10n.playbackOutputUnknown;
  if (value == 0) return l10n.playerSettingOff;
  return switch (kind) {
    'interpolation' when value == 2 => l10n.playbackEnhanceDouble,
    'anime4k' when value == 1 => l10n.playbackEnhanceLight,
    'anime4k' when value == 2 => l10n.playbackEnhanceStrong,
    'super' when value == 2 => l10n.playbackEnhanceX2,
    'strength' => '$value',
    _ => l10n.playbackOutputUnknown,
  };
}

String? playbackEnhanceReason(AppLocalizations l10n, int reason) {
  return switch (reason) {
    2 => l10n.playbackEnhanceReasonNativeDolby,
    3 => l10n.playbackEnhanceReasonModel,
    4 => l10n.playbackEnhanceReasonOverload,
    5 => l10n.playbackEnhanceReasonRefresh,
    6 => l10n.playbackEnhanceReasonNoPicture,
    7 => l10n.playbackEnhanceReasonCapacity,
    _ => null,
  };
}

/// Chinese explanations for a mismatch, a fallback, or a blocked passthrough.
List<String> playbackOutputReasons(
  AppLocalizations l10n,
  PlaybackOutputStatus status, {
  required double playbackRate,
}) {
  if (!status.sampled) return const [];
  final lines = <String>[];
  if (status.dolbyVisionProfile == 5 &&
      status.doviReconstruction == 0 &&
      status.videoOutputKind == 0) {
    lines.add(l10n.playbackOutputProfile5MissingRpu);
  }
  if (status.doviReconstruction == 3) {
    lines.add(l10n.playbackOutputBaseFallback);
  }
  void add(int requested, int effective, int reason) {
    final named = playbackEnhanceReason(l10n, reason);
    if (named != null && (requested != 0 || effective != 0)) {
      lines.add(named);
      return;
    }
    if (requested != effective) lines.add(l10n.playbackEnhanceReasonMismatch);
  }

  add(
    status.requestedInterpolation,
    status.effectiveInterpolation,
    status.reasonInterpolation,
  );
  add(status.requestedAnime4k, status.effectiveAnime4k, status.reasonAnime4k);
  add(
    status.requestedSuperResolution,
    status.effectiveSuperResolution,
    status.reasonSuperResolution,
  );
  add(status.requestedDenoise, status.effectiveDenoise, status.reasonDenoise);
  add(status.requestedSharpen, status.effectiveSharpen, status.reasonSharpen);
  final pcm =
      status.audioDelivery == 1 ||
      status.audioDelivery == 2 ||
      status.audioDelivery == 3;
  if (pcm && (playbackRate < 0.999 || playbackRate > 1.001)) {
    lines.add(l10n.playbackOutputSpeedPcm);
  }
  return lines;
}

/// True when a later frame rewrote kind, delivery, or an enhancement tier.
bool playbackOutputFrameChanged(
  PlaybackOutputStatus before,
  PlaybackOutputStatus next,
) {
  if (!next.sampled || next == before) return false;
  return before.videoOutputKind != next.videoOutputKind ||
      before.doviReconstruction != next.doviReconstruction ||
      before.dolbyVisionProfile != next.dolbyVisionProfile ||
      before.dolbyVisionCompatibility != next.dolbyVisionCompatibility ||
      before.audioDelivery != next.audioDelivery ||
      before.audioChannels != next.audioChannels ||
      before.audioAtmos != next.audioAtmos ||
      before.requestedInterpolation != next.requestedInterpolation ||
      before.effectiveInterpolation != next.effectiveInterpolation ||
      before.reasonInterpolation != next.reasonInterpolation ||
      before.requestedAnime4k != next.requestedAnime4k ||
      before.effectiveAnime4k != next.effectiveAnime4k ||
      before.reasonAnime4k != next.reasonAnime4k ||
      before.requestedSuperResolution != next.requestedSuperResolution ||
      before.effectiveSuperResolution != next.effectiveSuperResolution ||
      before.reasonSuperResolution != next.reasonSuperResolution ||
      before.requestedDenoise != next.requestedDenoise ||
      before.effectiveDenoise != next.effectiveDenoise ||
      before.reasonDenoise != next.reasonDenoise ||
      before.requestedSharpen != next.requestedSharpen ||
      before.effectiveSharpen != next.effectiveSharpen ||
      before.reasonSharpen != next.reasonSharpen ||
      before.outputFrameRate != next.outputFrameRate;
}
