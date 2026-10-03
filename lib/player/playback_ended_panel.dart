import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/player/player_keys.dart';

/// Touch and remote completion actions. The owning page handles native cleanup
/// and navigation, so returning to a series also restores phone system chrome.
class PlaybackEndedPanel extends StatelessWidget {
  const PlaybackEndedPanel({
    super.key,
    required this.title,
    required this.onReplay,
    required this.onClose,
    this.onViewSeries,
    this.tv = false,
    this.replayFocus,
  });

  final String title;
  final VoidCallback onReplay;
  final VoidCallback onClose;
  final VoidCallback? onViewSeries;
  final bool tv;
  final FocusNode? replayFocus;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: Colors.black87,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(tv ? 48 : 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: tv ? 760 : 480),
              child: Material(
                key: PlayerKeys.playbackEnded,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: EdgeInsets.all(tv ? 32 : 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.replay_rounded,
                        size: tv ? 48 : 32,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          l.playbackEnded,
                          style: tv
                              ? theme.textTheme.headlineMedium
                              : theme.textTheme.titleLarge,
                        ),
                      ),
                      if (title.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: tv ? 22 : null,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FocusTraversalGroup(
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.center,
                          children: tv
                              ? [
                                  TvAction(
                                    key: PlayerKeys.replay,
                                    focusNode: replayFocus,
                                    autofocus: true,
                                    onPressed: onReplay,
                                    child: _TvLabel(
                                      Icons.replay_rounded,
                                      l.replay,
                                    ),
                                  ),
                                  if (onViewSeries != null)
                                    TvAction(
                                      key: PlayerKeys.endedViewSeries,
                                      onPressed: onViewSeries,
                                      child: _TvLabel(
                                        Icons.video_library_outlined,
                                        l.viewSeries,
                                      ),
                                    ),
                                  TvAction(
                                    key: PlayerKeys.endedClose,
                                    onPressed: onClose,
                                    child: _TvLabel(
                                      Icons.close_rounded,
                                      l.closePlayer,
                                    ),
                                  ),
                                ]
                              : [
                                  FilledButton.icon(
                                    key: PlayerKeys.replay,
                                    onPressed: onReplay,
                                    icon: const Icon(Icons.replay_rounded),
                                    label: Text(l.replay),
                                  ),
                                  if (onViewSeries != null)
                                    OutlinedButton.icon(
                                      key: PlayerKeys.endedViewSeries,
                                      onPressed: onViewSeries,
                                      icon: const Icon(
                                        Icons.video_library_outlined,
                                      ),
                                      label: Text(l.viewSeries),
                                    ),
                                  Tooltip(
                                    message: l.closePlayer,
                                    child: OutlinedButton.icon(
                                      key: PlayerKeys.endedClose,
                                      onPressed: onClose,
                                      icon: const Icon(Icons.close_rounded),
                                      label: Text(l.closePlayer),
                                    ),
                                  ),
                                ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvLabel extends StatelessWidget {
  const _TvLabel(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 28),
        const SizedBox(width: 10),
        Text(text, style: const TextStyle(fontSize: 22)),
      ],
    ),
  );
}
