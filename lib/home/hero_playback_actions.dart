import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/player/player_window_host.dart';

/// 轮播的「播放」要落到一条可播的流。电影直接可播;剧集按详情页同样的
/// 规则解析出该播的那一集(有进度的接着看,否则第一集未看的)。
/// 没有可播集时返回 null,调用方提示 [AppLocalizations.noPlayableStream]。
Future<EmbyItem?> resolveHeroPlayTarget(
  BuildContext context,
  EmbyItem item, {
  CatalogController? catalog,
}) async {
  if (!item.isSeries) {
    return item.isPlayable ? item : null;
  }
  final cache = (catalog ?? CatalogScope.maybeOf(context))?.cache;
  if (cache == null) return null;
  final controller = DetailController(
    auth: AuthScope.of(context),
    cache: cache,
    itemId: item.id,
  );
  try {
    controller.applyItem(item);
    await controller.loadSeasons();
    await controller.retainOffPageResume();
    final resolved = controller.playTarget;
    return resolved != null && resolved.isPlayable ? resolved : null;
  } finally {
    controller.dispose();
  }
}

/// The play action and details action share one predictable row.
///
/// The hero promotes catalog titles, not viewing history: the label always
/// reads "播放" even when a saved position exists. Playback itself still
/// resumes from that position through `autoResume`.
class HeroPlaybackActions extends StatefulWidget {
  const HeroPlaybackActions({
    super.key,
    required this.item,
    required this.onDetails,
    this.onResume,
    this.catalog,
    this.expand = false,
  });
  final EmbyItem item;
  final VoidCallback onDetails;

  /// Phone navigation owns a route; desktop callers use the window host.
  final Future<void> Function()? onResume;

  /// Series resolution needs the catalog cache; falls back to [CatalogScope].
  final CatalogController? catalog;

  /// Phone layout: fill the row width instead of hugging the content.
  final bool expand;

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
        final target = await resolveHeroPlayTarget(
          context,
          widget.item,
          catalog: widget.catalog,
        );
        if (!mounted) return;
        if (target == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).noPlayableStream),
            ),
          );
          return;
        }
        await host.open(PlayerOpenRequest(itemId: target.id, autoResume: true));
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
    final scheme = Theme.of(context).colorScheme;
    final expand = widget.expand;
    // 桌面/TV 的按钮压在深色遮罩上,前景固定白;手机版式落在页面底色上,
    // 跟随主题取色。
    final onScrim = !expand;
    final play = FilledButton.icon(
      key: ValueKey('hero-resume-${widget.item.id}'),
      onPressed: _opening ? null : _resume,
      icon: _opening
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_rounded, size: 22),
      label: Text(
        l10n.play,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // 只加粗,字族与中文回退仍走主题;整段替换 textStyle 会在
        // 手机上把「播放」画成方框。
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: onScrim ? Colors.white : null,
        foregroundColor: onScrim ? Colors.black : null,
      ),
    );
    final details = onScrim
        ? OutlinedButton(
            onPressed: widget.onDetails,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: .16),
              side: BorderSide(color: Colors.white.withValues(alpha: .28)),
            ),
            child: Text(l10n.details),
          )
        : FilledButton.tonal(
            onPressed: widget.onDetails,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: scheme.surfaceContainerHighest,
              foregroundColor: scheme.onSurface,
            ),
            child: Text(l10n.details),
          );
    if (expand) {
      return Row(
        children: [
          Expanded(flex: 3, child: play),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: details),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(flex: 3, child: play),
        const SizedBox(width: 12),
        Flexible(flex: 2, child: details),
      ],
    );
  }
}
