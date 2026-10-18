import 'dart:async';

import 'package:rillight/app/mobile_motion.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import '../auth/server_ui.dart';
import 'player_controller.dart';
import 'playback_line_recovery_ui.dart';

import 'package:rillight/app/ui/app_icons.dart';

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

/// Playback mode remains available even when this server has only one line.
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
        if (controller.playbackLines.isEmpty) return const SizedBox.shrink();
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
        leading: const Icon(AppIcons.swap, fill: AppIcons.filled),
        title: Text(label),
        subtitle: Text(
          controller.playbackLineSelection.isAutomatic
              ? AppLocalizations.of(context).serversAutomatic
              : AppLocalizations.of(context).playbackLineFixed,
        ),
        trailing: const Icon(AppIcons.chevronRight, fill: AppIcons.filled),
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
                      AppIcons.swap,
                      fill: AppIcons.filled,
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
      icon: const Icon(AppIcons.swap, fill: AppIcons.filled, size: 24),
      onPressed: () => unawaited(_open(context)),
    );
  }

  Future<void> _open(BuildContext context) =>
      showPlaybackLineDialog(context, controller);
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
    isScrollControlled: true,
    useSafeArea: true,

    builder: (sheetContext) {
      final l10n = AppLocalizations.of(sheetContext);
      return SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .8,
            ),
            child: Column(
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
                Flexible(child: _PlaybackLineContent(controller: controller)),
              ],
            ),
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
      return AppModalFrame(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(dialogContext).height - 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  l10n.playbackLine,
                  style: AppUiTheme.of(dialogContext).textTheme.titleLarge,
                ),
              ),
              Flexible(
                child: _PlaybackLineContent(
                  controller: controller,
                  autofocus: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: AppButton(
                  key: const Key('playback-lines-close'),
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.serversDismiss),
                ),
              ),
            ],
          ),
        ),
      );
    },
  ).whenComplete(() => controller.setControlsPinned(false, owner: owner));
}

class _PlaybackLineContent extends StatelessWidget {
  const _PlaybackLineContent({
    required this.controller,
    this.autofocus = false,
  });
  final PlayerController controller;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => controller.switchConfirmation != null
        ? playbackSwitchConfirmation(controller)
        : SingleChildScrollView(
            child: PlaybackLineMenu(
              controller: controller,
              autofocus: autofocus,
            ),
          ),
  );
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
        final selection = controller.playbackLineSelection;
        final actual = lines
            .where((line) => line.id == controller.activeLineId)
            .firstOrNull;
        if (controller.switchConfirmation != null) {
          return playbackSwitchConfirmation(controller);
        }
        return Column(
          key: const Key('playback-line-menu'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (actual != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  l10n.playbackLineActual(playbackLineLabel(actual)),
                  key: const Key('playback-line-actual'),
                ),
              ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: ServerFeedbackCard(
                  failure,
                  key: const Key('playback-line-failure'),
                ),
              ),
            if (controller.isRecovering ||
                controller.pendingLineId != null) ...[
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.playbackLinePending),
              ),
              AppButton(
                key: const Key('playback-line-cancel'),
                onPressed: controller.cancelLineRecovery,
                child: Text(l10n.cancelAction),
              ),
            ],
            AppListTile(
              key: const Key('playback-line-auto'),
              leading: Icon(
                AppIcons.bolt,
                size: 20,
                color: selection.isAutomatic
                    ? AppUiTheme.of(context).colorScheme.primary
                    : AppUiTheme.of(context).colorScheme.onSurfaceVariant,
              ),
              title: Text(l10n.serversAutomatic),
              subtitle: Text(l10n.serversAutomaticHint),
              trailing: selection.isAutomatic
                  ? Icon(
                      AppIcons.checkCircle,
                      fill: AppIcons.filled,
                      size: 22,
                      color: AppUiTheme.of(context).colorScheme.primary,
                    )
                  : null,
              selected: selection.isAutomatic,
              autofocus: autofocus && selection.isAutomatic,
              onTap: () =>
                  unawaited(_pickLine(controller, const LineSelection.auto())),
            ),
            for (var index = 0; index < lines.length; index++)
              _LineTile(
                controller: controller,
                lineId: lines[index].id,
                label: playbackLineLabel(lines[index]),
                selected: selection.fixedLineId == lines[index].id,
                current: controller.playbackLineIsCurrent(lines[index]),
                currentLabel: l10n.playbackLineInUse,
                autofocus:
                    autofocus && selection.fixedLineId == lines[index].id,
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
    required this.selected,
    required this.currentLabel,
    required this.autofocus,
    this.onSelected,
  });

  final PlayerController controller;
  final String lineId;
  final String label;
  final bool current, selected;
  final String currentLabel;
  final bool autofocus;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    return AppListTile(
      key: ValueKey('playback-line-$lineId'),
      autofocus: autofocus,
      selected: selected,
      leading: Icon(
        selected ? AppIcons.checkCircle : AppIcons.circle,
        fill: selected ? AppIcons.filled : null,
        size: 22,
        color: selected
            ? AppUiTheme.of(context).colorScheme.primary
            : AppUiTheme.of(context).colorScheme.outline,
      ),
      title: Text(
        label,
        style: selected
            ? TextStyle(
                fontWeight: FontWeight.w600,
                color: AppUiTheme.of(context).colorScheme.primary,
              )
            : null,
      ),
      // Same tag as the server list's line picker: one meaning, one look.
      trailing: current
          ? ServerStatusPill(label: currentLabel, tone: ServerTone.success)
          : null,
      onTap: () {
        unawaited(
          _pickLine(controller, LineSelection.fixed(lineId)).then((_) {
            if (controller.switchConfirmation == null) onSelected?.call();
          }),
        );
      },
    );
  }
}

Future<void> _pickLine(
  PlayerController controller,
  LineSelection selection,
) async {
  try {
    await controller.selectPlaybackLine(selection);
  } catch (_) {
    // The controller publishes the actual connection and an actionable failure.
  }
}
