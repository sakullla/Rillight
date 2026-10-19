import 'dart:async';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/home/library_latest_row.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 首页行请求的 Limit。满这一页说明货架查询后面还有条目。
const int phoneHomeRowLimit = 24;

/// 首屏作品主操作和下一段之间的间距。继续观看紧挨在这段空白之后。
const double phoneHomeHeroFollowGap = 12;

/// 其余首页区块之间的垂直节奏。
const double phoneHomeSectionGap = 28;

/// 手机首页：轮播图、继续观看、下一集、片库入口和每个片库的最近添加。
/// 拖动手柄排序，关掉的行归到「未显示」。片库页仍列出全部片库。
class PhoneHome extends StatefulWidget {
  const PhoneHome({super.key, this.sections});

  final PhoneHomeSectionController? sections;

  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<PhoneHome> {
  PhoneHomeSectionController? _sections;
  var _loadedServerId = '';

  /// 空库的「去媒体库」:直接打开第一个库;没有库时回退到服务器列表。
  void _openLibraries(CatalogController catalog) {
    if (catalog.libraries.isEmpty) {
      context.push('/servers');
      return;
    }
    context.push(AppRoutes.library(catalog.libraries.first.id));
  }

  /// 当前服务器是否配置了多条线路,决定服务器离线时显示「更换线路」。
  bool _hasAlternateLine() {
    final auth = AuthScope.maybeOf(context);
    final serverId = auth?.session?.server.id;
    if (auth == null || serverId == null) {
      return false;
    }
    for (final saved in auth.savedServers) {
      if (saved.id == serverId) {
        return saved.lines.length > 1;
      }
    }
    return false;
  }

  PhoneHomeSectionController get _controller =>
      _sections ?? PhoneHomeSectionController.app();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.sections ?? PhoneHomeSectionController.app();
    if (!identical(next, _sections)) {
      _sections = next;
      _loadedServerId = '';
    }
    final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
    if (_loadedServerId == serverId) {
      return;
    }
    _loadedServerId = serverId;
    unawaited(_controller.load(serverId));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([catalog, _controller]),
      builder: (context, _) {
        final watching = continueWatchingItems(
          catalog.resume.items,
          catalog.nextUp.items,
        );
        final watchingIds = {for (final item in watching) item.id};
        final nextUpItems = [
          for (final item in catalog.nextUp.items)
            if (!watchingIds.contains(item.id)) item,
        ];
        final byId = {
          PhoneHomeSectionId.resume: _HomeSection(
            title: l10n.resumeRow,
            state: CatalogRowState(
              items: watching,
              loading: catalog.resume.loading && watching.isEmpty,
              hidden:
                  watching.isEmpty &&
                  !catalog.resume.loading &&
                  catalog.resume.error == null,
              error: watching.isEmpty ? catalog.resume.error : null,
              notice: catalog.resume.notice,
            ),
            shelfId: CatalogKeys.shelfResume,
            location: AppRoutes.shelfResume,
            rowKey: CatalogKeys.resumeRow,
            wide: true,
            resume: true,
          ),
          PhoneHomeSectionId.nextUp: _HomeSection(
            title: l10n.nextUpRow,
            state: CatalogRowState(
              items: nextUpItems,
              loading: catalog.nextUp.loading && nextUpItems.isEmpty,
              hidden:
                  nextUpItems.isEmpty &&
                  !catalog.nextUp.loading &&
                  catalog.nextUp.error == null,
              error: nextUpItems.isEmpty ? catalog.nextUp.error : null,
              notice: catalog.nextUp.notice,
            ),
            shelfId: CatalogKeys.shelfNextUp,
            location: AppRoutes.shelfNextUp,
            rowKey: CatalogKeys.nextUpRow,
            wide: true,
          ),
        };
        final visible = _controller.visibleIds(catalog.libraries);
        final sections = [
          for (final id in visible)
            if (byId[id] != null) byId[id]!,
        ];
        final states = [for (final section in sections) section.state];
        final hasItems = states.any((state) => state.items.isNotEmpty);
        // 整页骨架的判断要和桌面、TV 用同一组数据:冷启动时最近入库行和
        // 片库列表也还在路上,不能只凭续播行没回来就说「这个服务器还没有内容」。
        final loading =
            [
              ...states,
              catalog.latestMovies,
              catalog.latestSeries,
            ].any((state) => state.loading) ||
            catalog.librariesLoading;
        final hasBanner =
            visible.contains(PhoneHomeSectionId.banner) &&
            PhoneHero.featuredItemsOf(catalog).isNotEmpty;
        // 片库入口不算「已有海报」:库存在但没有任何影片时,仍要给出
        // 明确的空库状态和「去媒体库」入口。
        final pageHasContent = hasItems || hasBanner;
        MediaServerException? firstError;
        for (final state in states) {
          if (state.error != null) {
            firstError = state.error;
            break;
          }
        }
        // 可见行、轮播图和片库都没有可展示内容时才用整页占位、失败或空。
        final Widget body;
        List<Widget>? sectionChildren;
        if (!hasItems && !hasBanner && firstError == null && loading) {
          body = const MobileLoadingPlaceholder.home();
        } else if (!hasItems && !hasBanner && firstError != null && !loading) {
          final hasLibraries = catalog.libraries.isNotEmpty;
          final copy = homeFailureCopyForError(
            l10n,
            firstError,
            hasLibraries: hasLibraries,
            hasAlternateLine: _hasAlternateLine(),
          );
          body = MobileFailureState(
            title: copy.title,
            message: copy.message,
            primaryLabel: copy.primaryLabel,
            onRetry: () {
              catalog.reloadHomeRows();
            },
            secondaryLabel: copy.secondaryLabel,
            onSecondary: () => context.push('/servers'),
          );
        } else if (!pageHasContent && !loading) {
          final hasLibraries = catalog.libraries.isNotEmpty;
          final copy = homeFailureCopy(
            l10n,
            HomeFailureKind.empty,
            hasLibraries: hasLibraries,
          );
          body = MobileEmptyState(
            title: copy.title,
            message: copy.message,
            primaryLabel: copy.primaryLabel,
            onPrimary: hasLibraries
                ? () => _openLibraries(catalog)
                : () => context.push('/servers'),
            secondaryLabel: copy.secondaryLabel,
            onSecondary: () {
              catalog.reload(showCachedFirst: false);
            },
          );
        } else {
          // Keep each item's route hero owned by the same rail across lazy
          // disposal and reconstruction when the user scrolls back.
          final sharedPosterOwners = <String, String>{};
          final librariesById = {
            for (final library in catalog.libraries) library.id: library,
          };
          // 横向海报行从屏幕边缘滑入滑出，页边距由标题和行内留白负责。
          const sectionMargin = EdgeInsets.zero;
          // 头图后面只留一小段，让继续观看紧挨主操作。其余区块保持 28。
          // 隐藏的区块不占位。横幅全出血，排在第一位时伸进状态栏与透明顶栏之下。
          final children = <Widget>[];
          for (final id in visible) {
            if (id == PhoneHomeSectionId.banner) {
              children.add(
                PhoneHero(
                  catalog: catalog,
                  extendBehindTopBar:
                      visible.first == PhoneHomeSectionId.banner,
                ),
              );
              continue;
            }
            final section = byId[id];
            if (section != null) {
              if (section.state.hidden) {
                continue;
              }
              children.add(
                Padding(
                  key: section.rowKey,
                  padding: sectionMargin,
                  child: _PhoneHomeRow(
                    section: section,
                    retry: () {
                      catalog.reloadHomeRows();
                    },
                    onRemoveFromResume: catalog.hideFromResume,
                    sharePoster: (itemId) =>
                        sharedPosterOwners.putIfAbsent(itemId, () => id) == id,
                  ),
                ),
              );
              continue;
            }
            if (id == PhoneHomeSectionId.libraries) {
              if (catalog.libraries.isEmpty) {
                continue;
              }
              children.add(
                Padding(
                  key: const ValueKey('home-section-libraries'),
                  padding: sectionMargin,
                  child: _PhoneLibraryEntry(libraries: catalog.libraries),
                ),
              );
              continue;
            }
            final libraryId = PhoneHomeSectionId.libraryIdOf(id);
            final library = libraryId == null ? null : librariesById[libraryId];
            if (library != null) {
              children.add(
                Padding(
                  key: ValueKey('home-section-library-$libraryId'),
                  padding: sectionMargin,
                  child: _PhoneLibraryLatest(
                    library: library,
                    sharePoster: (itemId) =>
                        sharedPosterOwners.putIfAbsent(
                          itemId,
                          () => 'library-$libraryId',
                        ) ==
                        'library-$libraryId',
                  ),
                ),
              );
            }
          }
          sectionChildren = children;
          body = const SizedBox.shrink();
        }
        final fullBleed =
            sectionChildren != null ||
            (body is MobileLoadingPlaceholder &&
                body.variant == MobileLoadingVariant.home);
        final navClearance = phoneScrollClearance(context);
        // 只有轮播图排在第一并且真有画面时，才让它伸进状态栏。
        // 用户把它调到后面时，第一行仍要躲开透明顶栏。
        final bannerLeads =
            visible.isNotEmpty &&
            visible.first == PhoneHomeSectionId.banner &&
            hasBanner;
        // 轮播不在第一位时，第一行要躲开壳层那条手机顶栏。
        final topInset = sectionChildren != null && !bannerLeads
            ? MediaQuery.viewPaddingOf(context).top +
                  PhoneTopBar.bodyHeight +
                  AppSpacing.md
            : 0.0;
        final page = AppRefresh(
          // 首页铺满到状态栏下，顶栏又浮在上面：指示器要落在两者之下才看得见。
          edgeOffset:
              MediaQuery.viewPaddingOf(context).top + PhoneTopBar.bodyHeight,
          onRefresh: () => catalog.reload(showCachedFirst: false),
          child: ListView.builder(
            key: const PageStorageKey('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
            padding: fullBleed
                ? EdgeInsets.only(
                    top: topInset,
                    bottom: AppSpacing.lg + navClearance,
                  )
                : EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md + navClearance,
                  ),
            itemCount: sectionChildren == null
                ? 1
                : sectionChildren.isEmpty
                ? 0
                : sectionChildren.length * 2 - 1,
            itemBuilder: (context, index) {
              final sections = sectionChildren;
              if (sections == null) return body;
              if (index.isOdd) {
                final before = sections[index ~/ 2];
                return SizedBox(
                  height: before is PhoneHero
                      ? phoneHomeHeroFollowGap
                      : phoneHomeSectionGap,
                );
              }
              return sections[index ~/ 2];
            },
          ),
        );
        return MediaImageScrollListener(child: page);
      },
    );
  }
}

double _cardWidthOf(BuildContext context, {required bool wide}) {
  final screen = MediaQuery.sizeOf(context).width;
  return wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
}

/// 海报卡角标组的定位键。实现已迁入 mobile_widgets(ADR-2),此处保留入口,
/// 既有测试与调用方的 import 不变。
Key phoneHomeBadgesKey(String itemId) => phoneCardBadgesKey(itemId);

String _resumeTitle(MediaItem item) {
  final series = item.seriesName?.trim();
  if (item.isEpisode && series != null && series.isNotEmpty) {
    return series;
  }
  return item.name;
}

String _resumeMeta(MediaItem item, String title) {
  if (!item.isEpisode) {
    final year = item.productionYear;
    return year != null && year > 0 ? '$year' : '';
  }
  final code = seasonEpisodeCode(item);
  final name = item.name.trim();
  if (_episodeNameIsTechnical(name)) {
    final spec = _episodeSpecLabel(item);
    return [?code, if (spec.isNotEmpty) spec].join(' · ');
  }
  if (name.isEmpty || name == title) {
    return code ?? '';
  }
  if (_nameCarriesEpisode(item) || code == null) {
    return name;
  }
  return '$code · $name';
}

/// 集名已经写出这一集（S1E2、S01E02、第 2 集、EP02）时，副标题不再加一遍季集编号。
bool _nameCarriesEpisode(MediaItem item) {
  final name = item.name.trim();
  final code = seasonEpisodeCode(item);
  if (code != null && name.toLowerCase().startsWith(code.toLowerCase())) {
    return true;
  }
  if (_leadingSeasonEpisodeMatches(item, name)) return true;
  if (item.indexNumber == null) return false;
  return numberedEpisodeTitle(item) == item.name;
}

/// 行首季集号允许前导零。S01E02 与未补零的 S1E2 是同一集。
final _leadingSeasonEpisode = RegExp(r'^[sS](\d+)[eE](\d+)\b');

bool _leadingSeasonEpisodeMatches(MediaItem item, String name) {
  final season = item.parentIndexNumber;
  final episode = item.indexNumber;
  if (season == null || episode == null) return false;
  final match = _leadingSeasonEpisode.firstMatch(name);
  if (match == null) return false;
  return int.tryParse(match.group(1)!) == season &&
      int.tryParse(match.group(2)!) == episode;
}

/// 集名主要由分辨率、编码或点分发布串组成。人读集名（含中文短名）不是。
bool _episodeNameIsTechnical(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  final separators = RegExp(r'[._]').allMatches(trimmed).length;
  // 没有点分的中文名是人读集名，即使里面提到画质也不改写成规格。
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(trimmed) && separators == 0) {
    return false;
  }
  if (!_releaseHint.hasMatch(trimmed)) return false;
  // 两个以上的点或下划线才是发布串。句子里的一个句点不算。
  if (separators >= 2) return true;
  final tokens = trimmed
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty);
  return tokens.isNotEmpty && tokens.every(_specToken.hasMatch);
}

final _releaseHint = RegExp(
  r'1080p|720p|2160p|1440p|480p|\b4k\b|\buhd\b|x26[45]|h\.?26[45]|\b26[45]\b|'
  r'hevc|\bavc\b|\bav1\b|\bvp9\b|flac|\baac\b|bdrip|bluray|web-?dl|webrip|10bit',
  caseSensitive: false,
);

/// 整段标题本身就是分辨率、编码或发布词，而不是句子里夹了一个画质词。
final _specToken = RegExp(
  r'^(?:1080p|720p|2160p|1440p|480p|4k|uhd|x26[45]|h\.?26[45]|26[45]|'
  r'hevc|avc|av1|vp9|flac|aac|bdrip|bluray|web-?dl|webrip|10bit)$',
  caseSensitive: false,
);

/// 发布串集名的副标题规格：分辨率和视频编码。
/// 解析出的规格即使与标题相同也保留；只有回退成原文件名或片源标签时才省略。
String _episodeSpecLabel(MediaItem item) {
  final first = item.mediaSources.isEmpty ? null : item.mediaSources.first;
  final sourceName = first?.name?.trim();
  final source = ItemMediaSource(
    id: first?.id ?? item.id,
    name: sourceName != null && sourceName.isNotEmpty ? sourceName : item.name,
    height: first?.height,
    width: first?.width,
    streams: first?.streams ?? const [],
  );
  final text = releaseSourcePrimaryText(source).trim();
  if (text.isEmpty) return '';
  final raw = item.name.trim();
  final named = source.name?.trim() ?? '';
  final echoed = text == raw || text == named || text == source.label;
  if (echoed && !_sourceHasParsedSpec(source)) return '';
  return text;
}

/// 分辨率或视频编码来自画面尺寸、视频流，或文件名里的规格词。
bool _sourceHasParsedSpec(ItemMediaSource source) {
  ItemMediaStream? video;
  for (final stream in source.streams) {
    if (stream.isVideo) {
      video = stream;
      break;
    }
  }
  final height = video?.height ?? source.height ?? 0;
  final width = video?.width ?? source.width ?? 0;
  if (height > 0 || width > 0) return true;
  if (video?.codec?.trim().isNotEmpty ?? false) return true;
  final raw = source.name?.trim() ?? '';
  if (raw.isEmpty) return false;
  for (final token in raw.split(RegExp(r'[.\s_\-]+'))) {
    if (token.isNotEmpty && _parsedSpecToken.hasMatch(token)) return true;
  }
  return false;
}

/// 与片源格式化相同的分辨率、编码词。命中时主文字是解析结果，不是文件名回退。
final _parsedSpecToken = RegExp(
  r'^(?:2160p|4k|uhd|1440p|1080p|720p|480p|'
  r'265|h265|h\.265|x265|hevc|264|h264|h\.264|x264|avc|av1|vp9)$',
  caseSensitive: false,
);

/// 行高 = 图区 + 图下标题。横卡的进度在画面底边，移除按钮叠在画面角上。
double _rowHeightOf(BuildContext context, {required bool wide}) =>
    phoneHomeRailHeight(context, wide: wide);

class _HomeSection {
  const _HomeSection({
    required this.title,
    required this.state,
    required this.shelfId,
    required this.location,
    required this.rowKey,
    this.wide = false,
    this.resume = false,
  });

  final String title;
  final CatalogRowState state;
  final String shelfId;
  final String location;
  final Key rowKey;
  final bool wide;
  final bool resume;
}

//// 分栏标题。能进入完整列表时，箭头贴在标题右侧，整段都可点。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.onMore, this.moreKey});

  final String title;
  final VoidCallback? onMore;
  final Key? moreKey;

  @override
  Widget build(BuildContext context) {
    // 区块之间的垂直节奏由首页统一负责，标题只留与卡片的下间距。
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: PhoneSectionHeader(
          title: title,
          onMore: onMore,
          moreKey: moreKey,
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        ),
      ),
    );
  }
}

class _PhoneHomeRow extends StatelessWidget {
  const _PhoneHomeRow({
    required this.section,
    required this.retry,
    required this.onRemoveFromResume,
    required this.sharePoster,
  });

  final _HomeSection section;
  final VoidCallback retry;
  final Future<void> Function(MediaItem item) onRemoveFromResume;

  /// 同一条目只让第一张海报参与飞行，避免同一路由里标签重复。
  final bool Function(String id) sharePoster;

  @override
  Widget build(BuildContext context) {
    final state = section.state;
    if (state.hidden) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final problem = state.error ?? state.notice;
    final hasMore =
        state.error == null &&
        ((section.resume || section.shelfId == CatalogKeys.shelfLatestSeries)
            ? state.items.isNotEmpty
            : state.items.length >= phoneHomeRowLimit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: section.title,
          onMore: hasMore ? () => context.push(section.location) : null,
          moreKey: hasMore ? CatalogKeys.shelfMore(section.shelfId) : null,
        ),
        if (state.loading && state.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: MobileLoadingPlaceholder.row(wide: section.wide),
          ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: MobileFailureState(
              message: catalogFailureMessage(l10n, problem),
              onRetry: retry,
            ),
          ),
        if (state.items.isNotEmpty)
          SizedBox(
            height: _rowHeightOf(context, wide: section.wide),
            child: ListView.builder(
              key: PageStorageKey('row-${section.title}'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: state.items.length,
              itemBuilder: (context, index) {
                final item = state.items[index];
                final shared = sharePoster(item.id);
                final cardWidth = _cardWidthOf(context, wide: section.wide);
                if (section.wide) {
                  return _WideCard(
                    item: item,
                    shared: shared,
                    width: cardWidth,
                    onRemove: section.resume && item.canResume
                        ? () {
                            unawaited(onRemoveFromResume(item));
                          }
                        : null,
                  );
                }
                return PhonePosterCard(
                  item: item,
                  width: cardWidth,
                  hero: shared,
                  pressKey: shared ? CatalogKeys.item(item.id) : null,
                );
              },
            ),
          ),
      ],
    );
  }
}

class _WideCard extends StatelessWidget {
  const _WideCard({
    required this.item,
    required this.shared,
    required this.width,
    this.onRemove,
  });

  final MediaItem item;
  final bool shared;
  final double width;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final progress = item.playbackProgress;
    final title = _resumeTitle(item);
    final meta = _resumeMeta(item, title);
    final remaining = remainingLabel(l10n, item);
    final caption = [if (meta.isNotEmpty) meta, ?remaining].join(' · ');
    final episodeCode = item.isEpisode ? seasonEpisodeCode(item) : null;
    final badges = [
      for (final label in phoneCardBadgeLabels(
        l10n,
        item,
        // 横卡底部已经有进度条，不再把同一进度写成「已看 n%」。
        includeResumeText: false,
      ))
        // 副标题已经写出集数时，角标不再重复同一季集编号。
        if (episodeCode == null || label != episodeCode || meta.isEmpty) label,
    ];
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(
        width: width,
        child: MobilePressable(
          key: CatalogKeys.item(item.id),
          onTap: () => PhoneMotion.openItem(
            context,
            item,
            preferBackdrop: !item.isEpisode,
            maxWidth: PhoneMotion.posterRequestWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: PhoneArtworkFrame(
                  radius: 12,
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      _sharedPosterImage(item, shared),
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: [0.0, 0.35, 0.62, 1.0],
                                colors: [
                                  Color(0x40000000),
                                  Color(0x00000000),
                                  Color(0x00000000),
                                  Color(0x9E000000),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (badges.isNotEmpty)
                        Positioned(
                          top: 8,
                          left: 8,
                          right: 48,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: PhoneCardBadges(
                              itemId: item.id,
                              labels: badges,
                            ),
                          ),
                        ),
                      if (item.isPlayable)
                        Positioned(
                          left: 10,
                          bottom: 12,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x52000000),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: AppIconButton(
                              key: Key('phone-resume-play-${item.id}'),
                              tooltip: item.canResume
                                  ? l10n.resumePlay
                                  : l10n.play,
                              style: AppButtonStyle(
                                minimumSize: const Size(48, 48),
                                fixedSize: const Size(48, 48),
                                padding: EdgeInsets.zero,
                                backgroundColor: const Color(0xF2FFFFFF),
                                foregroundColor: const Color(0xff000000),
                                shape: const CircleBorder(),
                              ),
                              onPressed: () => context.push<void>(
                                '/play/${item.id}',
                                extra: PlayerOpenRequest(
                                  itemId: item.id,
                                  autoResume: true,
                                ),
                              ),
                              icon: const Icon(
                                AppIcons.play,
                                size: 22,
                                fill: AppIcons.filled,
                              ),
                            ),
                          ),
                        ),
                      if (item.canResume)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Semantics(
                            container: true,
                            label: l10n.playbackProgress(
                              (progress * 100).round(),
                            ),
                            child: SizedBox(
                              key: CatalogKeys.resumeProgress,
                              height: 3.5,
                              child: ColoredBox(
                                color: const Color(0xffffffff)
                                    .withValues(alpha: 0.22),
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: progress.clamp(0.0, 1.0),
                                  child: ColoredBox(color: scheme.primary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (onRemove != null)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: AppTooltip(
                            message: l10n.removeFromResume,
                            child: GestureDetector(
                              key: CatalogKeys.removeFromResume(item.id),
                              behavior: HitTestBehavior.opaque,
                              onTap: onRemove,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      color: Color(0x8C000000),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: Icon(
                                        AppIcons.close,
                                        size: 13,
                                        fill: AppIcons.filled,
                                        color: Color(0xffffffff),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (caption.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhoneLibraryEntry extends StatelessWidget {
  const _PhoneLibraryEntry({required this.libraries});

  final List<MediaItem> libraries;

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    // 比继续观看小一档：一屏两张多，片库多时一眼看到更多入口。
    final cardWidth = phoneHomeLibraryCardWidth(screen);
    final cardHeight = cardWidth * 9 / 16;
    return Column(
      key: const Key('phone-home-libraries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: l10n.phoneHomeSectionLibraries),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: libraries.length,
            itemBuilder: (context, index) {
              final library = libraries[index];
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: SizedBox(
                  width: cardWidth,
                  height: cardHeight,
                  child: MobilePressable(
                    key: Key('phone-home-library-${library.id}'),
                    onTap: () => context.push(AppRoutes.library(library.id)),
                    child: PhoneLibraryTile(library: library),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PhoneLibraryLatest extends StatelessWidget {
  const _PhoneLibraryLatest({required this.library, required this.sharePoster});

  final MediaItem library;
  final bool Function(String id) sharePoster;

  @override
  Widget build(BuildContext context) {
    return LibraryLatestData(
      library: library,
      builder: (context, snapshot) {
        if (!snapshot.loading &&
            snapshot.error == null &&
            snapshot.items.isEmpty) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final title = l10n.phoneHomeLibraryLatest(library.name);
        return Column(
          key: Key('phone-home-library-latest-${library.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(
              title: title,
              moreKey: CatalogKeys.shelfMore('library-${library.id}'),
              onMore: () => context.push(AppRoutes.library(library.id)),
            ),
            if (snapshot.loading && snapshot.items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: MobileLoadingPlaceholder.row(),
              ),
            if (snapshot.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: MobileFailureState(
                  message: catalogFailureMessage(l10n, snapshot.error!),
                  onRetry: snapshot.retry,
                ),
              ),
            if (snapshot.items.isNotEmpty)
              SizedBox(
                height: _rowHeightOf(context, wide: false),
                child: ListView.builder(
                  key: PageStorageKey('row-$title'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                  itemCount: snapshot.items.length,
                  itemBuilder: (context, index) {
                    final item = snapshot.items[index];
                    final shared = sharePoster(item.id);
                    return PhonePosterCard(
                      item: item,
                      width: _cardWidthOf(context, wide: false),
                      hero: shared,
                      pressKey: shared ? CatalogKeys.item(item.id) : null,
                      includePlaybackBadges: false,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

Widget _sharedPosterImage(MediaItem item, bool shared) {
  final image = MediaImage(
    item: item,
    fit: BoxFit.cover,
    preferBackdrop: !item.isEpisode,
    preferThumb: item.isEpisode,
    maxWidth: PhoneMotion.posterRequestWidth,
  );
  if (!shared) {
    return image;
  }
  return PhoneMotion.sharedImage(
    itemId: item.id,
    preferBackdrop: image.preferBackdrop,
    child: image,
  );
}
