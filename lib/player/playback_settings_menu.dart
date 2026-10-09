import 'dart:async';
import 'source_switch_menu.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/widgets/reveal_selected.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/player/playback_output_panel.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_skip_settings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/phone_subtitle_settings.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/track_picker.dart';

enum _SettingsSection { speed, skip, subtitles, audio, quality, source, output }

/// 分类始终留在面板里，改值时不收起。窄窗口改成顶部分类条，控件相同。
class PlaybackSettingsMenu extends StatefulWidget {
  const PlaybackSettingsMenu({super.key, required this.controller});
  final PlayerController controller;
  @override
  State<PlaybackSettingsMenu> createState() => _PlaybackSettingsMenuState();
}

class _PlaybackSettingsMenuState extends State<PlaybackSettingsMenu> {
  final MenuController _menu = MenuController();
  final FocusNode _buttonFocus = FocusNode();
  final FocusScopeNode _panelFocus = FocusScopeNode();
  _SettingsSection _section = _SettingsSection.speed;
  bool _pending = false;

  @override
  void didUpdateWidget(PlaybackSettingsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    scheduleMicrotask(
      () => oldWidget.controller.setControlsPinned(false, owner: _menu),
    );
    if (_menu.isOpen) widget.controller.setControlsPinned(true, owner: _menu);
  }

  @override
  void dispose() {
    _buttonFocus.dispose();
    _panelFocus.dispose();
    final controller = widget.controller;
    // 换片源时加载态会拆掉整棵控制树。MenuAnchor 的关闭动画不一定回调。
    // 等树拆完再释放本菜单的钉住，其它面板的钉住保留。
    scheduleMicrotask(() => controller.setControlsPinned(false, owner: _menu));
    super.dispose();
  }

  Future<void> _apply(Future<void> Function() change) async {
    if (_pending || widget.controller.loading) return;
    setState(() => _pending = true);
    try {
      await change();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).playbackFailed)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pending = false);
        if (_menu.isOpen) {
          widget.controller.setControlsPinned(true, owner: _menu);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(
      AppViewport.dp(420, screen),
      math.max(280.0, screen.width - 48),
    );
    final height = math.min(
      AppViewport.dp(336, screen),
      math.max(240.0, screen.height - 220),
    );
    final l10n = AppLocalizations.of(context);
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      onOpen: () {
        widget.controller.setControlsPinned(true, owner: _menu);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _menu.isOpen) _panelFocus.requestFocus();
        });
      },
      onClose: () => widget.controller.setControlsPinned(false, owner: _menu),
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(16),
        shadowColor: WidgetStatePropertyAll(scheme.scrim.withValues(alpha: .5)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.xl),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      builder: (context, menu, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlaybackLineButton(controller: widget.controller),
          IconButton(
            key: PlayerKeys.more,
            focusNode: _buttonFocus,
            tooltip: l10n.playerPlaybackSettings,
            color: scheme.onSurface,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
        ],
      ),
      menuChildren: [
        SizedBox(
          key: const Key('player-settings-panel'),
          width: width,
          height: height,
          child: FocusScope(
            node: _panelFocus,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _menu.close();
                _buttonFocus.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Material(
              type: MaterialType.transparency,
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) => _panel(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _sectionValue(AppLocalizations l10n, _SettingsSection section) {
    final c = widget.controller;
    switch (section) {
      case _SettingsSection.speed:
        return playerRateLabel(c.playbackRate);
      case _SettingsSection.skip:
        final enabled = <String>[
          if (c.skipIntroEnabled) l10n.settingsSkipIntro,
          if (c.skipOutroEnabled) l10n.settingsSkipOutro,
        ];
        return enabled.isEmpty ? l10n.playerSettingOff : enabled.join(' · ');
      case _SettingsSection.subtitles:
        return switch (c.phoneSubtitleSettings.size) {
          PhoneSubtitleSize.small => l10n.phoneSubtitleSmall,
          PhoneSubtitleSize.standard => l10n.phoneSubtitleStandard,
          PhoneSubtitleSize.large => l10n.phoneSubtitleLarge,
          PhoneSubtitleSize.extraLarge => l10n.phoneSubtitleExtraLarge,
        };
      case _SettingsSection.audio:
        for (final track in c.selectableAudioTracks) {
          if (track.index == c.audioStreamIndex) return track.label;
        }
        return '';
      case _SettingsSection.quality:
        return playerQualityLabel(l10n, c.maxStreamingBitrate);
      case _SettingsSection.source:
        for (final source in c.mediaSources) {
          if (source.id == c.resolved?.mediaSource.id) {
            return source.presentation.headline;
          }
        }
        return '';
      case _SettingsSection.output:
        return playbackVideoOutputLabel(l10n, c.outputStatus);
    }
  }

  Widget _panel(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final sections = <_SettingsSection, (String, IconData, Key)>{
      _SettingsSection.speed: (
        l10n.playbackRate,
        Icons.speed_rounded,
        PlayerKeys.speed,
      ),
      _SettingsSection.skip: (
        l10n.playerSkipSettings,
        Icons.skip_next_rounded,
        const Key('player-skip-settings-section'),
      ),
      _SettingsSection.subtitles: (
        l10n.phoneSubtitleSize,
        Icons.subtitles_rounded,
        const Key('player-subtitle-size-section'),
      ),
      if (c.canSwitchAudioTrack)
        _SettingsSection.audio: (
          l10n.audioTrack,
          Icons.audiotrack_rounded,
          PlayerKeys.audio,
        ),
      if (c.canSwitchQuality)
        _SettingsSection.quality: (
          l10n.quality,
          Icons.high_quality_outlined,
          PlayerKeys.quality,
        ),
      if (c.canSwitchMediaSource)
        _SettingsSection.source: (
          l10n.mediaSource,
          Icons.video_library_outlined,
          PlayerKeys.mediaSource,
        ),
      _SettingsSection.output: (
        l10n.playbackOutputSection,
        Icons.tune_rounded,
        const Key('player-output-section'),
      ),
    };
    final section = sections.containsKey(_section)
        ? _section
        : _SettingsSection.speed;
    Widget category(_SettingsSection key, (String, IconData, Key) info) {
      final selected = section == key;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: RevealSelected(
          selected: selected,
          child: Semantics(
            selected: selected,
            child: TextButton.icon(
              key: info.$3,
              onPressed: () => setState(() => _section = key),
              icon: Icon(info.$2, size: 16),
              label: Text(info.$1),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                foregroundColor: selected
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant,
                backgroundColor: selected
                    ? scheme.surfaceBright
                    : Colors.transparent,
                shape: const StadiumBorder(),
                side: selected
                    ? BorderSide(color: scheme.onSurface.withValues(alpha: .7))
                    : BorderSide.none,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final value = _sectionValue(l10n, section);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sections[section]!.$1,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (value.isNotEmpty)
                Flexible(
                  child: Tooltip(
                    message: value,
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      key: section == _SettingsSection.speed
                          ? PlayerKeys.speedLabel
                          : null,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (section == _SettingsSection.speed)
            PlayerRateGrid(
              selected: c.playbackRate,
              enabled: !_pending && !c.loading,
              onSelected: (rate) => unawaited(_apply(() => c.setRate(rate))),
            )
          else if (_isListSection(section))
            Expanded(child: _listPicker(context, section))
          else
            ..._controls(context, section),
        ],
      ),
    );
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.playerPlaybackSettings,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('player-settings-close'),
                  onPressed: _menu.close,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 2,
            child: _pending || c.loading
                ? const LinearProgressIndicator()
                : Divider(
                    height: 2,
                    color: scheme.outlineVariant.withValues(alpha: .7),
                  ),
          ),
          SizedBox(
            height: 48,
            child: ScrollConfiguration(
              behavior: const _CategoryScrollBehavior(),
              child: ListView(
                key: const Key('player-settings-categories'),
                scrollDirection: Axis.horizontal,
                primary: false,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final entry in sections.entries)
                    category(entry.key, entry.value),
                ],
              ),
            ),
          ),
          Expanded(
            // 音轨/片源等列表分区自带滚动与搜索,不再套外层滚轴。
            child: _isListSection(section)
                ? KeyedSubtree(
                    key: ValueKey('player-settings-content-${section.name}'),
                    child: content,
                  )
                : SingleChildScrollView(
                    key: ValueKey('player-settings-content-${section.name}'),
                    primary: false,
                    child: content,
                  ),
          ),
        ],
      ),
    );
  }

  bool _isListSection(_SettingsSection section) =>
      section == _SettingsSection.audio || section == _SettingsSection.source;

  /// 长列表分区:超阈值自动出现搜索框,选项懒构建。
  Widget _listPicker(BuildContext context, _SettingsSection section) {
    final c = widget.controller;
    final enabled = !_pending && !c.loading;
    switch (section) {
      case _SettingsSection.audio:
        return TrackPickerList(
          options: [
            for (final track in c.selectableAudioTracks)
              TrackPickerOption(
                title: Text(
                  track.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _trackMeta(context, track),
                searchText:
                    '${track.label} ${track.language ?? ''} '
                    '${track.codec ?? ''} ${track.displayTitle ?? ''}',
                selected: track.index == c.audioStreamIndex,
                onTap: enabled
                    ? () => unawaited(_apply(() => c.setAudio(track.index)))
                    : null,
              ),
          ],
        );
      case _SettingsSection.source:
        return TrackPickerList(
          options: [
            for (final source in c.mediaSources)
              TrackPickerOption(
                title: MediaSourceMenuTile(view: source.presentation),
                searchText:
                    '${source.name ?? ''} ${source.id} '
                    '${source.presentation.headline} '
                    '${source.presentation.detail ?? ''}',
                selected: source.id == c.resolved?.mediaSource.id,
                onTap: enabled
                    ? () => unawaited(
                        _apply(() async {
                          await c.switchMediaVersion(source.id);
                        }),
                      )
                    : null,
              ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget? _trackMeta(BuildContext context, MediaStreamInfo track) {
    final meta = trackMetaLabel(AppLocalizations.of(context), track);
    if (meta.isEmpty) return null;
    final theme = Theme.of(context);
    return Text(
      meta,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: .68),
      ),
    );
  }

  List<Widget> _controls(BuildContext context, _SettingsSection section) {
    final c = widget.controller;
    final l10n = AppLocalizations.of(context);
    final enabled = !_pending && !c.loading;
    switch (section) {
      case _SettingsSection.speed:
        return const [];
      case _SettingsSection.subtitles:
        if (!c.canAdjustSubtitleSize) {
          return [Text(l10n.phoneSubtitleUnavailable)];
        }
        return [
          PhoneSubtitleSettingsControls(
            value: c.phoneSubtitleSettings,
            showHeading: false,
            error: c.subtitlePresentationError,
            onChanged: (value) =>
                unawaited(_apply(() => c.setPhoneSubtitleSettings(value))),
          ),
        ];
      case _SettingsSection.skip:
        return [PlaybackSkipSettings(controller: c, compact: true)];
      case _SettingsSection.quality:
        return [
          PlayerOptionGrid(
            options: [
              for (final bitrate in c.availableBitrates)
                PlayerOption(
                  key: ValueKey('player-quality-$bitrate'),
                  label: playerQualityLabel(l10n, bitrate),
                  selected: bitrate == c.maxStreamingBitrate,
                  onPressed: enabled
                      ? () => unawaited(_apply(() => c.setMaxBitrate(bitrate)))
                      : null,
                ),
            ],
          ),
        ];
      case _SettingsSection.output:
        return [PlaybackOutputPanelView(controller: c)];
      default:
        return const [];
    }
  }
}

class _CategoryScrollBehavior extends MaterialScrollBehavior {
  const _CategoryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}
