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
import 'package:rillight/library/item_format.dart';
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
  String? _seasonId;
  bool _loading = true;
  bool _busyPlayed = false;
  EmbyException? _error;

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
      _seasons = const [];
      _episodes = const [];
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
      if (!mounted) {
        return;
      }
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _seasonId = seasonId;
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: MediaImage(item: item, width: 160, height: 240),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      itemTitle(item),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (item.isEpisode) ...[
                      const SizedBox(height: 8),
                      Text(episodeLabel(item)),
                      if (item.seriesName != null)
                        Text(
                          item.seriesName!,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                    ],
                    if (runtime != null) ...[
                      const SizedBox(height: 8),
                      Text(runtime),
                    ],
                    if (item.childCount != null && item.isSeries) ...[
                      const SizedBox(height: 8),
                      Text(l10n.episodeCount(item.childCount!)),
                    ],
                    if (item.canResume) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.playbackProgress(
                          (item.playbackProgress * 100).round(),
                        ),
                        key: CatalogKeys.resumeProgress,
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (item.isPlayable)
                      FilledButton.icon(
                        key: PlayerKeys.open,
                        onPressed: () => context.push(AppRoutes.play(item.id)),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                          item.canResume ? l10n.resumePlay : l10n.play,
                        ),
                      ),
                    if (item.isPlayable) const SizedBox(height: 8),
                    SwitchListTile(
                      key: CatalogKeys.playedToggle,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        item.userData.played
                            ? l10n.markUnplayed
                            : l10n.markPlayed,
                      ),
                      value: item.userData.played,
                      onChanged: _busyPlayed
                          ? null
                          : (value) {
                              _setPlayed(value);
                            },
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (item.overview != null && item.overview!.trim().isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(l10n.overview, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(item.overview!),
          ],
          if (item.isSeries) ...[
            const SizedBox(height: 24),
            Text(l10n.seasons, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
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
            const SizedBox(height: 12),
            for (final episode in _episodes)
              ListTile(
                key: CatalogKeys.episode(episode.id),
                title: Text(episodeLabel(episode)),
                subtitle: episode.userData.played
                    ? Text(l10n.markPlayed)
                    : null,
                onTap: () => context.push(AppRoutes.item(episode.id)),
              ),
          ],
        ],
      ),
    );
  }
}
