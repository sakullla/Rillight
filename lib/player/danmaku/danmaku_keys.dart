import 'package:flutter/widgets.dart';

/// 弹幕 UI Key:既有 `player-danmaku-*` 字面量保持不变,新增项用 `danmaku-*`。
abstract final class DanmakuKeys {
  static const menu = Key('player-danmaku-menu');
  static const search = Key('player-danmaku-search');
  static const panel = Key('player-danmaku-panel');
  static const searchPanel = Key('player-danmaku-search-panel');
  static const toggle = Key('player-danmaku-toggle');
  static const matchChip = Key('player-danmaku-match-chip');
  static const status = Key('player-danmaku-status');
  static const setupHint = Key('player-danmaku-setup-hint');
  static const sourceBanner = Key('player-danmaku-source-banner');
  static const useOfficial = Key('player-danmaku-use-official');
  static const searchDismiss = Key('player-danmaku-search-dismiss');
  static const searchField = Key('player-danmaku-search-field');
  static const searchSubmit = Key('player-danmaku-search-submit');
  static const searchLoading = Key('player-danmaku-search-loading');

  static const fontScale = Key('danmaku-font-scale');
  static const speed = Key('danmaku-speed');
  static const area = Key('danmaku-area');
  static const opacity = Key('danmaku-opacity');
  static const types = Key('danmaku-types');
  static const typeScroll = Key('danmaku-type-scroll');
  static const typeTop = Key('danmaku-type-top');
  static const typeBottom = Key('danmaku-type-bottom');
  static const typeColorful = Key('danmaku-type-colorful');
  static const advancedToggle = Key('danmaku-advanced-toggle');
  static const preventOverlap = Key('danmaku-prevent-overlap');
  static const mergeDuplicates = Key('danmaku-merge-duplicates');
  static const outline = Key('danmaku-outline');
  static const followPlaybackRate = Key('danmaku-follow-playback-rate');
  static const density = Key('danmaku-density');
  static const timeOffset = Key('danmaku-time-offset');
  static const timeOffsetMinus = Key('danmaku-time-offset-minus');
  static const timeOffsetPlus = Key('danmaku-time-offset-plus');
  static const timeOffsetZero = Key('danmaku-time-offset-zero');
  static const keywordInput = Key('danmaku-keyword-input');
  static const keywords = Key('danmaku-keywords');
  static const restoreDefaults = Key('danmaku-restore-defaults');

  static Key searchAnime(int animeId) => Key('player-danmaku-anime-$animeId');

  static Key searchEpisode(int episodeId) =>
      Key('player-danmaku-episode-$episodeId');

  static Key keywordChip(String keyword) => Key('danmaku-keyword-$keyword');
}
