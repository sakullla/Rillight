import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 详情页日期统一格式:yyyy-MM-dd(播出日期胶囊与元数据分区共用)。
String formatDateYmd(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// 分区骨架:标题 + 内容,左右对齐页面 [AppSpacing.page] 边距。
/// 与 `_ChapterStrip` 同一条竖线,数据为空的分区由调用方整段隐藏。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// 概览分区:默认 3 行截断,超长时提供展开/收起。
///
/// [compact] 为 true 时不带分区标题与页面边距,直接嵌入 hero 信息栏。
class EpisodeOverviewSection extends StatefulWidget {
  const EpisodeOverviewSection({
    super.key,
    required this.overview,
    this.compact = false,
  });

  /// 正文文本,供测试断言 maxLines。
  static const textKey = Key('episode-overview-text');

  /// 展开/收起按钮。
  static const toggleKey = Key('episode-overview-toggle');

  static const _collapsedLines = 3;

  final String? overview;
  final bool compact;

  @override
  State<EpisodeOverviewSection> createState() => _EpisodeOverviewSectionState();
}

class _EpisodeOverviewSectionState extends State<EpisodeOverviewSection> {
  bool _expanded = false;

  bool _exceedsCollapsedLines(
    BuildContext context,
    double maxWidth,
    TextStyle? style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: widget.overview, style: style),
      maxLines: EpisodeOverviewSection._collapsedLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overview = widget.overview;
    if (overview == null || overview.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.55,
    );
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final toggleable =
            _expanded ||
            _exceedsCollapsedLines(context, constraints.maxWidth, style);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              overview,
              key: EpisodeOverviewSection.textKey,
              maxLines: _expanded
                  ? null
                  : EpisodeOverviewSection._collapsedLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: style,
            ),
            if (toggleable)
              TextButton(
                key: EpisodeOverviewSection.toggleKey,
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelLarge,
                ),
                child: Text(_expanded ? l10n.collapse : l10n.expand),
              ),
          ],
        );
      },
    );
    if (widget.compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          0,
        ),
        child: body,
      );
    }
    return _Section(title: l10n.detailOverview, child: body);
  }
}

/// 窄屏横滑一次只露出放得下的整数张卡片。
///
/// 剩余宽度留白，下一张整页留在外面。滑到最后一页时卡片靠右，
/// 右侧边距与行首相同。宽屏换行不走这里。
class WholeCardStrip extends StatelessWidget {
  const WholeCardStrip({
    super.key,
    required this.itemCount,
    required this.cardWidth,
    required this.gap,
    required this.height,
    required this.itemBuilder,
    this.margin = 0,
  });

  final int itemCount;
  final double cardWidth;
  final double gap;
  final double height;
  final double margin;
  final IndexedWidgetBuilder itemBuilder;

  int _perPage(double viewport) {
    final inner = viewport - margin * 2;
    if (inner <= cardWidth || cardWidth <= 0) {
      return 1;
    }
    var count = ((inner + gap) / (cardWidth + gap)).floor();
    if (count < 1) {
      count = 1;
    }
    while (count > 1 && count * cardWidth + (count - 1) * gap > inner + 0.1) {
      count--;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    if (itemCount <= 0) {
      return SizedBox(height: height);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        if (!viewport.isFinite || viewport <= 0) {
          return SizedBox(height: height);
        }
        final perPage = _perPage(viewport);
        final pages = (itemCount + perPage - 1) ~/ perPage;
        return SizedBox(
          height: height,
          child: PageView.builder(
            itemCount: pages,
            padEnds: false,
            itemBuilder: (context, page) {
              final start = page * perPage;
              final end = start + perPage > itemCount
                  ? itemCount
                  : start + perPage;
              final children = <Widget>[];
              for (var index = start; index < end; index++) {
                if (children.isNotEmpty) {
                  children.add(SizedBox(width: gap));
                }
                children.add(itemBuilder(context, index));
              }
              final alignEnd = pages > 1 && page == pages - 1;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: margin),
                child: Row(
                  mainAxisAlignment: alignEnd
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  children: children,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 演职员分区:按类型分组(演员/导演/编剧/其他),头像 + 名字 + 角色,
/// 无图条目文字首字兜底。
class EpisodePeopleSection extends StatelessWidget {
  const EpisodePeopleSection({super.key, required this.people});

  static const sectionKey = Key('episode-people');

  final List<ItemPerson> people;

  /// 分组顺序:演员 → 导演 → 编剧 → 其他。
  static const _typeOrder = ['Actor', 'Director', 'Writer'];

  String _groupLabel(AppLocalizations l10n, String? type) {
    return switch (type) {
      'Actor' => l10n.personTypeActor,
      'Director' => l10n.personTypeDirector,
      'Writer' => l10n.personTypeWriter,
      _ => l10n.personTypeOther,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (people.isEmpty) {
      return const SizedBox.shrink();
    }
    final groups = <String, List<ItemPerson>>{};
    for (final person in people) {
      final type = _typeOrder.contains(person.type) ? person.type! : '';
      groups.putIfAbsent(type, () => []).add(person);
    }
    final orderedTypes = [
      for (final type in _typeOrder)
        if (groups.containsKey(type)) type,
      if (groups.containsKey('')) '',
    ];
    // 宽屏各组并排换行。手机宽度不够时改成每组一条横滑，避免三列把头像和名字挤断。
    return _Section(
      title: l10n.detailCast,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 600;
          if (narrow) {
            final textScale = MediaQuery.textScalerOf(context).scale(1);
            final rowHeight =
                _PersonAvatar.size + AppSpacing.xs + (22 + 18) * textScale;
            return Column(
              key: sectionKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final type in orderedTypes) ...[
                  Text(
                    _groupLabel(l10n, type.isEmpty ? null : type),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  WholeCardStrip(
                    height: rowHeight,
                    itemCount: groups[type]!.length,
                    cardWidth: 112,
                    gap: AppSpacing.md,
                    itemBuilder: (context, index) {
                      final person = groups[type]![index];
                      return _PersonChip(
                        key: ValueKey('episode-person-$type-$index'),
                        person: person,
                        width: 112,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            );
          }
          return Wrap(
            key: sectionKey,
            spacing: AppSpacing.xxxl,
            runSpacing: AppSpacing.lg,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              for (final type in orderedTypes)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _groupLabel(l10n, type.isEmpty ? null : type),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.md,
                      children: [
                        for (
                          var index = 0;
                          index < groups[type]!.length;
                          index++
                        )
                          _PersonChip(
                            key: ValueKey('episode-person-$type-$index'),
                            person: groups[type]![index],
                          ),
                      ],
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({super.key, required this.person, this.width = 104});

  final ItemPerson person;

  /// 卡宽:头像 + 两行居中文字。手机横滑行用更宽的一档，避免英文名被切成半个词。
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = person.role?.trim();
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PersonAvatar(person: person),
          const SizedBox(height: AppSpacing.xs),
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge,
          ),
          if (role != null && role.isNotEmpty)
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 演职员头像:有 Id + PrimaryImageTag 时经 [MediaImageCache] 管道拉取,
/// 失败或无图时以名字首字圆形兜底。
class _PersonAvatar extends StatefulWidget {
  const _PersonAvatar({required this.person});

  final ItemPerson person;

  static const double size = 80;

  @override
  State<_PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<_PersonAvatar> {
  /// 头像请求宽:80 逻辑像素 × 2 倍屏留余量。
  static const _avatarRequestWidth = 192;

  Future<Uint8List?>? _future;

  bool get _hasImage {
    final id = widget.person.id;
    final tag = widget.person.primaryImageTag;
    return id != null && id.isNotEmpty && tag != null && tag.isNotEmpty;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasImage && AuthScope.maybeOf(context) != null) {
      _future ??= _load();
    }
  }

  Future<Uint8List?> _load() {
    final auth = AuthScope.of(context);
    return MediaImageCache.instance.load(
      serverId: auth.session?.server.id ?? '',
      itemId: widget.person.id!,
      type: 'Primary',
      tag: widget.person.primaryImageTag,
      maxWidth: _avatarRequestWidth,
      fetch: () async {
        try {
          final data = await auth.client.getItemImage(
            widget.person.id!,
            tag: widget.person.primaryImageTag,
            maxWidth: _avatarRequestWidth,
          );
          if (data.isEmpty) {
            return null;
          }
          return Uint8List.fromList(data);
        } catch (_) {
          return null;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.person.name.trim();
    final fallback = CircleAvatar(
      radius: _PersonAvatar.size / 2,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (!_hasImage) {
      return fallback;
    }
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return fallback;
        }
        return CircleAvatar(
          radius: _PersonAvatar.size / 2,
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          foregroundImage: MemoryImage(bytes),
        );
      },
    );
  }
}

/// 媒体流分区:当前片源的视频/音频/字幕轨分组列出。
class EpisodeMediaStreamsSection extends StatelessWidget {
  const EpisodeMediaStreamsSection({
    super.key,
    required this.source,
    this.selectedAudioIndex,
    this.selectedSubtitleIndex,
    this.onAudio,
    this.onSubtitle,
  });

  static const sectionKey = Key('episode-media-streams');

  /// 当前选中的片源;为 null 或无流时分区整段隐藏。
  final ItemMediaSource? source;
  final int? selectedAudioIndex;
  final int? selectedSubtitleIndex;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final source = this.source;
    if (source == null || source.streams.isEmpty) {
      return const SizedBox.shrink();
    }
    final videos = [
      for (final s in source.streams)
        if (s.isVideo) s,
    ];
    final audios = [
      for (final s in source.streams)
        if (s.isAudio) s,
    ];
    final subtitles = [
      for (final s in source.streams)
        if (s.isSubtitle) s,
    ];
    final groups = <(String, List<Widget>)>[
      if (videos.isNotEmpty)
        (
          l10n.videoTrack,
          [for (final s in videos) _chip(context, _videoLine(s))],
        ),
      if (audios.isNotEmpty)
        (
          l10n.audioTrack,
          [
            for (final s in audios)
              _chip(
                context,
                _audioLine(l10n, s),
                selected: s.index == selectedAudioIndex,
                onTap: onAudio == null ? null : () => onAudio!(s.index),
              ),
          ],
        ),
      if (subtitles.isNotEmpty)
        (
          l10n.subtitleTrack,
          [
            for (final s in subtitles)
              _chip(
                context,
                _subtitleLine(s),
                selected: s.index == selectedSubtitleIndex,
                onTap: onSubtitle == null ? null : () => onSubtitle!(s.index),
              ),
          ],
        ),
    ];
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return _Section(
      title: l10n.detailMediaInfo,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Column(
          key: sectionKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.sm),
              Text(groups[i].$1, style: labelStyle),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: groups[i].$2,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String line, {
    bool selected = false,
    VoidCallback? onTap,
  }) {
    if (line.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.18)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            line,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: selected ? scheme.primary : scheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  static String _joined(List<String?> parts) {
    return [
      for (final part in parts)
        if (part != null && part.trim().isNotEmpty) part.trim(),
    ].join(' · ');
  }

  static String? _upper(String? codec) {
    final value = codec?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.toUpperCase();
  }

  static String _videoLine(ItemMediaStream stream) {
    final range = stream.videoRange?.trim();
    final showRange =
        range != null && range.isNotEmpty && range.toUpperCase() != 'SDR';
    final line = _joined([
      _resolution(stream),
      _upper(stream.codec),
      if (showRange) range,
    ]);
    if (line.isNotEmpty) {
      return line;
    }
    return stream.label?.trim() ?? '';
  }

  static String? _resolution(ItemMediaStream stream) {
    final height = stream.height;
    if (height == null || height <= 0) {
      return null;
    }
    if (height >= 2000) {
      return '4K';
    }
    if (height >= 1400) {
      return '1440p';
    }
    if (height >= 1000) {
      return '1080p';
    }
    if (height >= 700) {
      return '720p';
    }
    return '${height}p';
  }

  static String _audioLine(AppLocalizations l10n, ItemMediaStream stream) {
    final label = stream.label?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return _joined([
      _upper(stream.codec),
      stream.channels != null ? l10n.audioChannels(stream.channels!) : null,
    ]);
  }

  static String _subtitleLine(ItemMediaStream stream) {
    final label = stream.label?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return _upper(stream.codec) ?? '';
  }
}

/// 下一集卡片:缩略图 + 标题,点击进入该集详情。无下一集时整段隐藏。
class NextEpisodeCard extends StatelessWidget {
  const NextEpisodeCard({super.key, required this.episode, this.onTap});

  static const sectionKey = Key('episode-next-section');
  static const cardKey = Key('episode-next-card');

  final EmbyItem? episode;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final episode = this.episode;
    if (episode == null) {
      return const SizedBox.shrink();
    }
    final runtime = runtimeLabel(l10n, episode);
    return _Section(
      title: l10n.nextEpisode,
      child: ConstrainedBox(
        key: sectionKey,
        constraints: const BoxConstraints(maxWidth: 420),
        child: SizedBox(
          width: double.infinity,
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: InkWell(
              key: cardKey,
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: SizedBox(
                        width: 160,
                        height: 90,
                        child: MediaImage(
                          item: episode,
                          width: 160,
                          height: 90,
                          preferThumb: true,
                          maxWidth: 320,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            episodeLabel(episode),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          if (runtime != null)
                            Text(
                              runtime,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
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
    );
  }
}

/// 元数据分区:入库日期等次级日期。全部缺失时整段隐藏。
class EpisodeMetadataSection extends StatelessWidget {
  const EpisodeMetadataSection({super.key, required this.item});

  static const sectionKey = Key('episode-metadata');

  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      if (item.dateCreated != null)
        (l10n.dateAdded, formatDateYmd(item.dateCreated!)),
    ];
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return _Section(
      title: l10n.detailMetadata,
      child: Column(
        key: sectionKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.$1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(row.$2, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
