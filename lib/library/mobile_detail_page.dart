import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

class MobileDetailPage extends StatefulWidget {
  const MobileDetailPage({
    super.key,
    required this.itemId,
    this.initialSeasonId,
  });
  final String itemId;
  final String? initialSeasonId;
  @override
  State<MobileDetailPage> createState() => _MobileDetailPageState();
}

class _MobileDetailPageState extends State<MobileDetailPage> {
  DetailController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      _controller = DetailController(
        auth: AuthScope.of(context),
        cache: CatalogScope.of(context).cache,
        itemId: widget.itemId,
        seasonId: widget.initialSeasonId,
      );
      _controller!.load();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play({bool fromStart = false}) async {
    final c = _controller!, target = _controller!.playTarget;
    if (target == null) return;
    await context.push(
      '/play/${target.id}',
      extra: PlayerOpenRequest(
        itemId: target.id,
        mediaSourceId: c.item?.isSeries == true ? null : c.mediaSourceId,
        autoResume: !fromStart,
      ),
    );
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    c.load();
    CatalogScope.of(context).reloadHomeRows();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = _controller!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final item = c.item, target = c.playTarget;
        return Scaffold(
          appBar: AppBar(title: Text(item?.name ?? l.playerLoading)),
          bottomNavigationBar: item == null
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      key: const Key('mobile-detail-play'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 52),
                      ),
                      onPressed:
                          target != null && (target.isMovie || target.isEpisode)
                          ? _play
                          : null,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        target == null
                            ? l.noPlayableStream
                            : target.canResume
                            ? l.resumePlay
                            : l.play,
                      ),
                    ),
                  ),
                ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: c.load,
              child: ListView(
                key: PageStorageKey('detail-${widget.itemId}'),
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (c.loading) const LinearProgressIndicator(),
                  if (c.error != null)
                    MobileFailure(error: c.error!, retry: c.load),
                  if (item != null) ...[
                    Center(
                      child: SizedBox(
                        width: 210,
                        height: 300,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: MediaImage(item: item, maxWidth: 480),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      item.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        if (item.productionYear != null)
                          '${item.productionYear}',
                        if (item.isEpisode) episodeLabel(item),
                      ].join(' · '),
                    ),
                    const SizedBox(height: 16),
                    if (item.overview?.isNotEmpty == true) Text(item.overview!),
                    if (target?.canResume == true)
                      TextButton(
                        onPressed: () => _play(fromStart: true),
                        child: Text(l.playFromStart),
                      ),
                    if (item.mediaSources.length > 1) ...[
                      const SizedBox(height: 20),
                      DropdownButtonFormField<String>(
                        initialValue: c.mediaSourceId,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: l.mediaSource),
                        items: [
                          for (final source in item.mediaSources)
                            DropdownMenuItem(
                              value: source.id,
                              child: Text(
                                source.name ?? source.id,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) c.selectSource(value);
                        },
                      ),
                    ],
                    if (item.isSeries) ...[
                      const SizedBox(height: 24),
                      if (c.seasons.isNotEmpty)
                        DropdownButtonFormField<String>(
                          initialValue: c.seasonId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l.playerEpisodes,
                          ),
                          items: [
                            for (final season in c.seasons)
                              DropdownMenuItem(
                                value: season.id,
                                child: Text(season.name),
                              ),
                          ],
                          onChanged: (id) {
                            if (id != null) c.selectSeason(id);
                          },
                        ),
                      if (c.episodesLoading) const LinearProgressIndicator(),
                      if (c.episodeError != null)
                        MobileFailure(
                          error: c.episodeError!,
                          retry: () => c.selectSeason(
                            c.seasonId!,
                            more: c.episodes.isNotEmpty && c.hasMore,
                          ),
                        ),
                      if (!c.episodesLoading && c.episodes.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(l.mobileEmpty),
                        ),
                      for (final episode in c.episodes)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          minVerticalPadding: 12,
                          leading: const Icon(Icons.play_circle_outline),
                          title: Text(episode.name),
                          subtitle: Text(episodeLabel(episode)),
                          onTap: () => context.push(AppRoutes.item(episode.id)),
                        ),
                      if (c.hasMore)
                        FilledButton(
                          onPressed: c.episodesLoading
                              ? null
                              : () => c.selectSeason(c.seasonId!, more: true),
                          child: Text(l.mobileLoadMore),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
