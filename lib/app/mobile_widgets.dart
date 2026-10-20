import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 手机端通用按压反馈基件(T1):按下时缩放 + 提亮,供海报卡、主按钮等复用。
///
/// 缩放与提亮幅度取 [AppMobileCard] 档位,时长走 [AppMotion.durationOf],
/// 系统要求减少动态效果时动效退化为瞬时切换。配合 [onTap] 使用;
/// 仅 Android 手机布局引用,桌面/TV 组件不适用。
class MobilePressable extends StatefulWidget {
  const MobilePressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = AppMobileCard.pressScale,
    this.brighten = AppMobileCard.pressBrighten,
    this.duration = AppMobileCard.pressDuration,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 按下时的缩放比例,见 [AppMobileCard.pressScale] 档位。
  final double scale;

  /// 按下时的提亮幅度,见 [AppMobileCard.pressBrighten]。
  final double brighten;

  /// 回弹时长档,默认 [AppMobileCard.pressDuration]。
  final Duration duration;

  @override
  State<MobilePressable> createState() => _MobilePressableState();
}

class _MobilePressableState extends State<MobilePressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.durationOf(context, widget.duration);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap == null
          ? null
          : () {
              _setPressed(false);
              widget.onTap!();
            },
      onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
      onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
      onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: duration,
        curve: AppMotion.standard,
        child: ColorFiltered(
          colorFilter: _pressed
              ? ColorFilter.mode(
                  AppInk.white.withValues(alpha: widget.brighten),
                  BlendMode.plus,
                )
              : const ColorFilter.mode(AppInk.transparent, BlendMode.plus),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 只管视觉的按压反馈:按下时轻微缩放与提亮,不参与手势竞技场。
///
/// 包在已有点击目标(如 [AppSurfaceAction])的外层,点击、焦点与键盘激活
/// 仍由内层负责;手指移动超过触摸阈值(开始滚动)即复原,不会在滑动列表时
/// 让整行一直处于按下态。[enabled] 为 false 时不响应。
class MobilePressFeedback extends StatefulWidget {
  const MobilePressFeedback({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = AppMobileCard.pressScale,
    this.brighten = AppMobileCard.pressBrighten,
  });

  final Widget child;
  final bool enabled;
  final double scale;
  final double brighten;

  @override
  State<MobilePressFeedback> createState() => _MobilePressFeedbackState();
}

class _MobilePressFeedbackState extends State<MobilePressFeedback> {
  bool _pressed = false;
  Offset? _origin;

  void _set(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.durationOf(context, AppMobileCard.pressDuration);
    final pressed = _pressed && widget.enabled;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.enabled
          ? (event) {
              _origin = event.position;
              _set(true);
            }
          : null,
      onPointerMove: (event) {
        final origin = _origin;
        if (origin != null && (event.position - origin).distance > kTouchSlop) {
          _origin = null;
          _set(false);
        }
      },
      onPointerUp: (_) {
        _origin = null;
        _set(false);
      },
      onPointerCancel: (_) {
        _origin = null;
        _set(false);
      },
      child: AnimatedScale(
        scale: pressed ? widget.scale : 1,
        duration: duration,
        curve: AppMotion.standard,
        child: ColorFiltered(
          colorFilter: pressed
              ? ColorFilter.mode(
                  AppInk.white.withValues(alpha: widget.brighten),
                  BlendMode.plus,
                )
              : const ColorFilter.mode(AppInk.transparent, BlendMode.plus),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 海报卡角标组的定位键:一张卡最多一组角标,测试据此把角标限定在卡内。
Key phoneCardBadgesKey(String itemId) => Key('phone-card-badges-$itemId');

/// 角标文案:分集给季集编号、剧集给季数、已看给已看标记、可续播给
/// 已看百分比(沿用 playbackProgress/resumeProgress 的既有语义)。
///
/// [includePlayback] 关闭时不给已看/进度角标:片库「最新入库」预览行只在
/// 入场时取一次数据,不随 reloadHomeRows 刷新,播动态角标会停留旧值。
List<String> phoneCardBadgeLabels(
  AppLocalizations l10n,
  MediaItem item, {
  bool includePlayback = true,
  bool includeResumeText = true,
  bool includeSeriesSeason = true,
}) {
  final labels = <String>[];
  if (item.isEpisode) {
    final code = seasonEpisodeCode(item);
    if (code != null) {
      labels.add(code);
    }
  } else if (includeSeriesSeason &&
      item.isSeries &&
      (item.childCount ?? 0) > 0) {
    labels.add(l10n.cardSeasonCount(item.childCount!));
  }
  if (includePlayback) {
    if (item.userData.played) {
      labels.add(l10n.mobileWatched);
    } else if (includeResumeText && item.canResume) {
      labels.add(l10n.playbackProgress((item.playbackProgress * 100).round()));
    }
  }
  return labels;
}

//// 海报图角上的信息角标:深色小胶囊,叠在图区上不遮挡点按。「已看」用强调色。
class _PhoneCardBadge extends StatelessWidget {
  const _PhoneCardBadge({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent ? scheme.primary : AppInk.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(6),
        border: accent
            ? null
            : Border.all(
                color: AppInk.white.withValues(alpha: 0.16),
                width: 0.6,
              ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          style: theme.textTheme.labelSmall?.copyWith(
            color: accent ? scheme.onPrimary : AppInk.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
      ),
    );
  }
}

/// 一张卡的角标组(ADR-3),多个角标从左到右排列、超出换行。
class PhoneCardBadges extends StatelessWidget {
  const PhoneCardBadges({
    super.key,
    required this.itemId,
    required this.labels,
  });

  final String itemId;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final watched = AppLocalizations.of(context).mobileWatched;
    return Wrap(
      key: phoneCardBadgesKey(itemId),
      spacing: AppSpacing.xxs,
      runSpacing: AppSpacing.xxs,
      children: [
        for (final label in labels)
          _PhoneCardBadge(label: label, accent: label == watched),
      ],
    );
  }
}

/// 海报/剧照底边的细进度条。底轨是半透明黑,进度用主题强调色。
class PhoneArtworkProgress extends StatelessWidget {
  const PhoneArtworkProgress({
    super.key,
    required this.progress,
    this.height = 3,
    this.semanticsLabel,
  });

  final double progress;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final bar = SizedBox(
      height: height,
      child: ColoredBox(
        color: AppInk.black.withValues(alpha: 0.5),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress.clamp(0.0, 1.0),
          child: ColoredBox(color: scheme.primary),
        ),
      ),
    );
    final label = semanticsLabel;
    if (label == null) return ExcludeSemantics(child: bar);
    return Semantics(container: true, label: label, child: bar);
  }
}

/// 海报与剧照的统一画框:圆角、发丝描边,深浅主题都不加卡片底。
class PhoneArtworkFrame extends StatelessWidget {
  const PhoneArtworkFrame({
    super.key,
    required this.child,
    this.radius = PhoneArtworkFrame.defaultRadius,
  });

  static const double defaultRadius = 12;

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final shape = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: shape,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        border: Border.all(
          color: light
              ? AppInk.black.withValues(alpha: 0.08)
              : AppInk.white.withValues(alpha: 0.10),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 手机端 2:3 海报卡(ADR-2):裸海报 + 图下标题与「年份 ★评分」。
///
/// 不给海报套卡片底和描边框:画面就是卡片本身,标题直接落在页面底色上。
/// 角标叠在图左上,可续播时底边一条进度。片库网格把标题放到两行,并把季数
/// 单独写成 [AppLocalizations.seasonCount],不和评分挤在同一行。
///
/// [width] 非空是横向行里的定宽卡(右侧留间距);为 null 时铺满父级
/// 宽度,供网格单元格使用——网格 childAspectRatio 须按
/// [phonePosterCardLabelExtent] 预留图下文字区。
class PhonePosterCard extends StatelessWidget {
  const PhonePosterCard({
    super.key,
    required this.item,
    this.width,
    this.pressKey,
    this.hero = false,
    this.includePlaybackBadges = true,
    this.imageMaxWidth = PhoneMotion.posterRequestWidth,
    this.onTap,
    this.titleMaxLines = 1,
    this.seasonCountCaption = false,
  });

  final MediaItem item;

  /// 横向行里的固定卡宽;null 时铺满父级宽度(网格)。
  final double? width;

  /// 点按热区的行为键(如 CatalogKeys.item)。键语义归调用方,组件不假设。
  final Key? pressKey;

  /// 是否用 [PhoneMotion.sharedImage] 参与详情页飞行。同一路由里同一条目
  /// 只允许一张海报置 true,否则 Hero 标签重复。
  final bool hero;

  /// 是否显示已看/进度角标。只取一次数据的行传 false,避免角标停留旧值。
  final bool includePlaybackBadges;

  /// 请求图宽,默认 [PhoneMotion.posterRequestWidth];网格按单元格物理宽取。
  final int imageMaxWidth;

  /// 点按行为;默认 [PhoneMotion.openItem] 进详情。
  final VoidCallback? onTap;

  /// 标题行数。片库网格用两行,首页横滑卡保持一行。
  final int titleMaxLines;

  /// 剧集季数改用 [AppLocalizations.seasonCount],单独排在评分下面。
  final bool seasonCountCaption;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final seasonCount = item.childCount;
    final showSeasonCaption =
        seasonCountCaption && item.isSeries && (seasonCount ?? 0) > 0;
    final badges = phoneCardBadgeLabels(
      l10n,
      item,
      includePlayback: includePlaybackBadges,
      // 进度由底边进度条表达,不再重复写成「已看 n%」。
      includeResumeText: false,
      includeSeriesSeason: !showSeasonCaption,
    );
    final image = MediaImage(
      item: item,
      maxWidth: imageMaxWidth,
      fit: BoxFit.cover,
    );
    final rating = item.communityRating;
    final year = item.productionYear;
    final subtitle = year != null && year > 0 ? '$year' : '';
    final showProgress =
        includePlaybackBadges && item.canResume && !item.userData.played;
    final card = MobilePressable(
      key: pressKey,
      onTap:
          onTap ??
          () => PhoneMotion.openItem(context, item, maxWidth: imageMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: PhoneArtworkFrame(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  hero
                      ? PhoneMotion.sharedImage(
                          itemId: item.id,
                          preferBackdrop: false,
                          child: image,
                        )
                      : image,
                  if (badges.isNotEmpty)
                    Positioned(
                      top: 6,
                      left: 6,
                      right: 6,
                      child: PhoneCardBadges(itemId: item.id, labels: badges),
                    ),
                  if (showProgress)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PhoneArtworkProgress(
                        progress: item.playbackProgress,
                        semanticsLabel: l10n.playbackProgress(
                          (item.playbackProgress * 100).round(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 7, 2, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: phonePosterTitleStyle(theme),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (subtitle.isNotEmpty)
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: phonePosterMetaStyle(theme),
                        ),
                      ),
                    if (rating != null && rating > 0) ...[
                      if (subtitle.isNotEmpty) const SizedBox(width: 6),
                      Icon(
                        AppIcons.star,
                        fill: AppIcons.filled,
                        size: 10,
                        color: AppBrand.ratingStar(theme.brightness),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        rating.toStringAsFixed(1),
                        maxLines: 1,
                        style: phonePosterMetaStyle(theme)?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                if (showSeasonCaption) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.seasonCount(seasonCount!),
                    key: Key('phone-poster-season-${item.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: phonePosterMetaStyle(theme),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final width = this.width;
    if (width == null) {
      return card;
    }
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(width: width, child: card),
    );
  }
}

/// 海报卡标题:一行、w600,比正文小一档。
TextStyle? phonePosterTitleStyle(AppUiThemeData theme) => theme
    .textTheme
    .bodyMedium
    ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.25);

/// 海报卡副行:年份与评分。
TextStyle? phonePosterMetaStyle(AppUiThemeData theme) => theme
    .textTheme
    .labelSmall
    ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.25);

// 海报主图是否存在:无标签的 Primary 兜底不算有图,避免把占位交出去。
bool phonePosterHasImage(MediaItem item) {
  return item
      .imageCandidates(preferBackdrop: false)
      .any((ref) => ref.tag != null && ref.tag!.isNotEmpty);
}

/// 网格海报卡(ADR-3):铺满网格单元格的 [PhonePosterCard],带图上胶囊角标。
///
/// 有图时参与 Hero 飞行并带图交接进详情;无图直 push 详情,不出现占位飞行
/// (沿用原 MobilePoster 语义)。[onTap] 可覆盖默认导航(如相册进货架);
/// 与首页同屏可能重复出现条目时应把 [hero] 置 false,避免 Hero 标签撞车。
class PhoneGridPosterCard extends StatelessWidget {
  const PhoneGridPosterCard({
    super.key,
    required this.item,
    this.hero = true,
    this.includePlaybackBadges = true,
    this.imageMaxWidth = PhoneMotion.posterRequestWidth,
    this.onTap,
    this.titleMaxLines = 1,
    this.seasonCountCaption = false,
  });

  final MediaItem item;

  /// 是否参与 Hero 飞行;仅在有图时生效。
  final bool hero;

  /// 是否显示已看/进度角标。只取一次数据的网格传 false,避免角标停留旧值。
  final bool includePlaybackBadges;

  /// 请求图宽,默认 [PhoneMotion.posterRequestWidth]。
  final int imageMaxWidth;

  /// 点按行为;默认按有无图走 [PhoneMotion.openItem] 或直 push 详情。
  final VoidCallback? onTap;

  /// 见 [PhonePosterCard.titleMaxLines]。
  final int titleMaxLines;

  /// 见 [PhonePosterCard.seasonCountCaption]。
  final bool seasonCountCaption;

  @override
  Widget build(BuildContext context) {
    final hasImage = phonePosterHasImage(item);
    return RepaintBoundary(
      child: PhonePosterCard(
        item: item,
        hero: hero && hasImage,
        includePlaybackBadges: includePlaybackBadges,
        imageMaxWidth: imageMaxWidth,
        titleMaxLines: titleMaxLines,
        seasonCountCaption: seasonCountCaption,
        onTap:
            onTap ??
            () {
              if (!hasImage) {
                context.push(AppRoutes.item(item.id));
                return;
              }
              PhoneMotion.openItem(
                context,
                item,
                preferBackdrop: false,
                maxWidth: imageMaxWidth,
              );
            },
      ),
    );
  }
}

/// 网格海报卡图下文字区高度:7px 间距 + 标题 + 2px + 年份/评分行 + 4px 余量。
/// 网格 childAspectRatio 与骨架共用,保证单元格刚好容纳网格态
/// [PhonePosterCard](年份缺失的卡片底部留空,不挤压图区 2:3)。
///
/// 默认是单行标题。片库传入两行标题和季数行;不传时高度与原先一致。
double phonePosterCardLabelExtent(
  BuildContext context, {
  int titleLines = 1,
  bool includeSeasonLine = false,
}) {
  final theme = AppUiTheme.of(context);
  double lineHeight(TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final meta = lineHeight(phonePosterMetaStyle(theme));
  final star = MediaQuery.textScalerOf(context).scale(10);
  final metaLine = meta > star ? meta : star;
  final seasonLine = includeSeasonLine ? 2 + meta : 0;
  return 7 +
      lineHeight(phonePosterTitleStyle(theme)) * titleLines +
      2 +
      metaLine +
      seasonLine +
      4;
}

/// 片库海报文字区:单行加粗主标题 + 单行「年份 ★评分」元信息(剧集季数已移入封面左上角标)。
double phoneLibraryPosterLabelExtent(BuildContext context) =>
    phonePosterCardLabelExtent(
      context,
      titleLines: 1,
      includeSeasonLine: false,
    );

/// Readable poster widths: 360dp uses two columns, 412dp uses three.
/// System text scaling reduces columns instead of shrinking labels.
int mobileGridColumnCount(double width, {double textScale = 1}) =>
    ((width + AppSpacing.md) / (126 * textScale.clamp(1, 2))).floor().clamp(
      1,
      6,
    );

/// 手机端海报网格(T5):Wrap 换 GridView,列数走 [mobileGridColumnCount],
/// 间距走 [AppSpacing];图片懒加载沿用 media_image。
///
/// 默认嵌套在可滚动页内:shrinkWrap + 禁用自身滚动,滚动由外层负责。
class MobileGrid extends StatelessWidget {
  const MobileGrid({
    super.key,
    required this.items,
    this.itemBuilder,
    this.padding = EdgeInsets.zero,
  });

  final List<MediaItem> items;

  /// 自定义卡片构建;null 时用 [PhoneGridPosterCard]。调用方负责条目 key。
  final Widget Function(BuildContext context, MediaItem item)? itemBuilder;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpacing.sm;
      final columns = mobileGridColumnCount(
        constraints.maxWidth,
        textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
      );
      final cellWidth =
          (constraints.maxWidth - spacing * (columns - 1)) / columns;
      final labelExtent = phonePosterCardLabelExtent(context);
      return GridView.builder(
        padding: padding,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: AppSpacing.lg,
          crossAxisSpacing: spacing,
          childAspectRatio: cellWidth / (cellWidth * 1.5 + labelExtent),
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return itemBuilder?.call(context, item) ??
              PhoneGridPosterCard(item: item);
        },
      );
    },
  );
}

/// 手机分区标题:大号粗体标题,能进完整列表时右侧带「全部」与箭头,整行可点。
class PhoneSectionHeader extends StatelessWidget {
  const PhoneSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onMore,
    this.moreKey,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: AppSpacing.sm),
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  final Key? moreKey;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: phoneSectionTitleStyle(theme),
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
    final onMore = this.onMore;
    final row = Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(child: heading),
              if (onMore != null) ...[
                const SizedBox(width: 2),
                Icon(
                  AppIcons.chevronRight,
                  fill: AppIcons.filled,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
    return Padding(
      padding: padding,
      child: onMore == null
          ? row
          : AppSurfaceAction(
              key: moreKey,
              onTap: onMore,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: row,
              ),
            ),
    );
  }
}

/// 分区标题字阶:20 号粗体,与海报行拉开层次。
TextStyle? phoneSectionTitleStyle(AppUiThemeData theme) =>
    theme.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.2,
    );

/// 手机标签页的大标题栏:左侧大号页面名,右侧可放操作。
class PhoneLargeTitle extends StatelessWidget {
  const PhoneLargeTitle({
    super.key,
    required this.title,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.xs,
      AppSpacing.xs,
      AppSpacing.xs,
    ),
  });

  final String title;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: phoneLargeTitleStyle(theme),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 片库是否带有可用封面。
bool phoneLibraryHasImage(MediaItem library) {
  bool tagged(String? tag) => tag != null && tag.isNotEmpty;
  return tagged(library.primaryImageTag) ||
      tagged(library.backdropImageTag) ||
      tagged(library.thumbImageTag);
}

/// 片库类型图标。
IconData phoneLibraryIcon(String? collectionType) => switch (collectionType) {
  'movies' => AppIcons.movie,
  'tvshows' => AppIcons.series,
  'music' => AppIcons.music,
  'musicvideos' => AppIcons.musicVideo,
  'photos' || 'homevideos' => AppIcons.photoLibrary,
  'boxsets' => AppIcons.boxSet,
  'playlists' => AppIcons.playlist,
  'livetv' => AppIcons.liveTv,
  _ => AppIcons.library,
};

/// 没有封面的片库取一组深色渐变。按库 id 在色板里轮换，同类型的多个库
/// （「电影」「纪录片」「动画」）并排时也不撞色。
List<Color> _libraryGradient(MediaItem library) {
  var hash = 0;
  for (final unit in library.id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return AppBrand.libraryGradients[hash % AppBrand.libraryGradients.length];
}

/// 16:9 片库磁贴：有封面铺满封面，没有就按类型画渐变和大图标；
/// 库名压在左下角，两种主题都是深底白字。
class PhoneLibraryTile extends StatelessWidget {
  const PhoneLibraryTile({
    super.key,
    required this.library,
    this.imageKey,
    this.placeholderKey,
    this.subtitle,
    this.large = false,
  });

  final MediaItem library;
  final Key? imageKey;
  final Key? placeholderKey;
  final String? subtitle;

  /// 片库标签页的大磁贴用更大的字。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final hasImage = phoneLibraryHasImage(library);
    final icon = phoneLibraryIcon(library.collectionType);
    return PhoneArtworkFrame(
      radius: 12,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            MediaImage(
              key: imageKey,
              item: library,
              preferBackdrop: true,
              maxWidth: large ? 720 : 480,
            )
          else
            DecoratedBox(
              key: placeholderKey,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _libraryGradient(library),
                ),
              ),
              child: Align(
                alignment: const Alignment(.82, -.1),
                child: ExcludeSemantics(
                  child: Icon(
                    icon,
                    fill: AppIcons.filled,
                    size: large ? 64 : 46,
                    color: AppInk.white.withValues(alpha: 0.2),
                  ),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.35, 1],
                colors: [
                  AppInk.transparent,
                  AppInk.black.withValues(alpha: 0.70),
                ],
              ),
            ),
          ),
          Positioned(
            left: large ? 14 : 12,
            right: large ? 14 : 12,
            bottom: large ? 12 : 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        library.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: AppInk.white,
                          fontSize: large ? 18 : 15,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          shadows: [
                            Shadow(
                              color: AppInk.black.withValues(alpha: 0.4),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppInk.white.withValues(alpha: 0.8),
                            height: 1.3,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasImage)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ExcludeSemantics(
                      child: Icon(
                        icon,
                        fill: AppIcons.filled,
                        size: large ? 18 : 15,
                        color: AppInk.white.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签页大标题字阶。
TextStyle? phoneLargeTitleStyle(AppUiThemeData theme) =>
    theme.textTheme.displaySmall?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      height: 1.2,
      letterSpacing: -0.4,
    );
