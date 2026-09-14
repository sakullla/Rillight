import 'package:flutter/widgets.dart';

abstract final class PlayerKeys {
  static const open = Key('player-open');
  static const surface = Key('player-surface');
  static const controls = Key('player-controls');
  static const playPause = Key('player-play-pause');
  static const seekBar = Key('player-seek-bar');
  static const fullscreen = Key('player-fullscreen');
  static const playMethod = Key('player-play-method');
  static const volume = Key('player-volume');
  static const mute = Key('player-mute');
  static const volumePercent = Key('player-volume-percent');
  static const more = Key('player-more');
  static const quality = Key('player-quality');
  static const speed = Key('player-speed');
  static const speedLabel = Key('player-speed-label');
  static const audio = Key('player-audio');
  static const subtitle = Key('player-subtitle');
  static const mediaSource = Key('player-media-source');
  static const mediaSourceLabel = Key('player-media-source-label');
  static const skipSettings = Key('player-skip-settings');
  static const resumeContinue = Key('player-resume-continue');
  static const resumeFromStart = Key('player-resume-start');
  static const nextEpisode = Key('player-next-episode');
  static const nextEpisodeCancel = Key('player-next-episode-cancel');
  static const nextEpisodePlay = Key('player-next-episode-play');
  static const playbackEnded = Key('player-playback-ended');
  static const replay = Key('player-replay');
  static const endedViewSeries = Key('player-ended-view-series');
  static const endedClose = Key('player-ended-close');
  static const disconnect = Key('player-disconnect');
  static const progressSyncFailed = Key('player-progress-sync-failed');
  static const subtitleNotice = Key('player-subtitle-notice');
  static const windowError = Key('player-window-error');
}
