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
    this.onResume,
  });
  final EmbyItem item;
  final VoidCallback onDetails;

  /// Phone navigation owns a route; desktop callers use the window host.
  final Future<void> Function()? onResume;

  @override
  State<HeroPlaybackActions> createState() => _HeroPlaybackActionsState();
}

class _HeroPlaybackActionsState extends State<HeroPlaybackActions> {
  bool _opening = false;

  Future<void> _resume() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final resume = widget.onResume;
      if (resume != null) {
        await resume();
      } else {
        final host = PlayerWindowScope.maybeOf(context);
        if (host == null) throw StateError('Player host unavailable');
        await host.open(
          PlayerOpenRequest(itemId: widget.item.id, autoResume: true),
        );
      }
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
        if (widget.item.canResume || widget.onResume != null) ...[
          Flexible(
            flex: 3,
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
                widget.item.canResume ? l10n.resumePlay : l10n.play,
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          flex: 2,
          child: OutlinedButton(
            onPressed: widget.onDetails,
            // 按钮总在深色遮罩上,不随应用明/暗主题取前景色。
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: Colors.white,
              backgroundColor: Colors.black.withValues(alpha: .18),
              side: BorderSide(color: Colors.white.withValues(alpha: .7)),
            ),
            child: Text(l10n.details),
          ),
        ),
      ],
    );
  }
}
