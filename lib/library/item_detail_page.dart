import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({super.key, required this.itemId});

  final String itemId;

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  EmbyItem? _item;
  List<EmbyItem> _seasons = const [];
  List<EmbyItem> _episodes = const [];
  List<EmbyItem> _similar = const [];
  String? _seasonId;
  bool _loading = true;
  bool _busyPlayed = false;
  EmbyException? _error;
  EmbyException? _similarError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void didUpdateWidget(ItemDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _similarError = null;
      _seasons = const [];
      _episodes = const [];
      _similar = const [];
      _seasonId = null;
    });
    final client = AuthScope.of(context).client;
    try {
      final item = await client.getItem(widget.itemId);
      var seasons = const <EmbyItem>[];
      var episodes = const <EmbyItem>[];
      String? seasonId;
      if (item.isSeries) {
        seasons = await client.getItems(
          parentId: item.id,
          includeItemTypes: 'Season',
          sortBy: 'IndexNumber',
          sortOrder: 'Ascending',
        );
        if (seasons.isNotEmpty) {
          seasonId = seasons.first.id;
          episodes = await client.getItems(
            parentId: seasonId,
            includeItemTypes: 'Episode',
            sortBy: 'IndexNumber',
            sortOrder: 'Ascending',
          );
        }
      }
      var similar = const <EmbyItem>[];
      EmbyException? similarError;
      try {
        similar = (await client.getSimilar(
          item.id,
          limit: 24,
        )).where((entry) => entry.id != item.id).toList();
      } on EmbyException catch (error) {
        if (_hideSimilar(error)) {
          similar = const [];
        } else {
          similarError = error;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _seasonId = seasonId;
        _similar = similar;
        _similarError = similarError;
        _loading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() {
      _seasonId = seasonId;
      _episodes = const [];
    });
    try {
      final episodes = await AuthScope.of(context).client.getItems(
        parentId: seasonId,
        includeItemTypes: 'Episode',
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
      );
      if (!mounted) {
        return;
      }
      setState(() => _episodes = episodes);
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _setPlayed(bool played) async {
    final item = _item;
    if (item == null || _busyPlayed) {
      return;
    }
    setState(() => _busyPlayed = true);
    final client = AuthScope.of(context).client;
    try {
      if (played) {
        await client.markPlayed(item.id);
      } else {
        await client.markUnplayed(item.id);
      }
      final updated = await client.getItem(item.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _item = updated;
        _busyPlayed = false;
      });
      await CatalogScope.maybeOf(context)?.reloadHomeRows();
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _busyPlayed = false;
      });
    }
  }

  bool _hideSimilar(EmbyException error) {
    final code = error.statusCode;
    return code == 404 || code == 400 || code == 501;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const SizedBox.expand();
    }
    final error = _error;
    if (error != null && _item == null) {
      final message = error.statusCode == 404
          ? l10n.itemUnavailable
          : catalogFailureMessage(l10n, error);
      return AppErrorView(message: message, onRetry: _load);
    }
    final item = _item;
    if (item == null) {
      return AppErrorView(message: l10n.itemUnavailable, onRetry: _load);
    }

    final runtime = runtimeLabel(l10n, item);
    final showSimilar = _similar.isNotEmpty || _similarError != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: CatalogKeys.back,
              tooltip: 'Back',
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go(AppRoutes.home);
                }
              },
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _Hero(
              item: item,
              runtime: runtime,
              busyPlayed: _busyPlayed,
              onPlay: item.isPlayable
                  ? () => context.push(AppRoutes.play(item.id))
                  : null,
              onPlayedChanged: (value) {
                _setPlayed(value);
              },
            ),
          ),
          if (item.isSeries) ...[
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                l10n.seasons,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final season in _seasons)
                    ChoiceChip(
                      key: CatalogKeys.season(season.id),
                      label: Text(season.name),
                      selected: season.id == _seasonId,
                      onSelected: (_) => _selectSeason(season.id),
                    ),
                ],
              ),
            ),
            if (_episodes.isNotEmpty) ...[
              const SizedBox(height: 16),
              MediaShelf(
                rowKey: CatalogKeys.episodesRow,
                shelfId: CatalogKeys.shelfEpisodes,
                title: l10n.episodesRow,
                items: _episodes,
                onTap: (episode) => context.push(AppRoutes.item(episode.id)),
                onMore: _seasonId == null
                    ? null
                    : () => context.push(
                        AppRoutes.shelfItems(
                          parentId: _seasonId,
                          includeItemTypes: 'Episode',
                          title: l10n.episodesRow,
                        ),
                      ),
                itemBuilder: (context, episode) {
                  return KeyedSubtree(
                    key: CatalogKeys.episode(episode.id),
                    child: PosterCard(
                      item: episode,
                      onTap: () => context.push(AppRoutes.item(episode.id)),
                    ),
                  );
                },
              ),
            ],
          ],
          if (showSimilar)
            MediaShelf(
              rowKey: CatalogKeys.similarRow,
              shelfId: CatalogKeys.shelfSimilar,
              title: l10n.similarRow,
              items: _similar,
              error: _similarError,
              onRetry: _load,
              onTap: (similar) => context.push(AppRoutes.item(similar.id)),
              onMore: () => context.push(
                AppRoutes.shelfSimilar(item.id, title: l10n.similarRow),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.item,
    required this.runtime,
    required this.busyPlayed,
    required this.onPlay,
    required this.onPlayedChanged,
  });

  final EmbyItem item;
  final String? runtime;
  final bool busyPlayed;
  final VoidCallback? onPlay;
  final ValueChanged<bool> onPlayedChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 280,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaImage(item: item, height: 280),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xCC000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 20,
                  child: Text(
                    itemTitle(item),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (item.isEpisode) ...[
          Text(episodeLabel(item)),
          if (item.seriesName != null)
            Text(item.seriesName!, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            if (runtime != null) Text(runtime!),
            if (item.childCount != null && item.isSeries)
              Text(l10n.episodeCount(item.childCount!)),
            if (item.canResume)
              Text(
                l10n.playbackProgress((item.playbackProgress * 100).round()),
                key: CatalogKeys.resumeProgress,
              ),
          ],
        ),
        if (item.overview != null && item.overview!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            item.overview!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (onPlay != null)
          FilledButton.icon(
            key: PlayerKeys.open,
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow),
            label: Text(item.canResume ? l10n.resumePlay : l10n.play),
          ),
        if (item.isPlayable) const SizedBox(height: 8),
        SwitchListTile(
          key: CatalogKeys.playedToggle,
          contentPadding: EdgeInsets.zero,
          title: Text(
            item.userData.played ? l10n.markUnplayed : l10n.markPlayed,
          ),
          value: item.userData.played,
          onChanged: busyPlayed ? null : onPlayedChanged,
        ),
      ],
    );
  }
}
