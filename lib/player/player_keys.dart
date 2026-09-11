import 'package:flutter/widgets.dart';

abstract final class PlayerKeys {
  static const open = Key('player-open');
  static const surface = Key('player-surface');
  static const controls = Key('player-controls');
  static const playPause = Key('player-play-pause');
  static const seekBar = Key('player-seek-bar');
  static const fullscreen = Key('player-fullscreen');
  static const playMethod = Key('player-play-method');
  static const quality = Key('player-quality');
  static const audio = Key('player-audio');
  static const subtitle = Key('player-subtitle');
  static const resumeContinue = Key('player-resume-continue');
  static const resumeFromStart = Key('player-resume-start');
  static const nextEpisode = Key('player-next-episode');
  static const nextEpisodeCancel = Key('player-next-episode-cancel');
  static const nextEpisodePlay = Key('player-next-episode-play');
  static const disconnect = Key('player-disconnect');
  static const progressSyncFailed = Key('player-progress-sync-failed');
  static const subtitleNotice = Key('player-subtitle-notice');
  static const windowError = Key('player-window-error');
}
