import 'dart:async';
import 'dart:typed_data';

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
import 'package:rillight/player/player_window_host.dart';

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
  String? _mediaSourceId;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;

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
      _mediaSourceId = null;
      _audioStreamIndex = null;
      _subtitleStreamIndex = null;
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
        _mediaSourceId = item.mediaSources.isEmpty
            ? null
            : item.mediaSources.first.id;
        _audioStreamIndex = _defaultAudio(item, _mediaSourceId);
        _subtitleStreamIndex = _defaultSubtitle(item, _mediaSourceId);
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

  Future<void> _openPlayer(String itemId, {int? startTimeTicks}) async {
    try {
      await PlayerWindowScope.of(context).open(
        PlayerOpenRequest(
          itemId: itemId,
          mediaSourceId: _mediaSourceId,
          audioStreamIndex: _audioStreamIndex,
          subtitleStreamIndex: _subtitleStreamIndex,
          startTimeTicks: startTimeTicks,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString(), key: PlayerKeys.windowError)),
      );
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

  EmbyItem? _playTarget(EmbyItem item) {
    if (item.isPlayable) {
      return item;
    }
    if (!item.isSeries) {
      return null;
    }
    for (final episode in _episodes) {
      if (episode.canResume) {
        return episode;
      }
    }
    if (_episodes.isNotEmpty) {
      return _episodes.first;
    }
    return null;
  }

  int? _defaultAudio(EmbyItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final audios = source?.audioStreams ?? const [];
    return audios.isEmpty ? null : audios.first.index;
  }

  int? _defaultSubtitle(EmbyItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final subs = source?.subtitleStreams ?? const [];
    return subs.isEmpty ? null : subs.first.index;
  }

  ItemMediaSource? _sourceById(EmbyItem item, String? sourceId) {
    if (item.mediaSources.isEmpty) {
      return null;
    }
    if (sourceId == null || sourceId.isEmpty) {
      return item.mediaSources.first;
    }
    for (final source in item.mediaSources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return item.mediaSources.first;
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
    final playTarget = _playTarget(item);
    final continueWatching = [
      for (final episode in _episodes)
        if (episode.canResume) episode,
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Hero(
            item: item,
            runtime: runtime,
            seasonCount: _seasons.length,
            nextEpisode: playTarget != null && item.isSeries
                ? playTarget
                : null,
            busyPlayed: _busyPlayed,
            mediaSourceId: _mediaSourceId,
            audioStreamIndex: _audioStreamIndex,
            subtitleStreamIndex: _subtitleStreamIndex,
            onBack: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(AppRoutes.home);
              }
            },
            onMediaSource: (id) {
              setState(() {
                _mediaSourceId = id;
                _audioStreamIndex = _defaultAudio(item, id);
                _subtitleStreamIndex = _defaultSubtitle(item, id);
              });
            },
            onAudio: (index) => setState(() => _audioStreamIndex = index),
            onSubtitle: (index) =>
                setState(() => _subtitleStreamIndex = index),
            onPlay: playTarget == null
                ? null
                : () => _openPlayer(playTarget.id),
            onPlayedChanged: (value) {
              _setPlayed(value);
            },
          ),
          if (item.chapters.isNotEmpty)
            _ChapterRow(
              itemId: item.id,
              chapters: item.chapters,
              onSelect: (chapter) {
                final target = playTarget ?? item;
                if (target.isPlayable) {
                  _openPlayer(
                    target.id,
                    startTimeTicks: chapter.startPositionTicks,
                  );
                }
              },
            ),
          if (item.isSeries) ...[
            if (continueWatching.isNotEmpty)
              MediaShelf(
                rowKey: CatalogKeys.resumeRow,
                shelfId: '${CatalogKeys.shelfEpisodes}-resume',
                title: l10n.resumeRow,
                items: continueWatching,
                wide: true,
                extent: 146,
                onTap: (episode) => context.push(AppRoutes.item(episode.id)),
                itemBuilder: (context, episode) {
                  return EpisodeThumbCard(
                    item: episode,
                    onTap: () => context.push(AppRoutes.item(episode.id)),
                  );
                },
              ),
            if (_episodes.isNotEmpty)
              MediaShelf(
                rowKey: CatalogKeys.episodesRow,
                shelfId: CatalogKeys.shelfEpisodes,
                title: l10n.episodesRow,
                items: _episodes,
                wide: true,
                extent: 146,
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
                  return EpisodeThumbCard(
                    item: episode,
                    onTap: () => context.push(AppRoutes.item(episode.id)),
                  );
                },
              ),
            if (_seasons.isNotEmpty)
              MediaShelf(
                shelfId: 'seasons',
                title: l10n.seasons,
                items: _seasons,
                extent: 228,
                onTap: (season) => _selectSeason(season.id),
                itemBuilder: (context, season) {
                  return SeasonPosterCard(
                    item: season,
                    selected: season.id == _seasonId,
                    onTap: () => _selectSeason(season.id),
                  );
                },
              ),
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
    required this.onBack,
    this.seasonCount = 0,
    this.nextEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
  });

  final EmbyItem item;
  final String? runtime;
  final bool busyPlayed;
  final VoidCallback? onPlay;
  final ValueChanged<bool> onPlayedChanged;
  final VoidCallback onBack;
  final int seasonCount;
  final EmbyItem? nextEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 420,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(
                item: item,
                height: 420,
                preferBackdrop: true,
                maxWidth: 1600,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.center,
                    colors: [Color(0xF2000000), Color(0x00000000)],
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  key: CatalogKeys.back,
                  tooltip: 'Back',
                  color: Colors.white,
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              Positioned(
                left: 28,
                right: 28,
                bottom: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (onPlay != null) ...[
                      FilledButton.icon(
                        key: PlayerKeys.open,
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                          item.canResume ? l10n.resumePlay : l10n.play,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (nextEpisode != null && item.isSeries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          episodeLabel(nextEpisode!),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    Text(
                      itemTitle(item),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.isSeries && seasonCount > 0)
                      Text(
                        l10n.seasonCount(seasonCount),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
        if (item.mediaSources.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<String>(
              key: ValueKey('source-${mediaSourceId ?? item.mediaSources.first.id}'),
              decoration: InputDecoration(labelText: l10n.mediaSource),
              initialValue: mediaSourceId ?? item.mediaSources.first.id,
              items: [
                for (final source in item.mediaSources)
                  DropdownMenuItem(
                    value: source.id,
                    child: Text(source.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onMediaSource?.call(value);
                }
              },
            ),
          ),
        if (_audioChoices(item, mediaSourceId).length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<int>(
              key: ValueKey('audio-$mediaSourceId-$audioStreamIndex'),
              decoration: InputDecoration(labelText: l10n.audioTrack),
              initialValue: audioStreamIndex,
              items: [
                for (final stream in _audioChoices(item, mediaSourceId))
                  DropdownMenuItem(
                    value: stream.index,
                    child: Text(stream.label ?? '#${stream.index}'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onAudio?.call(value);
                }
              },
            ),
          ),
        if (_subtitleChoices(item, mediaSourceId).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<int?>(
              decoration: InputDecoration(labelText: l10n.subtitleTrack),
              initialValue: subtitleStreamIndex,
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text(l10n.subtitleOff),
                ),
                for (final stream in _subtitleChoices(item, mediaSourceId))
                  DropdownMenuItem<int?>(
                    value: stream.index,
                    child: Text(stream.label ?? '#${stream.index}'),
                  ),
              ],
              onChanged: onSubtitle,
            ),
          ),
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
          ),
        ),
      ],
    );
  }
}

List<ItemMediaStream> _audioChoices(EmbyItem item, String? sourceId) {
  if (item.mediaSources.isEmpty) {
    return const [];
  }
  var source = item.mediaSources.first;
  if (sourceId != null) {
    for (final candidate in item.mediaSources) {
      if (candidate.id == sourceId) {
        source = candidate;
        break;
      }
    }
  }
  return source.audioStreams;
}

List<ItemMediaStream> _subtitleChoices(EmbyItem item, String? sourceId) {
  if (item.mediaSources.isEmpty) {
    return const [];
  }
  var source = item.mediaSources.first;
  if (sourceId != null) {
    for (final candidate in item.mediaSources) {
      if (candidate.id == sourceId) {
        source = candidate;
        break;
      }
    }
  }
  return source.subtitleStreams;
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.itemId,
    required this.chapters,
    required this.onSelect,
  });

  final String itemId;
  final List<ItemChapter> chapters;
  final ValueChanged<ItemChapter> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.chapters,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 148,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: chapters.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final chapter = chapters[index];
                return _ChapterCard(
                  itemId: itemId,
                  index: index,
                  chapter: chapter,
                  onTap: () => onSelect(chapter),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({
    required this.itemId,
    required this.index,
    required this.chapter,
    required this.onTap,
  });

  final String itemId;
  final int index;
  final ItemChapter chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const width = 168.0;
    const height = 94.0;
    return SizedBox(
      width: width,
      child: InkWell(
        key: CatalogKeys.chapter(index),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: width,
                height: height,
                child: ColoredBox(
                  color: const Color(0xFF2A2A2A),
                  child: _ChapterImage(
                    itemId: itemId,
                    index: index,
                    tag: chapter.imageTag,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              chapter.name.isEmpty ? 'Chapter ${index + 1}' : chapter.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              chapterClock(chapter.startPositionTicks),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(
                  alpha: 0.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChapterImage extends StatefulWidget {
  const _ChapterImage({
    required this.itemId,
    required this.index,
    this.tag,
  });

  final String itemId;
  final int index;
  final String? tag;

  @override
  State<_ChapterImage> createState() => _ChapterImageState();
}

class _ChapterImageState extends State<_ChapterImage> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<Uint8List?> _load() async {
    try {
      final bytes = await AuthScope.of(context).client.getChapterImage(
        widget.itemId,
        index: widget.index,
        tag: widget.tag,
      );
      if (bytes.isEmpty) {
        return null;
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return const Center(
            child: Icon(Icons.menu_book_outlined, color: Colors.white54),
          );
        }
        return Image.memory(bytes, fit: BoxFit.cover);
      },
    );
  }
}
