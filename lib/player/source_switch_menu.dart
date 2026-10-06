import 'dart:async';

import 'package:flutter/material.dart';
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
      return ListTile(
        key: const Key('player-playback-lines'),
        leading: const Icon(Icons.alt_route),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right_rounded),
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
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _focused
                  ? Theme.of(context).colorScheme.tertiaryContainer
                  : Colors.transparent,
              border: Border.all(
                color: _focused
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.transparent,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.alt_route, size: 28),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
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
    return IconButton(
      key: const Key('player-playback-lines'),
      tooltip: label,
      icon: const Icon(Icons.alt_route),
      onPressed: () => unawaited(_open(context)),
    );
  }

  Future<void> _open(BuildContext context) async {
    final owner = Object();
    controller.setControlsPinned(true, owner: owner);
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final l10n = AppLocalizations.of(context);
    final lines = controller.playbackLines;
    try {
      await showMenu<void>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromPoints(topLeft, bottomRight),
          Offset.zero & overlay.size,
        ),
        items: [
          for (final line in lines)
            PopupMenuItem<void>(
              key: ValueKey('playback-line-${line.id}'),
              onTap: () => unawaited(_pickLine(controller, line.id)),
              child: _LineCaption(
                label: playbackLineLabel(line),
                current: controller.playbackLineIsCurrent(line),
                currentLabel: l10n.playbackLineInUse,
              ),
            ),
        ],
      );
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
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
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
                  style: Theme.of(context).textTheme.titleLarge,
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
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      return AlertDialog(
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
    return ListTile(
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
