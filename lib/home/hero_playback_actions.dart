import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/player_window_host.dart';

/// The resume action and details action share one predictable row.
class HeroPlaybackActions extends StatefulWidget {
  const HeroPlaybackActions({
    super.key,
    required this.item,
    required this.onDetails,
  });
  final EmbyItem item;
  final VoidCallback onDetails;

  @override
  State<HeroPlaybackActions> createState() => _HeroPlaybackActionsState();
}

class _HeroPlaybackActionsState extends State<HeroPlaybackActions> {
  bool _opening = false;

  Future<void> _resume() async {
    if (_opening) return;
    final host = PlayerWindowScope.maybeOf(context);
    setState(() => _opening = true);
    try {
      if (host == null) throw StateError('Player host unavailable');
      await host.open(
        PlayerOpenRequest(itemId: widget.item.id, autoResume: true),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).playbackFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.item.canResume) ...[
          Flexible(
            child: FilledButton.icon(
              key: ValueKey('hero-resume-${widget.item.id}'),
              onPressed: _opening ? null : _resume,
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 20),
              label: Text(
                l10n.resumePlay,
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          child: OutlinedButton(
            onPressed: widget.onDetails,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            child: Text(l10n.details),
          ),
        ),
      ],
    );
  }
}
