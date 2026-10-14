import 'dart:async';

import 'package:rillight/app/mobile_motion.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import 'player_controller.dart';

enum PlaybackLinePresentation { popup, sheet, focusable }

enum PlaybackLineSurface { popup, sheet, dialog }

/// Existing call sites pass a surface. The line list replaces the old menu.
class SourceSwitchButton extends StatelessWidget {
  const SourceSwitchButton({
    super.key,
    required this.controller,
    this.surface = PlaybackLineSurface.popup,
  });

  final PlayerController controller;
  final PlaybackLineSurface surface;

  @override
  Widget build(BuildContext context) {
    final presentation = switch (surface) {
      PlaybackLineSurface.popup => PlaybackLinePresentation.popup,
      PlaybackLineSurface.sheet => PlaybackLinePresentation.sheet,
      PlaybackLineSurface.dialog => PlaybackLinePresentation.focusable,
    };
    return PlaybackLineButton(
      controller: controller,
      presentation: presentation,
    );
  }
}

/// Playback line entry. Hidden unless the server now playing has two lines.
class PlaybackLineButton extends StatelessWidget {
  const PlaybackLineButton({
    super.key,
    required this.controller,
    this.presentation = PlaybackLinePresentation.popup,
  });

  final PlayerController controller;
  final PlaybackLinePresentation presentation;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.canChoosePlaybackLine) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context);
        return switch (presentation) {
          PlaybackLinePresentation.popup => _PlaybackLinePopup(
            controller: controller,
            label: l10n.playbackLine,
          ),
          PlaybackLinePresentation.sheet => _PlaybackLineEntry(
            controller: controller,
            label: l10n.playbackLine,
            onPressed: () => showPlaybackLineSheet(context, controller),
          ),
          PlaybackLinePresentation.focusable => _PlaybackLineEntry(
            controller: controller,
            label: l10n.playbackLine,
            focusable: true,
            onPressed: () => showPlaybackLineDialog(context, controller),
          ),
        };
      },
    );
  }
}

class _PlaybackLineEntry extends StatelessWidget {
  const _PlaybackLineEntry({
    required this.controller,
    required this.label,
    required this.onPressed,
    this.focusable = false,
  });

  final PlayerController controller;
  final String label;
  final VoidCallback onPressed;
  final bool focusable;

  @override
  Widget build(BuildContext context) {
    if (!focusable) {
      return AppListTile(
        key: const Key('player-playback-lines'),
        leading: const Icon(CupertinoIcons.arrow_branch),
        title: Text(label),
        trailing: const Icon(CupertinoIcons.chevron_right),
        onTap: onPressed,
      );
    }
    return _FocusableLineButton(label: label, onPressed: onPressed);
  }
}

class _FocusableLineButton extends StatefulWidget {
  const _FocusableLineButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_FocusableLineButton> createState() => _FocusableLineButtonState();
}

class _FocusableLineButtonState extends State<_FocusableLineButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      key: const Key('player-playback-lines'),
      autofocus: false,
      onFocusChange: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        focused: _focused,
        label: widget.label,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Builder(
            builder: (context) {
              // 与电视播放控制行同一外观:半透明黑底,聚焦反相为白底黑字。
              final s = TvDesign.scaleOf(context);
              final foreground = _focused
                  ? CupertinoColors.black
                  : CupertinoColors.white;
              return Container(
                constraints: BoxConstraints(minHeight: 38 * s),
                padding: EdgeInsets.symmetric(
                  horizontal: 14 * s,
                  vertical: 8 * s,
                ),
                decoration: BoxDecoration(
                  color: _focused
                      ? CupertinoColors.white
                      : CupertinoColors.black.withValues(alpha: .34),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.arrow_branch,
                      size: 20 * s,
                      color: foreground,
                    ),
                    SizedBox(width: 6 * s),
                    Text(
                      widget.label,
                      style: AppUiTheme.of(context).textTheme.labelLarge
                          ?.copyWith(color: foreground),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlaybackLinePopup extends StatelessWidget {
  const _PlaybackLinePopup({required this.controller, required this.label});

  final PlayerController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return AppIconButton(
      key: const Key('player-playback-lines'),
      tooltip: label,
      icon: const Icon(CupertinoIcons.arrow_branch),
      onPressed: () => unawaited(_open(context)),
    );
  }

  Future<void> _open(BuildContext context) async {
    final owner = Object();
    controller.setControlsPinned(true, owner: owner);
    final l10n = AppLocalizations.of(context);
    final lines = controller.playbackLines;
    try {
      final selected = await showAppMenu<String>(
        context: context,
        items: [
          for (final line in lines)
            AppMenuEntry(
              value: line.id,
              child: KeyedSubtree(
                key: ValueKey('playback-line-${line.id}'),
                child: _LineCaption(
                  label: playbackLineLabel(line),
                  current: controller.playbackLineIsCurrent(line),
                  currentLabel: l10n.playbackLineInUse,
                ),
              ),
            ),
        ],
      );
      if (selected != null) await _pickLine(controller, selected);
    } finally {
      controller.setControlsPinned(false, owner: owner);
    }
  }
}

Future<void> showPlaybackLineSheet(
  BuildContext context,
  PlayerController controller,
) {
  final owner = Object();
  controller.setControlsPinned(true, owner: owner);
  return PhoneMotion.showBottomPanel<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,

    builder: (sheetContext) {
      final l10n = AppLocalizations.of(sheetContext);
      return SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  l10n.playbackLine,
                  style: AppUiTheme.of(context).textTheme.titleLarge,
                ),
              ),
              PlaybackLineMenu(controller: controller),
            ],
          ),
        ),
      );
    },
  ).whenComplete(() => controller.setControlsPinned(false, owner: owner));
}

Future<void> showPlaybackLineDialog(
  BuildContext context,
  PlayerController controller,
) {
  final owner = Object();
  controller.setControlsPinned(true, owner: owner);
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      return AppDialog(
        title: Text(l10n.playbackLine),
        content: SizedBox(
          width: 420,
          child: PlaybackLineMenu(controller: controller, autofocus: true),
        ),
      );
    },
  ).whenComplete(() => controller.setControlsPinned(false, owner: owner));
}

class PlaybackLineMenu extends StatelessWidget {
  const PlaybackLineMenu({
    super.key,
    required this.controller,
    this.onSelected,
    this.autofocus = false,
  });

  final PlayerController controller;
  final VoidCallback? onSelected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final lines = controller.playbackLines;
        final failure = controller.playbackLineFailure;
        final currentIndex = lines.indexWhere(controller.playbackLineIsCurrent);
        return Column(
          key: const Key('playback-line-menu'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  l10n.playbackLineFailed(failure),
                  key: const Key('playback-line-failure'),
                ),
              ),
            for (var index = 0; index < lines.length; index++)
              _LineTile(
                controller: controller,
                lineId: lines[index].id,
                label: playbackLineLabel(lines[index]),
                current: controller.playbackLineIsCurrent(lines[index]),
                currentLabel: l10n.playbackLineInUse,
                autofocus:
                    autofocus &&
                    (currentIndex < 0 ? index == 0 : index == currentIndex),
                onSelected: onSelected,
              ),
          ],
        );
      },
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.controller,
    required this.lineId,
    required this.label,
    required this.current,
    required this.currentLabel,
    required this.autofocus,
    this.onSelected,
  });

  final PlayerController controller;
  final String lineId;
  final String label;
  final bool current;
  final String currentLabel;
  final bool autofocus;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    return AppListTile(
      key: ValueKey('playback-line-$lineId'),
      autofocus: autofocus,
      selected: current,
      title: Text(label),
      trailing: current ? Text(currentLabel) : null,
      onTap: () {
        onSelected?.call();
        unawaited(_pickLine(controller, lineId));
      },
    );
  }
}

class _LineCaption extends StatelessWidget {
  const _LineCaption({
    required this.label,
    required this.current,
    required this.currentLabel,
  });

  final String label;
  final bool current;
  final String currentLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        if (current) Text(currentLabel),
      ],
    );
  }
}

Future<void> _pickLine(PlayerController controller, String lineId) async {
  try {
    await controller.switchLine(lineId);
  } catch (_) {
    // The controller keeps the previous line and records the reason.
  }
}
