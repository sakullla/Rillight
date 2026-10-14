import 'package:rillight/app/ui/ui.dart';
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: const Color(0xdd000000),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(tv ? 48 : 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: tv ? 760 : 480),
              child: Container(
                key: PlayerKeys.playbackEnded,
                decoration: BoxDecoration(color: scheme.surfaceContainerLow),
                child: Padding(
                  padding: EdgeInsets.all(tv ? 32 : 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.arrow_counterclockwise,
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
                                      CupertinoIcons.arrow_counterclockwise,
                                      l.replay,
                                    ),
                                  ),
                                  if (onViewSeries != null)
                                    TvAction(
                                      key: PlayerKeys.endedViewSeries,

                                      onPressed: onViewSeries,
                                      child: _TvLabel(
                                        CupertinoIcons.film,
                                        l.viewSeries,
                                      ),
                                    ),
                                  TvAction(
                                    key: PlayerKeys.endedClose,
                                    onPressed: onClose,
                                    child: _TvLabel(
                                      CupertinoIcons.xmark,
                                      l.closePlayer,
                                    ),
                                  ),
                                ]
                              : [
                                  AppButton.icon(
                                    key: PlayerKeys.replay,
                                    variant: AppButtonVariant.filled,
                                    onPressed: onReplay,
                                    icon: const Icon(
                                      CupertinoIcons.arrow_counterclockwise,
                                    ),
                                    label: Text(l.replay),
                                  ),
                                  if (onViewSeries != null)
                                    AppButton.icon(
                                      key: PlayerKeys.endedViewSeries,
                                      variant: AppButtonVariant.outlined,
                                      onPressed: onViewSeries,
                                      icon: const Icon(CupertinoIcons.film),
                                      label: Text(l.viewSeries),
                                    ),
                                  AppTooltip(
                                    message: l.closePlayer,
                                    child: AppButton.icon(
                                      key: PlayerKeys.endedClose,
                                      onPressed: onClose,
                                      icon: const Icon(CupertinoIcons.xmark),
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
