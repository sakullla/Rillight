import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/playback_skip_settings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';

enum _SettingsSection { speed, skip, audio, quality, source }

/// A stable settings panel: categories remain available while values change.
/// Narrow windows use a horizontal category bar with the same controls.
class PlaybackSettingsMenu extends StatefulWidget {
  const PlaybackSettingsMenu({super.key, required this.controller});
  final PlayerController controller;
  @override
  State<PlaybackSettingsMenu> createState() => _PlaybackSettingsMenuState();
}

class _PlaybackSettingsMenuState extends State<PlaybackSettingsMenu> {
  final MenuController _menu = MenuController();
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
    final controller = widget.controller;
    // Changing source temporarily removes the entire controls subtree while
    // loading. MenuAnchor teardown need not deliver its animated onClose.
    // Release this menu's lease after tree teardown, preserving other panels.
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
    final width = math.min(520.0, math.max(200.0, screen.width - 24));
    final height = math.min(400.0, math.max(160.0, screen.height - 112));
    final l10n = AppLocalizations.of(context);
    return MenuAnchor(
      controller: _menu,
      onOpen: () => widget.controller.setControlsPinned(true, owner: _menu),
      onClose: () => widget.controller.setControlsPinned(false, owner: _menu),
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .4),
            ),
          ),
        ),
      ),
      builder: (context, menu, _) => IconButton(
        key: PlayerKeys.more,
        tooltip: l10n.playerPlaybackSettings,
        color: scheme.onSurface,
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
      menuChildren: [
        SizedBox(
          key: const Key('player-settings-panel'),
          width: width,
          height: height,
          child: Material(
            type: MaterialType.transparency,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => _panel(context, compact: width < 460),
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel(BuildContext context, {required bool compact}) {
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
      if (c.audioTracks.isNotEmpty)
        _SettingsSection.audio: (
          l10n.audioTrack,
          Icons.audiotrack_rounded,
          PlayerKeys.audio,
        ),
      if (c.isTranscode)
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
    };
    final section = sections.containsKey(_section)
        ? _section
        : _SettingsSection.speed;
    Widget category(_SettingsSection key, (String, IconData, Key) info) {
      final selected = section == key;
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Semantics(
          selected: selected,
          child: TextButton.icon(
            key: info.$3,
            onPressed: () => setState(() => _section = key),
            icon: Icon(info.$2, size: 18),
            label: Text(info.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 44),
              foregroundColor: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
              backgroundColor: selected
                  ? scheme.secondaryContainer
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: theme.textTheme.labelLarge,
            ),
          ),
        ),
      );
    }

    final content = SingleChildScrollView(
      key: ValueKey('player-settings-content-${section.name}'),
      primary: false,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sections[section]!.$1,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          ..._controls(context, section),
        ],
      ),
    );
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.playerPlaybackSettings,
                    style: theme.textTheme.titleSmall,
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
                    color: scheme.outlineVariant.withValues(alpha: .35),
                  ),
          ),
          if (compact) ...[
            SingleChildScrollView(
              primary: false,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final entry in sections.entries)
                    category(entry.key, entry.value),
                ],
              ),
            ),
            Expanded(child: content),
          ] else
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 142,
                    child: SingleChildScrollView(
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(8, 12, 4, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in sections.entries)
                            category(entry.key, entry.value),
                        ],
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant.withValues(alpha: .35),
                  ),
                  Expanded(child: content),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _controls(BuildContext context, _SettingsSection section) {
    final c = widget.controller;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final enabled = !_pending && !c.loading;
    switch (section) {
      case _SettingsSection.speed:
        return [
          Text(
            _rateLabel(c.playbackRate),
            key: PlayerKeys.speedLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final rate in kPlaybackRateLadder)
                ChoiceChip(
                  label: SizedBox(
                    width: 42,
                    child: Text(_rateLabel(rate), textAlign: TextAlign.center),
                  ),
                  selected: rate == c.playbackRate,
                  showCheckmark: false,
                  onSelected: enabled
                      ? (_) => unawaited(_apply(() => c.setRate(rate)))
                      : null,
                ),
            ],
          ),
        ];
      case _SettingsSection.skip:
        return [
          PlaybackSkipSettings(controller: c),
          const SizedBox(height: 12),
          Text(
            l10n.playerSkipSettingsSaved,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ];
      case _SettingsSection.audio:
        return [
          for (final track in c.audioTracks)
            _choice(
              Text(track.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              track.index == c.audioStreamIndex,
              enabled
                  ? () => unawaited(_apply(() => c.setAudio(track.index)))
                  : null,
            ),
        ];
      case _SettingsSection.quality:
        return [
          for (final bitrate in c.availableBitrates)
            _choice(
              Text(_qualityLabel(l10n, bitrate)),
              bitrate == c.maxStreamingBitrate,
              enabled
                  ? () => unawaited(_apply(() => c.setMaxBitrate(bitrate)))
                  : null,
            ),
        ];
      case _SettingsSection.source:
        return [
          for (final source in c.mediaSources)
            _choice(
              MediaSourceMenuTile(view: source.presentation),
              source.id == c.resolved?.mediaSource.id,
              enabled
                  ? () =>
                        unawaited(_apply(() => c.switchMediaSource(source.id)))
                  : null,
            ),
        ];
    }
  }

  Widget _choice(Widget label, bool selected, VoidCallback? onPressed) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        selectedColor: scheme.onSecondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: label,
        trailing: selected ? const Icon(Icons.check_rounded, size: 18) : null,
        onTap: onPressed,
      ),
    );
  }
}

String _rateLabel(double rate) =>
    '${rate == rate.roundToDouble() ? rate.round() : rate}x';
String _qualityLabel(AppLocalizations l10n, int bitrate) =>
    bitrate == kTranscodeBitrates.first || !kTranscodeBitrates.contains(bitrate)
    ? l10n.qualityAuto
    : l10n.qualityMbps(bitrate ~/ 1000000);
